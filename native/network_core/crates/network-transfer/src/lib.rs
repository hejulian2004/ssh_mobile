//! Route-independent file transfer sessions, manifests, streaming chunks,
//! checksums, and resume primitives.

pub mod cancellation;
pub mod manager;
pub mod manifest;
pub mod receiver;
pub mod sender;

pub use cancellation::TransferCancellation;
pub use manager::{
    ResumableTransfer, TransferFailureReason, TransferManager, TransferSession, TransferSnapshot,
    TransferState,
};
pub use manifest::{
    single_safe_file_name, FileManifest, ResumeRequest, TransferAccept, TransferOffer,
    TransferReject, DEFAULT_TRANSFER_BUFFER, NETWORK_TRANSFER_PROTOCOL_VERSION,
};
pub use receiver::{
    existing_completed_file, existing_partial_offset, stream_receive_file,
    stream_receive_file_cancellable,
};
pub use sender::{build_file_manifest, stream_send_file, stream_send_file_cancellable};
