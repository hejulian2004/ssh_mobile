use network_protocol::{NetworkCommand, NetworkEvent};
use std::sync::{
    atomic::{AtomicU16, AtomicU8, Ordering},
    Arc, Mutex,
};
use std::time::Duration;
use tokio::sync::{mpsc, Notify};
use tracing::info;

use crate::commands::run_command_worker;
use crate::errors::NetworkError;
use crate::runtime_event_lanes::BoundedEventLanes;

use super::{
    NetworkRuntime, RuntimeState, COMMAND_MAILBOX_CAPACITY, RUNTIME_CREATED, RUNTIME_RUNNING,
    RUNTIME_STOPPED, RUNTIME_STOPPING,
};

impl NetworkRuntime {
    /// 创建运行时。调用 `start` 并提交配置命令后才开始使用网络；
    /// 生命周期转换前不会启动 worker。
    pub fn new() -> Result<Self, NetworkError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("ssh-net-worker")
            .build()
            .map_err(|error| NetworkError::RuntimeInitFailed(error.to_string()))?;
        let (event_tx, event_rx) = BoundedEventLanes::channel();
        let bound_port = Arc::new(AtomicU16::new(0));
        info!("NetworkRuntime initialized successfully");
        Ok(Self {
            runtime: Arc::new(runtime),
            command_tx: Mutex::new(None),
            event_rx: Arc::new(Mutex::new(event_rx)),
            event_tx,
            bound_port,
            lifecycle: AtomicU8::new(RUNTIME_CREATED),
            state: Mutex::new(None),
            stop_notify: Arc::new(Notify::new()),
        })
    }

    /// 将运行时从 Created 转换为 Running，并启动 worker。
    pub fn start(&self) -> Result<(), NetworkError> {
        self.lifecycle
            .compare_exchange(
                RUNTIME_CREATED,
                RUNTIME_RUNNING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| NetworkError::RuntimeNotRunning)?;
        let (command_tx, command_rx) = mpsc::channel::<NetworkCommand>(COMMAND_MAILBOX_CAPACITY);
        let state = Arc::new(RuntimeState::new(
            self.event_tx.clone(),
            Arc::clone(&self.bound_port),
        ));
        *self.state.lock().map_err(|_| {
            NetworkError::CommandQueueFailed("runtime state lock poisoned".into())
        })? = Some(Arc::clone(&state));
        let _runtime_guard = self.runtime.enter();
        if state
            .task_supervisor
            .spawn_runtime(
                "command-worker",
                run_command_worker(command_rx, Arc::clone(&state)),
            )
            .is_none()
        {
            return Err(NetworkError::RuntimeNotRunning);
        }
        *self
            .command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))? =
            Some(command_tx);
        Ok(())
    }

    /// 恰好停止 worker 一次；重复调用仍然成功。
    pub fn stop(&self) -> Result<(), NetworkError> {
        let current = self.lifecycle.load(Ordering::Acquire);
        if current == RUNTIME_CREATED || current == RUNTIME_STOPPED {
            self.bound_port.store(0, Ordering::Release);
            self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
            self.stop_notify.notify_waiters();
            return Ok(());
        }
        if current == RUNTIME_STOPPING {
            loop {
                let notified = self.stop_notify.notified();
                if self.lifecycle.load(Ordering::Acquire) != RUNTIME_STOPPING {
                    break;
                }
                self.runtime.block_on(notified);
            }
            return Ok(());
        }
        self.lifecycle
            .compare_exchange(
                RUNTIME_RUNNING,
                RUNTIME_STOPPING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| NetworkError::RuntimeNotRunning)?;
        self.command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))?
            .take();
        let state = self
            .state
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("runtime state lock poisoned".into()))?
            .take();
        if let Some(state) = state {
            self.shutdown_listener(state);
        }
        self.bound_port.store(0, Ordering::Release);
        self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
        self.stop_notify.notify_waiters();
        Ok(())
    }

    /// 返回 native QUIC endpoint 实际绑定的 UDP 端口。
    ///
    /// 该值只用于受控测试和诊断；调用方不会获得 socket 或 Quinn handle。
    pub fn bound_local_port(&self) -> Option<u16> {
        let port = self.bound_port.load(Ordering::Acquire);
        (port != 0).then_some(port)
    }

    /// Acquires an opaque native screen-media endpoint for a live Realtime
    /// session. The endpoint is bound to the current runtime/session generation
    /// and cannot expose the peer, socket, or media payload through this API.
    pub fn create_realtime_media_endpoint(
        &self,
        realtime_id: &str,
        peer_id: &str,
        direction: crate::realtime_media::RealtimeMediaDirection,
        expected_generation: u64,
    ) -> Result<
        crate::realtime_media::RealtimeMediaEndpointId,
        crate::realtime_media::RealtimeMediaError,
    > {
        let state = self.media_state()?;
        self.runtime
            .block_on(crate::realtime_media::create_endpoint(
                &state,
                realtime_id,
                peer_id,
                direction,
                expected_generation,
            ))
    }

    /// Test-only seam used by network-ffi to exercise the complete C ABI
    /// success path against a live native Realtime driver. It is excluded from
    /// normal builds and never exposes the driver or PeerConnection handle.
    #[cfg(feature = "ffi-test-support")]
    #[doc(hidden)]
    pub fn install_ffi_test_realtime_session(
        &self,
        realtime_id: &str,
        peer_id: &str,
    ) -> Result<u64, crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        self.runtime.block_on(async move {
            let mut driver = network_webrtc::RealtimeIoDriver::bind(
                network_webrtc::WebRtcPeer::new(network_webrtc::WebRtcConfig::default())
                    .map_err(|_| crate::realtime_media::RealtimeMediaError::DriverUnavailable)?,
                "127.0.0.1:0".parse().expect("valid loopback bind address"),
            )
            .await
            .map_err(|_| crate::realtime_media::RealtimeMediaError::DriverUnavailable)?;
            driver
                .peer_mut()
                .configure_h264_screen_video(
                    network_webrtc::MediaDirection::Sendrecv,
                    Some(0x1357_2468),
                )
                .map_err(|_| crate::realtime_media::RealtimeMediaError::DriverUnavailable)?;
            let driver = driver.into_handle();
            let mut manager = state.realtime.lock().await;
            Ok(manager.insert_ffi_test_driver_session(
                realtime_id.to_owned(),
                peer_id.to_owned(),
                driver,
            ))
        })
    }

    /// Test-only packet injection companion for
    /// [`install_ffi_test_realtime_session`]. Real callers receive RTP from
    /// the I/O driver; this only makes the pull half of the C ABI deterministic.
    #[cfg(feature = "ffi-test-support")]
    #[doc(hidden)]
    pub fn inject_ffi_test_realtime_media_frame(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
        frame: network_webrtc::EncodedVideoFrame,
    ) -> Result<(), crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        crate::realtime_media::inject_test_endpoint_frame(&state, endpoint_id, frame)
    }

    /// Releases an endpoint lease. Release remains idempotent after runtime
    /// stop because the registry has already invalidated every endpoint.
    pub fn release_realtime_media_endpoint(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
    ) -> Result<(), crate::realtime_media::RealtimeMediaError> {
        let state = self
            .state
            .lock()
            .map_err(|_| crate::realtime_media::RealtimeMediaError::Internal)?
            .clone();
        let Some(state) = state else {
            return Ok(());
        };
        crate::realtime_media::release_endpoint(&state, endpoint_id)
    }

    /// Validates a platform-owner capability against the existing endpoint
    /// lease without changing queue or lifecycle state.
    pub fn validate_realtime_media_endpoint(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
        realtime_id: &str,
        peer_id: &str,
        generation: u64,
        direction: crate::realtime_media::RealtimeMediaDirection,
    ) -> Result<(), crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        crate::realtime_media::validate_endpoint(
            &state,
            endpoint_id,
            realtime_id,
            peer_id,
            generation,
            direction,
        )
    }

    /// Submits a native-resident encoded H.264 access unit to a send endpoint.
    pub fn push_realtime_media_h264(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
        frame: network_webrtc::EncodedVideoFrame,
    ) -> Result<network_webrtc::VideoEnqueueResult, crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        crate::realtime_media::push_endpoint(&state, endpoint_id, frame)
    }

    /// Reads one native-resident encoded H.264 access unit from a receive
    /// endpoint. It never routes through the protobuf event queue.
    pub fn pop_realtime_media_h264(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
    ) -> Result<Option<network_webrtc::EncodedVideoFrame>, crate::realtime_media::RealtimeMediaError>
    {
        let state = self.media_state()?;
        crate::realtime_media::pop_endpoint(&state, endpoint_id)
    }

    /// Requests a keyframe through a generation-bound native media owner.
    ///
    /// The request is coalesced by the native screen-video queue; no media
    /// payload or WebRTC object crosses the endpoint boundary.
    pub fn request_realtime_media_keyframe(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
    ) -> Result<(), crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        crate::realtime_media::request_keyframe(&state, endpoint_id)
    }

    /// Resets a generation-bound receive decoder and drops stale access units.
    pub fn reset_realtime_media_decoder(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
    ) -> Result<(), crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        crate::realtime_media::reset_decoder(&state, endpoint_id)
    }

    /// Applies one bounded sender target through the native H.264 peer owner.
    /// Platform adapters apply the same target to their hardware encoder while
    /// the peer retains it for this generation.
    pub fn apply_realtime_media_adaptation(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
        target: network_webrtc::H264AdaptationTarget,
    ) -> Result<(), crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        crate::realtime_media::apply_adaptation(&state, endpoint_id, target)
    }

    /// Reads bounded native queue/recovery counters for one generation-bound
    /// screen-media endpoint. The snapshot contains no media payload.
    pub fn read_realtime_media_stats(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
    ) -> Result<network_webrtc::H264ScreenVideoStats, crate::realtime_media::RealtimeMediaError>
    {
        let state = self.media_state()?;
        crate::realtime_media::stats(&state, endpoint_id)
    }

    /// 返回原生轮询边界使用的 Tokio handle。
    pub fn handle(&self) -> &tokio::runtime::Handle {
        self.runtime.handle()
    }

    /// 运行时处于 Running 时入队一个 V2 命令。
    pub fn send_command(&self, command: NetworkCommand) -> Result<(), NetworkError> {
        if self.lifecycle.load(Ordering::Acquire) != RUNTIME_RUNNING {
            return Err(NetworkError::RuntimeNotRunning);
        }
        let sender = self
            .command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))?
            .as_ref()
            .ok_or(NetworkError::RuntimeNotRunning)?
            .clone();
        sender.try_send(command).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => {
                NetworkError::CommandQueueFailed("command mailbox is full".into())
            }
            mpsc::error::TrySendError::Closed(_) => {
                NetworkError::CommandQueueFailed("command mailbox is closed".into())
            }
        })
    }

    /// 轮询一个事件，但不向调用方暴露内部 receiver。
    pub fn poll_event(&self, timeout_ms: u32) -> Option<NetworkEvent> {
        let mut receiver = self.event_rx.lock().ok()?;
        if timeout_ms == 0 {
            receiver.try_recv()
        } else {
            let handle = self.runtime.handle();
            let _guard = handle.enter();
            handle
                .block_on(tokio::time::timeout(
                    Duration::from_millis(timeout_ms as u64),
                    receiver.recv(),
                ))
                .ok()?
        }
    }

    /// 为原生测试和受控集成注入一个事件。
    pub fn emit_event(&self, event: NetworkEvent) {
        let _ = self.event_tx.send(event);
    }

    fn media_state(&self) -> Result<Arc<RuntimeState>, crate::realtime_media::RealtimeMediaError> {
        if self.lifecycle.load(Ordering::Acquire) != RUNTIME_RUNNING {
            return Err(crate::realtime_media::RealtimeMediaError::RuntimeNotRunning);
        }
        self.state
            .lock()
            .map_err(|_| crate::realtime_media::RealtimeMediaError::Internal)?
            .clone()
            .ok_or(crate::realtime_media::RealtimeMediaError::RuntimeNotRunning)
    }

    /// Cancel the root, close every native I/O owner, then await every task
    /// registered in the supervisor before releasing the runtime state.
    fn shutdown_listener(&self, state: Arc<RuntimeState>) {
        self.runtime.block_on(async move {
            state.task_supervisor.cancel_root();
            crate::realtime_media::invalidate_all(&state);
            state.peer_supervisors.stop_all();
            state.close_all_transport_paths().await;
            // 控制面 Drop 会中止后台读写 worker（RelayControlClient::drop）；显式
            // take 释放共享引用即可。
            state.relay.control.write().await.take();
            state.realtime.lock().await.close_all();
            // A caller that observed `Running` immediately before `stop()`
            // moved the lifecycle to Stopping can still hold a cloned state.
            // Revoke again after the terminal peer close so that race cannot
            // publish a fresh endpoint into a stopped runtime generation.
            crate::realtime_media::invalidate_all(&state);
            if let Some(endpoint) = state.lifecycle.endpoint.write().await.take() {
                endpoint.close(quinn::VarInt::from_u32(0), b"runtime stopping");
            }
            state.task_supervisor.shutdown().await;
        });
    }

    /// 仅测试用：为当前 Peer 显式驱动一次确定性 recovery，返回其 wire key。
    ///
    /// 测试在连接保持稳定时显式重放未 ACK 消息，验证接收端按 MessageId 去重。
    /// 重放会以当前 ConnectionSession 重新编码发送（§20），不依赖生产重连路径。
    #[cfg(test)]
    pub(crate) fn recover_current_peer_for_test(&self, peer_id: &str) -> Option<String> {
        let state = self
            .state
            .lock()
            .expect("runtime state lock")
            .clone()
            .expect("runtime state");
        self.runtime.block_on(async move {
            let session_id = state
                .connection_sessions
                .current_session_id(peer_id)
                .await?;
            let wire_key = session_id.wire_key();
            crate::channel::recover_session(Arc::clone(&state), peer_id.to_string()).await;
            Some(wire_key)
        })
    }
}

/// Rust 侧最终销毁时中止仍存在的 supervised tasks。
impl Drop for NetworkRuntime {
    /// 中止在显式停止转换后仍存活的 tasks。
    fn drop(&mut self) {
        if let Ok(mut sender) = self.command_tx.lock() {
            sender.take();
        }
        if let Ok(mut state) = self.state.lock() {
            if let Some(state) = state.take() {
                if let Ok(mut endpoint) = state.lifecycle.endpoint.try_write() {
                    if let Some(endpoint) = endpoint.take() {
                        endpoint.close(quinn::VarInt::from_u32(0), b"runtime dropped");
                    }
                }
                if let Ok(mut realtime) = state.realtime.try_lock() {
                    crate::realtime_media::invalidate_all(&state);
                    realtime.close_all();
                }
                state.peer_supervisors.stop_all();
                state.task_supervisor.abort_all_now();
            }
        }
        self.bound_port.store(0, Ordering::Release);
        self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
        self.stop_notify.notify_waiters();
    }
}
