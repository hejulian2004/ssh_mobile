try:
    from .frozen_contract_support import *
except ImportError:
    from frozen_contract_support import *


class FrozenContractTransportMixin:
    def test_relay_data_contract_is_opaque_and_route_scoped(self) -> None:
        proto = _read("protocol/proto/relay/v2/relay_v2.proto")
        self.assertIn("message RelayDataPayload", proto)
        self.assertIn("bytes encrypted_payload = 2", proto)
        self.assertIn("opaque; relay never decrypts or parses", proto)
        self.assertNotIn("message RelayDataReady", proto)
        self.assertNotIn("ready = 14", proto)

        offer_start = proto.index("message ConnectivityOffer {")
        offer_end = proto.index("}\n", offer_start)
        self.assertNotIn("target_device_id", proto[offer_start:offer_end])

        signal_start = proto.index("message RealtimeSignal {")
        signal_end = proto.index("}\n", signal_start)
        signal = proto[signal_start:signal_end]
        self.assertIn("string target_device_id = 3", signal)
        self.assertIn("string source_device_id = 7", signal)

        contract = _read("protocol/RELAY_V2_CONTRACT.md")
        self.assertIn("Relay NEVER parses", contract)
        self.assertIn("`encrypted_payload`", contract)
        self.assertIn("Offering the wrong envelope type on a", contract)
        self.assertIn("route is a protocol violation", contract)
        self.assertIn("Resolve → Offer", contract)
        self.assertIn("WebSocket Ping", contract)
        self.assertIn("active data lifetime", contract)
        self.assertIn("no `RelayDataReady`", contract)
        self.assertIn("`source_device_id`", contract)

    def test_relay_dispatch_checks_path_admission_before_business_dispatch(self) -> None:
        relay = _read("native/network_core/crates/network-core/src/relay_data.rs")
        guard_start = relay.index("if kind != DATA_ENV_CRYPTO")
        match_start = relay.index("match kind", guard_start)
        self.assertLess(guard_start, match_start)
        guard = relay[guard_start:match_start]
        self.assertIn("relay_path_ready", guard)
        self.assertIn("business envelope rejected", guard)

    def test_candidate_cache_evidence_uses_monotonic_ttl_and_epoch_rules(self) -> None:
        cache = _read_with_tests(
            "native/network_core/crates/network-nat/src/candidate_v2.rs"
        )
        self.assertIn("Instant", cache)
        self.assertIn("now.saturating_duration_since(self.learned_at)", cache)
        self.assertIn("server_presence_ttl", cache)
        self.assertIn("invalidate_for_remote_epoch", cache)
        self.assertIn("SameRevisionDifferentFingerprint", cache)
        self.assertIn("self.learned_at.max(learned_at)", cache)

    def test_revocation_matrix_has_control_data_and_storage_evidence(self) -> None:
        control = _read("relay/internal/relay/control_v2_test.go")
        storage = _read("relay/internal/relay/fix_package_a_test.go")
        self.assertIn("TestRelayDataCloseDeviceClosesPendingActiveAndCounterpart", control)
        self.assertIn("TestRelayDataAdmissionBindsDeviceRoleAndToken", control)
        self.assertIn("TestAdminRevokeReturnsErrorWhenRevokeFails", storage)
        self.assertIn("TestDisconnectDeviceDoesNotClearForeignPresence", storage)

    def test_bounded_peer_supervisor_and_event_mux_are_bounded(self) -> None:
        supervisor = _read_with_tests(
            "native/network_core/crates/network-core/src/connect/peer_supervisor.rs"
        )
        self.assertIn("PEER_MAILBOX_CAPACITY", supervisor)
        self.assertIn("MAX_PEER_WAITERS", supervisor)
        self.assertIn("mailbox_and_resource_limits_are_bounded", supervisor)

        events = _read("native/network_core/crates/network-core/src/events.rs")
        self.assertNotIn("UnboundedSender", events)
        event_lanes = _read_with_tests(
            "native/network_core/crates/network-core/src/runtime_event_lanes.rs"
        )
        self.assertIn("EVENT_MAILBOX_CAPACITY", event_lanes)
        self.assertIn("MAX_EVENT_QUEUE_BYTES", event_lanes)
        self.assertIn("EventSender::Bounded", event_lanes)
        ffi = _read("native/network_core/crates/network-ffi/src/lib.rs")
        self.assertIn("EventMux", ffi)
        self.assertIn("SSH_NET_MAX_CONSECUTIVE_CONTROL_EVENTS", ffi)
        matrix = _load_matrix()
        cases = {case["id"]: case for case in matrix["cases"]}
        self.assertEqual(cases["flow.bounded_event_mux"]["status"], "covered")
