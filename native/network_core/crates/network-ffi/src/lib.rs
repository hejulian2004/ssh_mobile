//! Network Protocol V2 C ABI binding: runtime creation, commands, polling and
//! deterministic lifecycle control. The C ABI version is independent from the
//! Network Protocol version and only changes on an ABI shape break.
#![allow(linker_messages)]

use network_core::NetworkRuntime;
use network_protocol::{
    network_event, CommandResultEvent, NetworkCommand, NetworkError, NetworkErrorCode,
    NetworkEvent, NETWORK_PROTOCOL_VERSION,
};
use prost::Message;
use std::collections::{HashSet, VecDeque};
use std::ffi::c_void;
use std::panic::catch_unwind;
use std::slice;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

mod realtime_media;

pub const SSH_NET_ABI_VERSION: u32 = 1;
pub const SSH_NET_MAX_COMMAND_BYTES: usize = 1024 * 1024;
pub const SSH_NET_MAX_EVENT_BYTES: usize = 1024 * 1024;
pub const SSH_NET_MAX_CONTROL_ITEMS: usize = 256;
pub const SSH_NET_MAX_CONTROL_BYTES: usize = 4 * 1024 * 1024;
pub const SSH_NET_MAX_DATA_ITEMS: usize = 128;
pub const SSH_NET_MAX_DATA_BYTES: usize = 8 * 1024 * 1024;
pub const SSH_NET_MAX_CONSECUTIVE_CONTROL_EVENTS: usize = 8;
pub const SSH_NET_MAX_PENDING_COMMANDS: usize = 64;
pub const SSH_NET_MAX_TERMINAL_COMMANDS: usize = 1024;
const SSH_NET_RUNTIME_DRAIN_BATCH: usize = 512;

/// 跨 FFI 边界传递的不透明运行时句柄。
pub type SshNetRuntimeHandle = *mut c_void;

#[repr(C)]
pub struct SshNetBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

/// FFI-local lane classification.  The protocol owner remains responsible
/// for adding any future explicit lane metadata; this fallback classification
/// only schedules already-defined V2 events at the ABI boundary.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EventLane {
    CriticalControl,
    NormalControl,
    Data,
}

struct QueuedEvent<T> {
    value: T,
    bytes: usize,
}

/// Bounded FFI-side event mux used while the owning Core event source remains
/// V2. It prevents the ABI buffer from becoming an unbounded second queue and
/// enforces the frozen fairness rule for the events it has already drained.
struct EventMux<T> {
    critical: VecDeque<QueuedEvent<T>>,
    normal: VecDeque<QueuedEvent<T>>,
    data: VecDeque<QueuedEvent<T>>,
    control_bytes: usize,
    data_bytes: usize,
    consecutive_control: usize,
}

impl<T> EventMux<T> {
    fn new() -> Self {
        Self {
            critical: VecDeque::new(),
            normal: VecDeque::new(),
            data: VecDeque::new(),
            control_bytes: 0,
            data_bytes: 0,
            consecutive_control: 0,
        }
    }

    fn is_empty(&self) -> bool {
        self.critical.is_empty() && self.normal.is_empty() && self.data.is_empty()
    }

    #[cfg(test)]
    fn control_items(&self) -> usize {
        self.critical.len() + self.normal.len()
    }

    #[cfg(test)]
    fn data_items(&self) -> usize {
        self.data.len()
    }

    #[cfg(test)]
    fn control_bytes(&self) -> usize {
        self.control_bytes
    }

    #[cfg(test)]
    fn data_bytes(&self) -> usize {
        self.data_bytes
    }

    fn enqueue(&mut self, value: T, lane: EventLane, bytes: usize) -> bool {
        if bytes > SSH_NET_MAX_EVENT_BYTES {
            return false;
        }
        let entry = QueuedEvent { value, bytes };
        match lane {
            EventLane::CriticalControl => {
                if self.critical.len() + self.normal.len() >= SSH_NET_MAX_CONTROL_ITEMS
                    || self.control_bytes + bytes > SSH_NET_MAX_CONTROL_BYTES
                {
                    return false;
                }
                self.control_bytes += bytes;
                self.critical.push_back(entry);
                true
            }
            EventLane::NormalControl => {
                if self.critical.len() + self.normal.len() >= SSH_NET_MAX_CONTROL_ITEMS
                    || self.control_bytes + bytes > SSH_NET_MAX_CONTROL_BYTES
                {
                    return false;
                }
                self.control_bytes += bytes;
                self.normal.push_back(entry);
                true
            }
            EventLane::Data => {
                if bytes > SSH_NET_MAX_DATA_BYTES {
                    return false;
                }
                while !self.data.is_empty()
                    && (self.data.len() >= SSH_NET_MAX_DATA_ITEMS
                        || self.data_bytes + bytes > SSH_NET_MAX_DATA_BYTES)
                {
                    if let Some(dropped) = self.data.pop_front() {
                        self.data_bytes = self.data_bytes.saturating_sub(dropped.bytes);
                    }
                }
                self.data_bytes += bytes;
                self.data.push_back(entry);
                true
            }
        }
    }

    fn pop(&mut self) -> Option<T> {
        let has_data = !self.data.is_empty();
        let force_data =
            has_data && self.consecutive_control >= SSH_NET_MAX_CONSECUTIVE_CONTROL_EVENTS;
        if !force_data {
            if let Some(entry) = self.critical.pop_front() {
                self.control_bytes = self.control_bytes.saturating_sub(entry.bytes);
                self.consecutive_control += 1;
                return Some(entry.value);
            }
            if let Some(entry) = self.normal.pop_front() {
                self.control_bytes = self.control_bytes.saturating_sub(entry.bytes);
                self.consecutive_control += 1;
                return Some(entry.value);
            }
        }
        if let Some(entry) = self.data.pop_front() {
            self.data_bytes = self.data_bytes.saturating_sub(entry.bytes);
            self.consecutive_control = 0;
            return Some(entry.value);
        }
        if let Some(entry) = self.critical.pop_front() {
            self.control_bytes = self.control_bytes.saturating_sub(entry.bytes);
            self.consecutive_control += 1;
            return Some(entry.value);
        }
        self.normal.pop_front().map(|entry| {
            self.control_bytes = self.control_bytes.saturating_sub(entry.bytes);
            self.consecutive_control += 1;
            entry.value
        })
    }
}

/// Bounded exactly-once history for completed command IDs. Older IDs are
/// evicted in insertion order so a long-running runtime cannot retain every
/// command ever submitted.
struct BoundedCommandHistory {
    ids: HashSet<String>,
    order: VecDeque<String>,
}

impl BoundedCommandHistory {
    fn new() -> Self {
        Self {
            ids: HashSet::new(),
            order: VecDeque::new(),
        }
    }

    fn contains(&self, command_id: &str) -> bool {
        self.ids.contains(command_id)
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.ids.len()
    }

    fn insert(&mut self, command_id: String) -> bool {
        if !self.ids.insert(command_id.clone()) {
            return false;
        }
        self.order.push_back(command_id);
        while self.order.len() > SSH_NET_MAX_TERMINAL_COMMANDS {
            if let Some(evicted) = self.order.pop_front() {
                self.ids.remove(&evicted);
            }
        }
        true
    }
}

struct SshNetRuntime {
    runtime: NetworkRuntime,
    pending_commands: Mutex<HashSet<String>>,
    terminal_commands: Mutex<BoundedCommandHistory>,
    synthetic_events: Mutex<EventMux<NetworkEvent>>,
    drained_events: Mutex<EventMux<NetworkEvent>>,
}

impl SshNetRuntime {
    fn new() -> Result<Self, network_core::NetworkError> {
        Ok(Self {
            runtime: NetworkRuntime::new()?,
            pending_commands: Mutex::new(HashSet::new()),
            terminal_commands: Mutex::new(BoundedCommandHistory::new()),
            synthetic_events: Mutex::new(EventMux::new()),
            drained_events: Mutex::new(EventMux::new()),
        })
    }

    fn stop(&self) -> Result<(), network_core::NetworkError> {
        let result = self.runtime.stop();
        self.cancel_pending_commands();
        result
    }

    fn cancel_pending_commands(&self) {
        let command_ids = self
            .pending_commands
            .lock()
            .map(|mut pending| pending.drain().collect::<Vec<_>>())
            .unwrap_or_default();
        if command_ids.is_empty() {
            return;
        }
        let mut terminal = match self.terminal_commands.lock() {
            Ok(terminal) => terminal,
            Err(_) => return,
        };
        let mut events = match self.synthetic_events.lock() {
            Ok(events) => events,
            Err(_) => return,
        };
        for command_id in command_ids {
            if !terminal.insert(command_id.clone()) {
                continue;
            }
            let event = NetworkEvent {
                event_id: format!("{command_id}/cancelled"),
                timestamp_ms: unix_timestamp_ms(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(network_event::Payload::CommandResult(CommandResultEvent {
                    command_id,
                    accepted: false,
                    error: Some(NetworkError {
                        code: NetworkErrorCode::Cancelled as i32,
                        message: "runtime stopped".to_string(),
                        operation: "runtime_stop".to_string(),
                        peer_id: String::new(),
                        retry_disposition: 1,
                        retry_after_seconds: 0,
                    }),
                })),
            };
            let bytes = event.encode_to_vec().len();
            let _ = events.enqueue(event, EventLane::CriticalControl, bytes);
        }
    }

    fn remember_command(&self, command_id: &str) -> Result<(), i32> {
        let mut pending = self.pending_commands.lock().map_err(|_| -3)?;
        let terminal = self.terminal_commands.lock().map_err(|_| -3)?;
        if pending.contains(command_id) || terminal.contains(command_id) {
            return Err(-6);
        }
        if pending.len() >= SSH_NET_MAX_PENDING_COMMANDS {
            return Err(-7);
        }
        pending.insert(command_id.to_string());
        Ok(())
    }

    fn admit_event(&self, event: NetworkEvent) -> Option<NetworkEvent> {
        if let Some(network_event::Payload::CommandResult(result)) = &event.payload {
            let mut pending = self.pending_commands.lock().ok()?;
            let mut terminal = self.terminal_commands.lock().ok()?;
            if terminal.contains(&result.command_id) {
                return None;
            }
            pending.remove(&result.command_id);
            terminal.insert(result.command_id.clone());
        }
        if let Some(network_event::Payload::CommandResultV2(result)) = &event.payload {
            let mut pending = self.pending_commands.lock().ok()?;
            let mut terminal = self.terminal_commands.lock().ok()?;
            if terminal.contains(&result.command_id) {
                return None;
            }
            pending.remove(&result.command_id);
            terminal.insert(result.command_id.clone());
        }
        Some(event)
    }

    fn drain_runtime_events(&self, timeout_ms: u32) -> Result<(), i32> {
        for index in 0..SSH_NET_RUNTIME_DRAIN_BATCH {
            let Some(event) = self
                .runtime
                .poll_event(if index == 0 { timeout_ms } else { 0 })
            else {
                break;
            };
            let bytes = event.encode_to_vec().len();
            if bytes > SSH_NET_MAX_EVENT_BYTES {
                continue;
            }
            let lane = event_lane(&event);
            if let Some(event) = self.admit_event(event) {
                match self.drained_events.lock() {
                    Ok(mut mux) => {
                        let _ = mux.enqueue(event, lane, bytes);
                    }
                    Err(_) => return Err(-3),
                }
            }
        }
        Ok(())
    }
}

fn event_lane(event: &NetworkEvent) -> EventLane {
    match event.payload.as_ref() {
        Some(network_event::Payload::CommandResult(_))
        | Some(network_event::Payload::CommandResultV2(_))
        | Some(network_event::Payload::PeerState(_))
        | Some(network_event::Payload::RelayStateChanged(_)) => EventLane::CriticalControl,
        Some(network_event::Payload::TransferProgress(_))
        | Some(network_event::Payload::PeerTransferProgress(_))
        | Some(network_event::Payload::ChannelMessage(_))
        | Some(network_event::Payload::SshStreamDataReceived(_)) => EventLane::Data,
        _ => EventLane::NormalControl,
    }
}

fn unix_timestamp_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// 返回当前 ABI 版本号。
#[no_mangle]
pub extern "C" fn ssh_net_abi_version() -> u32 {
    SSH_NET_ABI_VERSION
}

/// 创建新的 NetworkRuntime 实例。
/// 成功返回 0，失败返回负错误码。
/// 输出句柄写入 `out_handle`。
///
/// # Safety
/// `out_handle` 必须是有效且非空、可接收运行时句柄的指针。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_create(out_handle: *mut SshNetRuntimeHandle) -> i32 {
    if out_handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| match SshNetRuntime::new() {
        Ok(runtime) => {
            let boxed = Box::new(runtime);
            let raw = Box::into_raw(boxed) as SshNetRuntimeHandle;
            unsafe {
                *out_handle = raw;
            }
            0
        }
        Err(_) => -2,
    });

    result.unwrap_or(-99)
}

/// 启动/激活网络运行时操作。
/// 成功返回 0，失败返回负错误码。
///
/// # Safety
/// `handle` 必须是由 `ssh_net_runtime_create` 创建的有效指针。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_start(handle: SshNetRuntimeHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        match runtime.runtime.start() {
            Ok(()) => 0,
            Err(_) => -3,
        }
    });

    result.unwrap_or(-99)
}

/// 查询 native QUIC endpoint 实际绑定的 UDP 端口。
///
/// 返回正数表示已完成配置，返回 0 表示 runtime 尚未完成配置；负值只表示
/// FFI 参数或内部 panic 错误，Dart facade 不会把这些原始整数暴露给调用方。
///
/// # Safety
/// `handle` 必须是由 `ssh_net_runtime_create` 创建的有效指针。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_local_port(handle: SshNetRuntimeHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        runtime.runtime.bound_local_port().map_or(0, i32::from)
    });

    result.unwrap_or(-99)
}

/// 停止运行时 worker。停止操作幂等，销毁句柄前必须调用。
///
/// # Safety
/// `handle` 必须是由 `ssh_net_runtime_create` 创建的有效指针。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_stop(handle: SshNetRuntimeHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        match runtime.stop() {
            Ok(()) => 0,
            Err(_) => -3,
        }
    });

    result.unwrap_or(-99)
}

/// 向运行时 worker 发送 Protobuf 编码的 NetworkCommand。
/// 成功返回 0，失败返回负错误码。
///
/// # Safety
/// `handle` 必须是有效运行时句柄。
/// `command_ptr` 必须指向 `command_len` 个编码 Protobuf 消息字节。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_command(
    handle: SshNetRuntimeHandle,
    command_ptr: *const u8,
    command_len: usize,
) -> i32 {
    if handle.is_null()
        || command_ptr.is_null()
        || command_len == 0
        || command_len > SSH_NET_MAX_COMMAND_BYTES
    {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        let slice = unsafe { slice::from_raw_parts(command_ptr, command_len) };

        match NetworkCommand::decode(slice) {
            Ok(cmd) => {
                if cmd.command_id.is_empty() || cmd.command_id.len() > 128 {
                    return -1;
                }
                if let Err(code) = runtime.remember_command(&cmd.command_id) {
                    return code;
                }
                let command_id = cmd.command_id.clone();
                match runtime.runtime.send_command(cmd) {
                    Ok(_) => 0,
                    Err(network_core::NetworkError::RuntimeNotRunning) => {
                        if let Ok(mut pending) = runtime.pending_commands.lock() {
                            pending.remove(&command_id);
                        }
                        -4
                    }
                    Err(_) => {
                        if let Ok(mut pending) = runtime.pending_commands.lock() {
                            pending.remove(&command_id);
                        }
                        -3
                    }
                }
            }
            Err(_) => -2,
        }
    });

    result.unwrap_or(-99)
}

/// 按超时轮询下一个 NetworkEvent。
/// 若有事件，将其序列化为 Protobuf 并写入 `out_event`。
/// 填充事件返回 1，超时或无事件返回 0，错误返回负值。
///
/// # Safety
/// 当 `out_event.ptr` 非空时，调用方必须使用 `ssh_net_buffer_free` 释放它。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_poll_event(
    handle: SshNetRuntimeHandle,
    timeout_ms: u32,
    out_event: *mut SshNetBuffer,
) -> i32 {
    if handle.is_null() || out_event.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        unsafe {
            (*out_event).ptr = std::ptr::null_mut();
            (*out_event).len = 0;
        }

        let synthetic = match runtime.synthetic_events.lock() {
            Ok(mut events) => events.pop(),
            Err(_) => return -3,
        };
        if let Some(event) = synthetic {
            let mut encoded = Vec::new();
            if event.encode(&mut encoded).is_err() || encoded.len() > SSH_NET_MAX_EVENT_BYTES {
                return -5;
            }
            let len = encoded.len();
            let mut boxed_slice = encoded.into_boxed_slice();
            let ptr = boxed_slice.as_mut_ptr();
            std::mem::forget(boxed_slice);
            unsafe {
                (*out_event).ptr = ptr;
                (*out_event).len = len;
            }
            return 1;
        }

        let drained_is_empty = match runtime.drained_events.lock() {
            Ok(events) => events.is_empty(),
            Err(_) => return -3,
        };
        if let Err(code) =
            runtime.drain_runtime_events(if drained_is_empty { timeout_ms } else { 0 })
        {
            return code;
        }

        let event = match runtime.drained_events.lock() {
            Ok(mut mux) => mux.pop(),
            Err(_) => return -3,
        };
        if let Some(event) = event {
            let mut encoded = Vec::new();
            if event.encode(&mut encoded).is_err() || encoded.len() > SSH_NET_MAX_EVENT_BYTES {
                return -5;
            }
            let len = encoded.len();
            let mut boxed_slice = encoded.into_boxed_slice();
            let ptr = boxed_slice.as_mut_ptr();
            std::mem::forget(boxed_slice);

            unsafe {
                (*out_event).ptr = ptr;
                (*out_event).len = len;
            }
            return 1;
        }
        0
    });

    result.unwrap_or(-99)
}

/// 释放由 Rust FFI 分配的缓冲区（例如 `ssh_net_runtime_poll_event` 返回的缓冲区）。
///
/// # Safety
/// `buffer.ptr` 必须来自 Rust FFI，释放后不得继续使用。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_buffer_free(buffer: SshNetBuffer) {
    if !buffer.ptr.is_null() {
        let _ = unsafe { Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.len) };
    }
}

/// 销毁 NetworkRuntime 实例并释放关联内存。
/// 成功返回 0，失败返回负错误码。
///
/// # Safety
/// `handle` 必须是由 `ssh_net_runtime_create` 创建的有效指针，调用后不得继续使用。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_destroy(handle: SshNetRuntimeHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        if runtime.stop().is_err() {
            return -3;
        }
        unsafe { drop(Box::from_raw(handle as *mut SshNetRuntime)) };
        0
    });

    result.unwrap_or(-99)
}

#[cfg(test)]
#[path = "tests/mod.rs"]
mod tests;

#[cfg(test)]
#[path = "tests/realtime_media.rs"]
mod realtime_media_tests;
