use std::collections::BTreeMap;

use super::{MessageId, OrderedInsertResult, OrderedMessage};
#[derive(Default)]
pub(super) struct OrderedChannelState {
    pub(super) expected_sequence: u64,
    pub(super) in_flight: Option<MessageId>,
    pub(super) reorder_buffer: BTreeMap<u64, OrderedMessage>,
    pub(super) reorder_bytes: usize,
}

impl OrderedChannelState {
    pub(super) fn insert(
        &mut self,
        message: OrderedMessage,
        max_messages: usize,
        max_bytes: usize,
        max_gap: u64,
    ) -> OrderedInsertResult {
        if message.sequence < self.expected_sequence {
            return OrderedInsertResult::Duplicate;
        }
        if message.sequence == self.expected_sequence {
            return match self.in_flight {
                Some(message_id) if message_id == message.message_id => {
                    OrderedInsertResult::Duplicate
                }
                Some(_) => OrderedInsertResult::Rejected,
                None => {
                    self.in_flight = Some(message.message_id);
                    OrderedInsertResult::Ready
                }
            };
        }
        if message.sequence.saturating_sub(self.expected_sequence) > max_gap
            || self.reorder_buffer.len() >= max_messages
            || self.reorder_bytes.saturating_add(message.payload.len()) > max_bytes
        {
            return OrderedInsertResult::Rejected;
        }
        match self.reorder_buffer.get(&message.sequence) {
            Some(existing) if existing.message_id == message.message_id => {
                OrderedInsertResult::Duplicate
            }
            Some(_) => OrderedInsertResult::Rejected,
            None => {
                self.reorder_bytes = self.reorder_bytes.saturating_add(message.payload.len());
                self.reorder_buffer.insert(message.sequence, message);
                OrderedInsertResult::Buffered
            }
        }
    }

    pub(super) fn acknowledge(&mut self, message_id: MessageId) -> Option<OrderedMessage> {
        if self.in_flight != Some(message_id) {
            return None;
        }
        self.in_flight = None;
        self.expected_sequence = self.expected_sequence.saturating_add(1);
        let next = self.reorder_buffer.remove(&self.expected_sequence)?;
        self.reorder_bytes = self.reorder_bytes.saturating_sub(next.payload.len());
        self.in_flight = Some(next.message_id);
        Some(next)
    }
}
