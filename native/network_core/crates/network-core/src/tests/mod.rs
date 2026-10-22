//! Runtime lifecycle, transfer contracts, and reservation data-plane tests.
//!
//! The integration boundary is kept in focused source chunks so every
//! hand-written test unit remains reviewable without changing the shared
//! private-state test namespace.

include!("runtime_integration/relay_data_fixtures.rs");
include!("runtime_integration/relay_data_and_runtime_lifecycle.rs");
include!("runtime_integration/direct_transfer_matrix.rs");
include!("runtime_integration/receiver_restart_and_admission.rs");
include!("runtime_integration/file_transfer_recovery.rs");
include!("runtime_integration/delivery_recovery.rs");
include!("runtime_integration/delivery_reconnect.rs");
include!("runtime_integration/peer_runtime_restart.rs");
include!("runtime_integration/tcp_fallback.rs");
include!("runtime_integration/websocket_fallback_and_stream_helpers.rs");
include!("runtime_integration/stream_transport.rs");
include!("runtime_integration/ssh_gateway_and_test_helpers.rs");
include!("runtime_integration/direct_realtime.rs");
