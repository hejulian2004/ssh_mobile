use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

use quinn::SendStream;
use tokio::sync::{watch, Mutex};

use crate::connect::PathLease;
use crate::runtime::EventSender;

// ---------------------------------------------------------------------------
// Per-stream receive/send state
// ---------------------------------------------------------------------------

/// How a stream's inbound bytes are consumed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StreamConsumer {
    /// Delivered as `SshStreamDataReceived` events (FFI client mode).
    Event,
    /// Buffered and drained by a native bridge task (gateway to sshd).
    Bridge,
    /// Buffered and drained by `receive_stream` (programmatic API).
    #[allow(dead_code)] // programmatic API consumer; exercised by tests
    Poll,
}

struct StreamEntry {
    consumer: StreamConsumer,
    recv_chunks: VecDeque<Vec<u8>>,
    recv_bytes: usize,
    recv_closed: bool,
    next_recv_seq: u64,
    /// 唤醒广播源（代次计数器）。watch 保存值：等待者必须在锁内订阅，
    /// 这样「条件检查 + 订阅」与生产者改动是原子临界区，检查-等待间隙里
    /// 的唤醒不会丢失（修复 `Notify` lost-wakeup 导致的背压 writer 永久
    /// 阻塞）。`watch::Sender` 不可 Clone，故保存在 entry 上，等待者通过
    /// `subscribe()` 派生 Receiver。
    wake_tx: watch::Sender<u64>,
    wake_gen: u64,
    quic_send: Option<SendStream>,
    next_send_seq: u64,
    send_closed: bool,
    send_lock: Arc<Mutex<()>>,
    /// One business path reservation held from StreamOpen through StreamClose.
    /// It is never replaced by a later path/session selection.
    path_lease: Option<PathLease>,
}

impl StreamEntry {
    /// 唤醒所有等待者。必须持锁调用（生产者改动状态后）：自增代次并广播，
    /// watch 保存最新代次，因此即使等待者尚未 poll，其 `changed()` 也会在
    /// 下一次 poll 时立即返回，而不是像 `Notify::notify_waiters()` 那样不带
    /// 许可地把唤醒丢掉。
    fn wake(&mut self) {
        self.wake_gen += 1;
        let _ = self.wake_tx.send(self.wake_gen);
    }

    /// 在锁内订阅最新代次（与条件检查同属一个临界区，生产者无法插入），
    /// 返回 Receiver 后即可在锁外 `changed().await` 等待下一次状态变化。
    fn wait_rx(&self) -> watch::Receiver<u64> {
        self.wake_tx.subscribe()
    }
}

#[derive(Default)]
struct StreamState {
    streams: HashMap<StreamKey, StreamEntry>,
    /// Stream identities retired by a Session teardown.  Keeping tombstones
    /// in the per-peer manager prevents an old FFI handle from addressing a
    /// newly-created stream with the same opener/id after reconnect.
    retired: HashSet<StreamKey>,
}

const MAX_RETIRED_STREAM_KEYS: usize = 131_072;

/// Direction-independent logical stream opener.  A per-peer manager has one
/// local device and one authenticated remote peer, so Local/Remote is the
/// compact representation of the opener peer id used on the wire.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum StreamOpener {
    Local,
    Remote,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct StreamKey {
    opener: StreamOpener,
    stream_id: u16,
}

impl StreamKey {
    fn new(opener: StreamOpener, stream_id: u16) -> Self {
        Self { opener, stream_id }
    }
}

/// Cloneable per-peer owner of every byte-stream receive buffer and QUIC send
/// half. The generic route receiver, QUIC bidi receivers, FFI commands and the
/// gateway bridge all share one manager per peer.
#[derive(Clone)]
pub(crate) struct ReliableStreamManager {
    inner: Arc<Mutex<StreamState>>,
    event_tx: EventSender,
}

pub(crate) fn validate_peer(peer_id: &str) -> bool {
    !peer_id.is_empty() && peer_id.len() <= 128
}

#[path = "manager_registry.rs"]
mod manager_registry;

#[path = "manager_buffer.rs"]
mod manager_buffer;
