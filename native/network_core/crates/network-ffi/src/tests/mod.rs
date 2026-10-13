use super::*;
use network_protocol::{
    network_command, network_event, ChannelMessageEvent, CommandResult, CommandResultEvent,
    CommandResultState, NetworkCommand, NetworkEvent, PeerStateChangedEvent,
    PeerTransferProgressEvent, RealtimeSessionState, RealtimeSignalEvent, RealtimeSignalKind,
    RealtimeStateChangedEvent, RelayStateChangedEvent, SshStreamClosedEvent, SshStreamDataCommand,
    SshStreamDataReceivedEvent, SshStreamOpenCommand, StartRealtimeSessionCommand, StreamHandle,
    TransferProgressEvent, NETWORK_PROTOCOL_VERSION,
};
use prost::Message;
use std::mem::{align_of, offset_of, size_of};
use std::ptr;

/// 验证 V2 FFI 对空句柄和空 buffer 的确定性拒绝。
#[test]
fn rejects_invalid_buffers_without_panicking() {
    assert_eq!(ssh_net_abi_version(), SSH_NET_ABI_VERSION);
    assert_eq!(unsafe { ssh_net_runtime_create(ptr::null_mut()) }, -1);
    assert_eq!(unsafe { ssh_net_runtime_start(ptr::null_mut()) }, -1);
    assert_eq!(unsafe { ssh_net_runtime_stop(ptr::null_mut()) }, -1);
    assert_eq!(unsafe { ssh_net_runtime_local_port(ptr::null_mut()) }, -1);
    assert_eq!(
        unsafe { ssh_net_runtime_command(ptr::null_mut(), ptr::null(), 0) },
        -1
    );
    assert_eq!(
        unsafe { ssh_net_runtime_poll_event(ptr::null_mut(), 1, ptr::null_mut()) },
        -1
    );
    assert_eq!(unsafe { ssh_net_runtime_destroy(ptr::null_mut()) }, -1);
    unsafe {
        ssh_net_buffer_free(SshNetBuffer {
            ptr: ptr::null_mut(),
            len: 0,
        });
    }
}

#[test]
fn ffi_buffer_keeps_the_c_layout_and_free_contract() {
    assert_eq!(offset_of!(SshNetBuffer, ptr), 0);
    assert_eq!(offset_of!(SshNetBuffer, len), size_of::<*mut u8>(),);
    assert_eq!(
        size_of::<SshNetBuffer>(),
        size_of::<*mut u8>() + size_of::<usize>(),
    );
    assert_eq!(
        align_of::<SshNetBuffer>(),
        align_of::<*mut u8>().max(align_of::<usize>()),
    );

    let bytes = vec![1_u8, 2, 3].into_boxed_slice();
    let buffer = SshNetBuffer {
        ptr: Box::into_raw(bytes) as *mut u8,
        len: 3,
    };
    unsafe { ssh_net_buffer_free(buffer) };
}

/// 验证 V2 运行时的创建、启动、重复停止、停止后命令和销毁顺序。
#[test]
fn enforces_runtime_lifecycle_order() {
    let mut handle = ptr::null_mut();
    assert_eq!(unsafe { ssh_net_runtime_create(&mut handle) }, 0);
    assert!(!handle.is_null());
    assert_eq!(unsafe { ssh_net_runtime_local_port(handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_start(handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_local_port(handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_stop(handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_local_port(handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_stop(handle) }, 0);
    let command = NetworkCommand {
        command_id: "stopped-command".to_string(),
        protocol_version: network_protocol::NETWORK_PROTOCOL_VERSION,
        payload: None,
    }
    .encode_to_vec();
    assert_eq!(
        unsafe { ssh_net_runtime_command(handle, command.as_ptr(), command.len()) },
        -4
    );
    assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
}

/// 验证新增 Realtime 命令和事件沿用现有 FFI Protobuf 边界，
/// 不暴露 WebRTC 原生句柄或内部类型。
#[test]
fn carries_realtime_commands_and_events_through_the_ffi_wire() {
    let command = NetworkCommand {
        command_id: "realtime-start".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::StartRealtimeSession(
            StartRealtimeSessionCommand {
                screen_video: false,
                realtime_id: "00112233445566778899aabbccddeeff".into(),
                peer_id: "peer-a".into(),
            },
        )),
    };
    let decoded_command = NetworkCommand::decode(command.encode_to_vec().as_slice())
        .expect("decode realtime command");
    assert!(matches!(
        decoded_command.payload,
        Some(network_command::Payload::StartRealtimeSession(_))
    ));

    let event = NetworkEvent {
        event_id: "realtime-event".into(),
        timestamp_ms: 123,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RealtimeSignal(
            RealtimeSignalEvent {
                realtime_id: "00112233445566778899aabbccddeeff".into(),
                peer_id: "peer-a".into(),
                kind: RealtimeSignalKind::WebRtcOffer as i32,
                revision: 1,
                payload: b"v=0\r\n".to_vec(),
            },
        )),
    };
    let decoded_event =
        NetworkEvent::decode(event.encode_to_vec().as_slice()).expect("decode realtime event");
    match decoded_event.payload {
        Some(network_event::Payload::RealtimeSignal(signal)) => {
            assert_eq!(signal.kind, RealtimeSignalKind::WebRtcOffer as i32);
            assert_eq!(signal.payload, b"v=0\r\n");
        }
        Some(network_event::Payload::RealtimeState(RealtimeStateChangedEvent {
            state, ..
        })) => assert_eq!(state, RealtimeSessionState::Connected as i32),
        other => panic!("unexpected realtime event payload: {other:?}"),
    }
}

#[test]
fn realtime_failure_returns_a_terminal_result_through_the_live_ffi_runtime() {
    let mut handle = ptr::null_mut();
    assert_eq!(unsafe { ssh_net_runtime_create(&mut handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_start(handle) }, 0);
    let command = NetworkCommand {
        command_id: "realtime-start-ffi-result".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::StartRealtimeSession(
            StartRealtimeSessionCommand {
                screen_video: false,
                realtime_id: "00112233445566778899aabbccddeeff".into(),
                peer_id: "missing-peer".into(),
            },
        )),
    }
    .encode_to_vec();
    assert_eq!(
        unsafe { ssh_net_runtime_command(handle, command.as_ptr(), command.len()) },
        0
    );

    let mut buffer = SshNetBuffer {
        ptr: ptr::null_mut(),
        len: 0,
    };
    assert_eq!(
        unsafe { ssh_net_runtime_poll_event(handle, 1000, &mut buffer) },
        1
    );
    let encoded = unsafe { std::slice::from_raw_parts(buffer.ptr, buffer.len) };
    let event = NetworkEvent::decode(encoded).expect("command result event");
    let Some(network_event::Payload::CommandResultV2(result)) = event.payload else {
        panic!("expected CommandResultV2");
    };
    assert_eq!(result.command_id, "realtime-start-ffi-result");
    assert_eq!(result.peer_id, "missing-peer");
    assert_eq!(result.state, CommandResultState::Failed as i32);
    assert_eq!(
        result.error.expect("NoRoute error").code,
        NetworkErrorCode::NoRoute as i32
    );
    unsafe { ssh_net_buffer_free(buffer) };
    assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
}

/// 验证 ReliableStream（§17）的 SSH 字节流命令与事件沿用现有 FFI Protobuf
/// 边界，不暴露内部 stream handle 或类型。
#[test]
fn carries_ssh_stream_commands_and_events_through_the_ffi_wire() {
    let handle = StreamHandle {
        opener_device_id: "device-a".into(),
        stream_id: 3,
    };
    let open = NetworkCommand {
        command_id: "ssh-open".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamOpen(
            SshStreamOpenCommand {
                peer_id: "peer-a".into(),
                handle: Some(handle.clone()),
                service: "ssh".into(),
            },
        )),
    };
    let decoded =
        NetworkCommand::decode(open.encode_to_vec().as_slice()).expect("decode ssh stream open");
    match decoded.payload {
        Some(network_command::Payload::SshStreamOpen(open)) => {
            assert_eq!(open.peer_id, "peer-a");
            assert_eq!(open.handle.as_ref().map(|handle| handle.stream_id), Some(3));
            assert_eq!(
                open.handle
                    .as_ref()
                    .map(|handle| handle.opener_device_id.as_str()),
                Some("device-a")
            );
            assert_eq!(open.service, "ssh");
        }
        other => panic!("unexpected command payload: {other:?}"),
    }

    let data = NetworkCommand {
        command_id: "ssh-data".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamData(
            SshStreamDataCommand {
                peer_id: "peer-a".into(),
                handle: Some(handle.clone()),
                data: b"SSH".to_vec(),
            },
        )),
    };
    let decoded =
        NetworkCommand::decode(data.encode_to_vec().as_slice()).expect("decode ssh stream data");
    assert!(matches!(
        decoded.payload,
        Some(network_command::Payload::SshStreamData(data)) if data.handle.as_ref().is_some_and(|handle| handle.stream_id == 3 && handle.opener_device_id == "device-a") && data.data == b"SSH"
    ));

    let received = NetworkEvent {
        event_id: "ssh-recv".into(),
        timestamp_ms: 123,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::SshStreamDataReceived(
            SshStreamDataReceivedEvent {
                peer_id: "peer-a".into(),
                handle: Some(handle.clone()),
                data: b"reply".to_vec(),
            },
        )),
    };
    let decoded =
        NetworkEvent::decode(received.encode_to_vec().as_slice()).expect("decode ssh stream event");
    match decoded.payload {
        Some(network_event::Payload::SshStreamDataReceived(recv)) => {
            assert_eq!(recv.handle.as_ref().map(|handle| handle.stream_id), Some(3));
            assert_eq!(
                recv.handle
                    .as_ref()
                    .map(|handle| handle.opener_device_id.as_str()),
                Some("device-a")
            );
            assert_eq!(recv.data, b"reply");
        }
        other => panic!("unexpected event payload: {other:?}"),
    }

    let closed = NetworkEvent {
        event_id: "ssh-closed".into(),
        timestamp_ms: 124,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::SshStreamClosed(
            SshStreamClosedEvent {
                peer_id: "peer-a".into(),
                handle: Some(handle.clone()),
            },
        )),
    };
    let decoded = NetworkEvent::decode(closed.encode_to_vec().as_slice())
        .expect("decode ssh stream closed event");
    assert!(matches!(
        decoded.payload,
        Some(network_event::Payload::SshStreamClosed(closed)) if closed.handle.as_ref().is_some_and(|handle| handle.stream_id == 3 && handle.opener_device_id == "device-a")
    ));
}

#[test]
fn data_flood_cannot_starve_critical_control() {
    let mut mux = EventMux::new();
    for value in 0..(SSH_NET_MAX_DATA_ITEMS * 4) {
        assert!(mux.enqueue(value, EventLane::Data, 1));
    }
    assert!(mux.enqueue(100, EventLane::CriticalControl, 1));
    assert_eq!(mux.pop(), Some(100));
}

#[test]
fn eight_control_fairness() {
    let mut mux = EventMux::new();
    for value in 0..10 {
        assert!(mux.enqueue(value, EventLane::CriticalControl, 1));
    }
    assert!(mux.enqueue(100, EventLane::Data, 1));

    for expected in 0..8 {
        assert_eq!(mux.pop(), Some(expected));
    }
    assert_eq!(mux.pop(), Some(100));
    assert_eq!(mux.pop(), Some(8));
    assert_eq!(mux.pop(), Some(9));
}

#[test]
fn control_byte_limit() {
    let mut mux = EventMux::new();
    for value in 0..4 {
        assert!(mux.enqueue(value, EventLane::NormalControl, SSH_NET_MAX_EVENT_BYTES));
    }
    assert_eq!(mux.control_items(), 4);
    assert_eq!(mux.control_bytes(), SSH_NET_MAX_CONTROL_BYTES);
    assert!(!mux.enqueue(4, EventLane::CriticalControl, SSH_NET_MAX_EVENT_BYTES));
    assert_eq!(mux.control_items(), 4);
    assert_eq!(mux.control_bytes(), SSH_NET_MAX_CONTROL_BYTES);
}

#[test]
fn data_byte_limit() {
    let mut mux = EventMux::new();
    for value in 0..9 {
        assert!(mux.enqueue(value, EventLane::Data, SSH_NET_MAX_EVENT_BYTES));
    }
    assert_eq!(mux.data_items(), 8);
    assert_eq!(mux.data_bytes(), SSH_NET_MAX_DATA_BYTES);
    assert_eq!(mux.pop(), Some(1));
}

#[test]
fn single_event_limit() {
    let mut mux = EventMux::new();
    assert!(!mux.enqueue(1, EventLane::CriticalControl, SSH_NET_MAX_EVENT_BYTES + 1));
    assert!(mux.is_empty());
}

#[test]
fn event_mux_releases_normal_control_bytes_and_falls_back_after_data() {
    let mut mux = EventMux::new();
    assert!(mux.enqueue(1, EventLane::NormalControl, 4));
    assert_eq!(mux.pop(), Some(1));
    assert_eq!(mux.control_bytes(), 0);

    for value in 0..4 {
        assert!(mux.enqueue(value, EventLane::NormalControl, SSH_NET_MAX_EVENT_BYTES));
    }
    assert!(!mux.enqueue(4, EventLane::NormalControl, SSH_NET_MAX_EVENT_BYTES));
    while mux.pop().is_some() {}

    let mut mux = EventMux::new();
    for value in 0..SSH_NET_MAX_CONSECUTIVE_CONTROL_EVENTS {
        assert!(mux.enqueue(value, EventLane::CriticalControl, 1));
    }
    assert!(mux.enqueue(99, EventLane::Data, 1));
    for _ in 0..SSH_NET_MAX_CONSECUTIVE_CONTROL_EVENTS {
        assert!(mux.pop().is_some());
    }
    assert_eq!(mux.pop(), Some(99));
    assert!(mux.is_empty());
}

#[test]
fn ffi_terminal_command_results_are_deduplicated() {
    let runtime = SshNetRuntime::new().expect("runtime");
    runtime
        .pending_commands
        .lock()
        .expect("pending lock")
        .insert("command-a".into());
    let event = NetworkEvent {
        event_id: "command-a/result".into(),
        timestamp_ms: 1,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::CommandResult(CommandResultEvent {
            command_id: "command-a".into(),
            accepted: true,
            error: None,
        })),
    };

    assert!(runtime.admit_event(event.clone()).is_some());
    assert!(runtime.admit_event(event).is_none());
    assert!(runtime
        .terminal_commands
        .lock()
        .expect("terminal lock")
        .contains("command-a"));

    let v2 = NetworkEvent {
        payload: Some(network_event::Payload::CommandResultV2(CommandResult {
            command_id: "command-v2".into(),
            ..Default::default()
        })),
        ..Default::default()
    };
    assert!(runtime.admit_event(v2.clone()).is_some());
    assert!(runtime.admit_event(v2).is_none());
}

#[test]
fn ffi_pending_commands_have_a_frozen_resource_cap() {
    let runtime = SshNetRuntime::new().expect("runtime");
    for index in 0..SSH_NET_MAX_PENDING_COMMANDS {
        assert!(runtime
            .remember_command(&format!("command-{index}"))
            .is_ok());
    }
    assert_eq!(runtime.remember_command("command-over-cap"), Err(-7));
    assert_eq!(runtime.remember_command("command-0"), Err(-6));
}

#[test]
fn ffi_terminal_command_history_is_bounded_and_evicts_oldest_ids() {
    let mut history = BoundedCommandHistory::new();
    for index in 0..=SSH_NET_MAX_TERMINAL_COMMANDS {
        assert!(history.insert(format!("terminal-{index}")));
    }

    assert_eq!(history.len(), SSH_NET_MAX_TERMINAL_COMMANDS);
    assert!(!history.contains("terminal-0"));
    assert!(history.contains(&format!("terminal-{SSH_NET_MAX_TERMINAL_COMMANDS}")));
    assert!(!history.insert(format!("terminal-{SSH_NET_MAX_TERMINAL_COMMANDS}")));
}

#[test]
fn stopping_runtime_synthesizes_one_cancelled_result_for_pending_commands() {
    let runtime = SshNetRuntime::new().expect("runtime");
    runtime
        .pending_commands
        .lock()
        .expect("pending lock")
        .insert("command-a".into());
    runtime.cancel_pending_commands();
    let event = runtime
        .synthetic_events
        .lock()
        .expect("event lock")
        .pop()
        .expect("cancelled event");
    let Some(network_event::Payload::CommandResult(result)) = event.payload else {
        panic!("expected command result");
    };
    assert_eq!(result.command_id, "command-a");
    assert!(!result.accepted);
    assert_eq!(
        result.error.expect("cancel error").code,
        NetworkErrorCode::Cancelled as i32
    );
}

#[test]
fn event_lane_keeps_control_and_data_priority_classification_explicit() {
    let cases = [
        (
            network_event::Payload::CommandResult(CommandResultEvent::default()),
            EventLane::CriticalControl,
        ),
        (
            network_event::Payload::CommandResultV2(CommandResult::default()),
            EventLane::CriticalControl,
        ),
        (
            network_event::Payload::PeerState(PeerStateChangedEvent::default()),
            EventLane::CriticalControl,
        ),
        (
            network_event::Payload::RelayStateChanged(RelayStateChangedEvent::default()),
            EventLane::CriticalControl,
        ),
        (
            network_event::Payload::TransferProgress(TransferProgressEvent::default()),
            EventLane::Data,
        ),
        (
            network_event::Payload::PeerTransferProgress(PeerTransferProgressEvent::default()),
            EventLane::Data,
        ),
        (
            network_event::Payload::ChannelMessage(ChannelMessageEvent::default()),
            EventLane::Data,
        ),
        (
            network_event::Payload::SshStreamDataReceived(SshStreamDataReceivedEvent::default()),
            EventLane::Data,
        ),
        (
            network_event::Payload::RouteChanged(Default::default()),
            EventLane::NormalControl,
        ),
    ];
    for (payload, expected) in cases {
        assert_eq!(
            event_lane(&NetworkEvent {
                payload: Some(payload),
                ..Default::default()
            }),
            expected
        );
    }
}

#[test]
fn ffi_runtime_poll_serializes_synthetic_events_and_reports_empty_queue() {
    let runtime = Box::new(SshNetRuntime::new().expect("runtime"));
    let handle = Box::into_raw(runtime) as SshNetRuntimeHandle;
    let runtime_ref = unsafe { &*(handle as *const SshNetRuntime) };
    let event = NetworkEvent {
        event_id: "synthetic-state".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerState(
            PeerStateChangedEvent::default(),
        )),
        ..Default::default()
    };
    let bytes = event.encode_to_vec().len();
    assert!(runtime_ref
        .synthetic_events
        .lock()
        .expect("synthetic lock")
        .enqueue(event, EventLane::CriticalControl, bytes));

    let mut buffer = SshNetBuffer {
        ptr: std::ptr::null_mut(),
        len: 0,
    };
    assert_eq!(
        unsafe { ssh_net_runtime_poll_event(handle, 0, &mut buffer) },
        1
    );
    assert!(!buffer.ptr.is_null());
    let encoded = unsafe { std::slice::from_raw_parts(buffer.ptr, buffer.len) };
    let decoded = NetworkEvent::decode(encoded).expect("synthetic event decode");
    assert_eq!(decoded.event_id, "synthetic-state");
    unsafe { ssh_net_buffer_free(buffer) };

    let mut empty = SshNetBuffer {
        ptr: std::ptr::null_mut(),
        len: 0,
    };
    assert_eq!(
        unsafe { ssh_net_runtime_poll_event(handle, 0, &mut empty) },
        0
    );

    runtime_ref.runtime.emit_event(NetworkEvent {
        event_id: "drained-state".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerState(
            PeerStateChangedEvent::default(),
        )),
        ..Default::default()
    });
    assert_eq!(
        unsafe { ssh_net_runtime_poll_event(handle, 0, &mut empty) },
        1
    );
    assert!(!empty.ptr.is_null());
    unsafe { ssh_net_buffer_free(empty) };

    let oversized = NetworkEvent {
        payload: Some(network_event::Payload::ChannelMessage(
            ChannelMessageEvent {
                payload: vec![0; SSH_NET_MAX_EVENT_BYTES],
                ..Default::default()
            },
        )),
        ..Default::default()
    };
    assert!(runtime_ref
        .synthetic_events
        .lock()
        .expect("synthetic lock")
        .enqueue(oversized, EventLane::CriticalControl, 0));
    let mut oversized_buffer = SshNetBuffer {
        ptr: std::ptr::null_mut(),
        len: 0,
    };
    assert_eq!(
        unsafe { ssh_net_runtime_poll_event(handle, 0, &mut oversized_buffer) },
        -5
    );
    assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
}

#[test]
fn ffi_command_boundary_rejects_malformed_and_duplicate_ids() {
    assert_eq!(ssh_net_abi_version(), SSH_NET_ABI_VERSION);
    let mut handle = std::ptr::null_mut();
    assert_eq!(unsafe { ssh_net_runtime_create(&mut handle) }, 0);

    let malformed = [0xff_u8];
    assert_eq!(
        unsafe { ssh_net_runtime_command(handle, malformed.as_ptr(), malformed.len()) },
        -2
    );
    let empty_id = NetworkCommand {
        command_id: String::new(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: None,
    }
    .encode_to_vec();
    assert_eq!(
        unsafe { ssh_net_runtime_command(handle, empty_id.as_ptr(), empty_id.len()) },
        -1
    );

    assert_eq!(unsafe { ssh_net_runtime_start(handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_start(handle) }, -3);
    let command = NetworkCommand {
        command_id: "duplicate-command".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: None,
    }
    .encode_to_vec();
    assert_eq!(
        unsafe { ssh_net_runtime_command(handle, command.as_ptr(), command.len()) },
        0
    );
    assert_eq!(
        unsafe { ssh_net_runtime_command(handle, command.as_ptr(), command.len()) },
        -6
    );
    assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
}
