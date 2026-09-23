use std::collections::VecDeque;
use std::sync::Arc;

use tokio::sync::{watch, Mutex};

use crate::connect::PathLease;
use crate::events::emit_stream_closed;
use crate::runtime::EventSender;

use super::super::{StreamError, MAX_CONCURRENT_STREAMS, MAX_SERVICE_BYTES};
use super::{
    StreamConsumer, StreamEntry, StreamKey, StreamOpener, StreamState, MAX_RETIRED_STREAM_KEYS,
};

impl super::ReliableStreamManager {
    pub(crate) fn new<S: Into<EventSender>>(event_tx: S) -> Self {
        Self {
            inner: Arc::new(Mutex::new(StreamState::default())),
            event_tx: event_tx.into(),
        }
    }

    pub(crate) async fn active_count(&self) -> u32 {
        self.inner.lock().await.streams.len().min(u32::MAX as usize) as u32
    }

    pub(crate) async fn open(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        service: &str,
        consumer: StreamConsumer,
    ) -> Result<(), StreamError> {
        if service.is_empty() || service.len() > MAX_SERVICE_BYTES {
            return Err(StreamError::InvalidArgument);
        }
        let mut state = self.inner.lock().await;
        if state.streams.len() >= MAX_CONCURRENT_STREAMS {
            return Err(StreamError::CapacityExceeded);
        }
        let key = StreamKey::new(opener, stream_id);
        if state.streams.contains_key(&key) {
            return Err(StreamError::AlreadyOpen);
        }
        if state.retired.contains(&key) {
            return Err(StreamError::Closed);
        }
        if state.retired.len() >= MAX_RETIRED_STREAM_KEYS {
            return Err(StreamError::CapacityExceeded);
        }
        let (wake_tx, _) = watch::channel(0u64);
        state.streams.insert(
            key,
            StreamEntry {
                consumer,
                recv_chunks: VecDeque::new(),
                recv_bytes: 0,
                recv_closed: false,
                next_recv_seq: 0,
                wake_tx,
                wake_gen: 0,
                quic_send: None,
                next_send_seq: 0,
                send_closed: false,
                send_lock: Arc::new(Mutex::new(())),
                path_lease: None,
            },
        );
        Ok(())
    }

    /// Stores the one path lease that belongs to this stream's entire
    /// Open..Close lifetime.
    pub(crate) async fn bind_lease(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        lease: PathLease,
    ) -> Result<(), StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.path_lease.is_some() {
            return Err(StreamError::AlreadyOpen);
        }
        entry.path_lease = Some(lease);
        Ok(())
    }

    pub(crate) async fn take_lease(
        &self,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<PathLease, StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        entry.path_lease.take().ok_or(StreamError::NotConnected)
    }

    pub(crate) async fn restore_lease(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        lease: PathLease,
    ) -> bool {
        let mut state = self.inner.lock().await;
        let Some(entry) = state.streams.get_mut(&StreamKey::new(opener, stream_id)) else {
            return false;
        };
        if entry.recv_closed || entry.path_lease.is_some() {
            return false;
        }
        entry.path_lease = Some(lease);
        true
    }

    #[cfg(test)]
    pub(crate) async fn has_lease(&self, opener: StreamOpener, stream_id: u16) -> bool {
        let state = self.inner.lock().await;
        state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .is_some_and(|entry| entry.path_lease.is_some())
    }

    /// Inbound StreamOpen: register the remote-opened stream.
    pub(crate) async fn handle_open(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        service: &str,
        consumer: StreamConsumer,
    ) -> Result<(), StreamError> {
        self.open(opener, stream_id, service, consumer).await
    }

    /// Inbound StreamClose / QUIC EOF: mark the receive side closed and wake
    /// consumers. Bridge/Poll consumers observe EOF through `receive` returning
    /// 0; the Event-mode `SshStreamClosed` event is emitted by the per-stream
    /// drainer after the buffer is emptied, so data events always precede the
    /// close event (设计 §17 顺序保证).
    pub(crate) async fn handle_close(
        &self,
        peer_id: &str,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<(), StreamError> {
        {
            let mut state = self.inner.lock().await;
            let key = StreamKey::new(opener, stream_id);
            let Some(entry) = state.streams.get_mut(&key) else {
                return Ok(());
            };
            if entry.recv_closed {
                return Ok(());
            }
            entry.recv_closed = true;
            entry.wake();
            if entry.send_closed {
                state.streams.remove(&key);
                if state.retired.len() < MAX_RETIRED_STREAM_KEYS {
                    state.retired.insert(key);
                }
            }
        }
        let _ = peer_id;
        Ok(())
    }

    /// Local close: mark the send side closed and remove the entry once both
    /// sides are finished. The local caller initiated the close so no event is
    /// emitted here; the app was already told when the peer closed (Event mode)
    /// or the bridge/API consumer observed EOF.
    pub(crate) async fn close_local(
        &self,
        peer_id: &str,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<(), StreamError> {
        let removed = {
            let mut state = self.inner.lock().await;
            let key = StreamKey::new(opener, stream_id);
            let Some(entry) = state.streams.get_mut(&key) else {
                return Ok(());
            };
            if entry.send_closed {
                return Ok(());
            }
            entry.send_closed = true;
            entry.wake();
            let removed = entry.recv_closed;
            if removed {
                state.streams.remove(&key);
                if state.retired.len() < MAX_RETIRED_STREAM_KEYS {
                    state.retired.insert(key);
                }
            }
            removed
        };
        let _ = removed;
        let _ = peer_id;
        Ok(())
    }

    #[allow(dead_code)] // test/diagnostic query surface
    pub(crate) async fn is_open(&self, opener: StreamOpener, stream_id: u16) -> bool {
        let state = self.inner.lock().await;
        state
            .streams
            .contains_key(&StreamKey::new(opener, stream_id))
    }

    #[allow(dead_code)] // test/diagnostic query surface
    pub(crate) async fn is_recv_closed(&self, opener: StreamOpener, stream_id: u16) -> bool {
        let state = self.inner.lock().await;
        state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .is_some_and(|e| e.recv_closed)
    }

    /// Session teardown: close every stream for the peer. Returns the ids so
    /// the caller can emit closed events.
    pub(crate) async fn close_all(
        &self,
        peer_id: &str,
        local_opener_device_id: &str,
    ) -> Vec<(StreamOpener, u16)> {
        let ids = {
            let mut state = self.inner.lock().await;
            let ids: Vec<(StreamOpener, u16)> = state
                .streams
                .keys()
                .map(|key| (key.opener, key.stream_id))
                .collect();
            let retired_keys = state.streams.keys().copied().collect::<Vec<_>>();
            state.retired.extend(retired_keys);
            state.streams.clear();
            ids
        };
        for (opener, stream_id) in &ids {
            let opener_device_id = match opener {
                StreamOpener::Local => local_opener_device_id,
                StreamOpener::Remote => peer_id,
            };
            emit_stream_closed(&self.event_tx, peer_id, opener_device_id, *stream_id);
        }
        ids
    }

    /// Revoke streams whose retained path lease has been hard-closed. Normal
    /// retirement leaves the lease active, so existing streams are not
    /// interrupted and new opens are rejected by path selection.
    #[allow(dead_code)]
    pub(crate) async fn close_inactive(
        &self,
        peer_id: &str,
        local_opener_device_id: &str,
    ) -> Vec<(StreamOpener, u16)> {
        let ids = {
            let mut state = self.inner.lock().await;
            let ids = state
                .streams
                .iter()
                .filter_map(|(key, entry)| {
                    entry
                        .path_lease
                        .as_ref()
                        .is_some_and(|lease| !lease.is_active())
                        .then_some(*key)
                })
                .collect::<Vec<_>>();
            for key in &ids {
                state.streams.remove(key);
                if state.retired.len() < MAX_RETIRED_STREAM_KEYS {
                    state.retired.insert(*key);
                }
            }
            ids.into_iter()
                .map(|key| (key.opener, key.stream_id))
                .collect::<Vec<_>>()
        };
        for (opener, stream_id) in &ids {
            let opener_device_id = match opener {
                StreamOpener::Local => local_opener_device_id,
                StreamOpener::Remote => peer_id,
            };
            emit_stream_closed(&self.event_tx, peer_id, opener_device_id, *stream_id);
        }
        ids
    }
}
