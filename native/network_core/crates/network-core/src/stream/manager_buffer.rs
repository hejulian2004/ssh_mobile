use std::sync::Arc;

use quinn::SendStream;
use tokio::sync::{watch, Mutex};

use crate::events::{emit_stream_closed, emit_stream_data_received};

use super::super::{StreamError, MAX_PER_STREAM_BUFFER_CAPACITY};
use super::{StreamConsumer, StreamKey, StreamOpener};

impl super::ReliableStreamManager {
    pub(crate) async fn register_quic_send(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        send: SendStream,
    ) -> Result<(), StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        entry.quic_send = Some(send);
        Ok(())
    }

    /// Acquires the per-stream send mutex so a full send operation (generic
    /// frame sequence or QUIC write) is not interleaved with another caller.
    pub(crate) async fn send_guard(
        &self,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<Arc<Mutex<()>>, StreamError> {
        let state = self.inner.lock().await;
        let entry = state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        Ok(Arc::clone(&entry.send_lock))
    }

    pub(crate) async fn next_send_seq(
        &self,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<u64, StreamError> {
        let state = self.inner.lock().await;
        let entry = state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        Ok(entry.next_send_seq)
    }

    pub(crate) async fn bump_send_seq(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        count: u64,
    ) -> Result<(), StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        entry.next_send_seq += count;
        Ok(())
    }

    /// Writes raw bytes to a QUIC stream send half. The per-stream send guard
    /// must be held by the caller so the `take`/`put-back` cannot race.
    pub(crate) async fn quic_send_bytes(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        data: &[u8],
    ) -> Result<(), StreamError> {
        let mut send = {
            let mut state = self.inner.lock().await;
            let entry = state
                .streams
                .get_mut(&StreamKey::new(opener, stream_id))
                .ok_or(StreamError::NotFound)?;
            if entry.send_closed {
                return Err(StreamError::Closed);
            }
            entry.quic_send.take().ok_or(StreamError::Closed)?
        };
        let result = send.write_all(data).await;
        // The peer closing the stream aborts the write; that resolves to an
        // error and we drop the dead stream half.
        let mut state = self.inner.lock().await;
        if let Some(entry) = state.streams.get_mut(&StreamKey::new(opener, stream_id)) {
            if entry.send_closed {
                return Err(StreamError::Closed);
            }
            if result.is_ok() {
                entry.quic_send = Some(send);
            }
        }
        result.map_err(|_| StreamError::Closed)
    }

    /// Finishes the QUIC send half (graceful close of our write side).
    pub(crate) async fn quic_finish_send(
        &self,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<(), StreamError> {
        let mut send = {
            let mut state = self.inner.lock().await;
            let entry = state
                .streams
                .get_mut(&StreamKey::new(opener, stream_id))
                .ok_or(StreamError::NotFound)?;
            if entry.send_closed {
                return Ok(());
            }
            entry.quic_send.take().ok_or(StreamError::Closed)?
        };
        let _ = send.finish();
        Ok(())
    }

    /// Inbound StreamBytes data. Every consumer mode buffers the bytes in a
    /// per-stream buffer bounded at `MAX_PER_STREAM_BUFFER_CAPACITY` and blocks
    /// the writer (backpressure) while the buffer is full, so a flooding peer
    /// cannot grow memory without bound. Event-mode bytes are drained by the
    /// per-stream emitter task into `SshStreamDataReceived` events; Bridge/Poll
    /// bytes are drained by the reader.
    pub(crate) async fn handle_bytes(
        &self,
        peer_id: &str,
        opener: StreamOpener,
        stream_id: u16,
        seq: u64,
        data: Vec<u8>,
    ) -> Result<(), StreamError> {
        let _ = peer_id; // 事件由 drainer 发出；此处仅缓冲，不直接用 peer_id。
        let data_len = data.len();
        // 阶段一：有界缓冲 + 背压（所有消费者模式一致）。缓冲区满时阻塞 writer。
        let after = loop {
            let wait: Option<watch::Receiver<u64>> = {
                let mut state = self.inner.lock().await;
                let entry = state
                    .streams
                    .get_mut(&StreamKey::new(opener, stream_id))
                    .ok_or(StreamError::NotFound)?;
                if entry.recv_closed || entry.send_closed {
                    // Late packet racing the close: drop, not an error.
                    return Ok(());
                }
                if seq != entry.next_recv_seq {
                    if seq < entry.next_recv_seq {
                        return Ok(()); // duplicate retransmission
                    }
                    return Err(StreamError::InvalidFrame); // gap on an ordered carrier
                }
                if entry.recv_bytes + data_len <= MAX_PER_STREAM_BUFFER_CAPACITY {
                    entry.next_recv_seq += 1;
                    entry.recv_bytes += data_len;
                    let after = entry.recv_bytes;
                    entry.recv_chunks.push_back(data);
                    entry.wake();
                    break after;
                }
                Some(entry.wait_rx())
            };
            // 订阅与条件检查同临界区：锁释放后即便生产者已 drain，watch 也
            // 保存了最新代次，`changed()` 立即返回；错误（sender 已丢）则
            // 重查，entry 已被移除时会得到 NotFound。
            if let Some(mut rx) = wait {
                let _ = rx.changed().await;
            }
        };
        // 阶段二（仅 Event 模式）：等待 drainer 把本块转成事件（缓冲降到
        // appended 之后）。这样事件顺序与帧处理顺序一致，且 drainer 慢/停时
        // writer 立即获得背压，而不是逐帧直接灌入无界事件通道。
        loop {
            let wait: Option<watch::Receiver<u64>> = {
                let mut state = self.inner.lock().await;
                let Some(entry) = state.streams.get_mut(&StreamKey::new(opener, stream_id)) else {
                    return Ok(());
                };
                if entry.consumer != StreamConsumer::Event || entry.recv_bytes < after {
                    return Ok(());
                }
                Some(entry.wait_rx())
            };
            if let Some(mut rx) = wait {
                let _ = rx.changed().await;
            }
        }
    }

    /// Event-mode drainer: pops buffered chunks and emits `SshStreamDataReceived`
    /// events, then emits `SshStreamClosed` after the receive side is closed and
    /// the buffer is empty (so data events always precede the close event). This
    /// is the Event-mode consumer — without it the writer would block forever at
    /// `MAX_PER_STREAM_BUFFER_CAPACITY`. 设计 §17：Event 流与 Bridge/Poll 共享
    /// 同一有界缓冲区与背压；本任务把缓冲字节转成事件，而不是逐帧直接灌入
    /// 无界事件通道。
    pub(crate) async fn drain_events(
        self,
        peer_id: &str,
        opener: StreamOpener,
        stream_id: u16,
        opener_device_id: &str,
    ) {
        loop {
            let wait: Option<watch::Receiver<u64>> = {
                let mut state = self.inner.lock().await;
                let Some(entry) = state.streams.get_mut(&StreamKey::new(opener, stream_id)) else {
                    return;
                };
                if let Some(chunk) = entry.recv_chunks.pop_front() {
                    entry.recv_bytes -= chunk.len();
                    emit_stream_data_received(
                        &self.event_tx,
                        peer_id,
                        opener_device_id,
                        stream_id,
                        &chunk,
                    );
                    entry.wake();
                    continue;
                }
                if entry.recv_closed {
                    // 缓冲区已空且对端关闭：最后发出 close 事件，保证 data 先于 close。
                    drop(state);
                    emit_stream_closed(&self.event_tx, peer_id, opener_device_id, stream_id);
                    return;
                }
                Some(entry.wait_rx())
            };
            if let Some(mut rx) = wait {
                let _ = rx.changed().await;
            }
        }
    }

    /// Drains buffered bytes for a Bridge/Poll consumer, spanning chunk
    /// boundaries so the caller receives a contiguous byte run. Returns 0 on
    /// EOF.
    pub(crate) async fn receive(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        buf: &mut [u8],
    ) -> Result<usize, StreamError> {
        loop {
            let wait = {
                let mut state = self.inner.lock().await;
                let entry = state
                    .streams
                    .get_mut(&StreamKey::new(opener, stream_id))
                    .ok_or(StreamError::NotFound)?;
                if entry.consumer == StreamConsumer::Event {
                    return Err(StreamError::InvalidArgument);
                }
                let mut filled = 0usize;
                while filled < buf.len() {
                    let Some(chunk) = entry.recv_chunks.front() else {
                        break;
                    };
                    let take = chunk.len().min(buf.len() - filled);
                    buf[filled..filled + take].copy_from_slice(&chunk[..take]);
                    filled += take;
                    if take == chunk.len() {
                        entry.recv_chunks.pop_front();
                    } else {
                        let remaining = chunk[take..].to_vec();
                        entry.recv_chunks.pop_front();
                        entry.recv_chunks.push_front(remaining);
                    }
                }
                if filled > 0 {
                    entry.recv_bytes -= filled;
                    entry.wake();
                    return Ok(filled);
                }
                if entry.recv_closed {
                    return Ok(0);
                }
                Some(entry.wait_rx())
            };
            if let Some(mut rx) = wait {
                let _ = rx.changed().await;
            }
        }
    }

    /// 诊断/测试查询面：返回该流当前缓冲的字节数，用于断言背压下有界性。
    #[cfg(test)]
    pub(crate) async fn buffered_bytes(
        &self,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Option<usize> {
        let state = self.inner.lock().await;
        state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .map(|entry| entry.recv_bytes)
    }
}
