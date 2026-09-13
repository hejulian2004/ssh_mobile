try:
    from .frozen_contract_support import *
except ImportError:
    from frozen_contract_support import *


class FrozenContractCompatibilityMixin:
    def test_network_protocol_v2_canonical_parity(self) -> None:
        proto = _read("protocol/proto/network/v2/network.proto")
        rust = _read_with_tests("native/network_core/crates/network-protocol/src/lib.rs")
        dart = _read_with_tests("apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart")

        # TransferProgressEvent
        self.assertIn("string peer_id = 4;", proto)
        self.assertIn('pub peer_id: String,', rust)
        self.assertIn("peerId = utf8.decode(reader.bytes(field.wireType));", dart)

        # IncomingTransferOfferEvent
        self.assertIn("RouteType route_type = 5;", proto)
        self.assertIn('pub route_type: Option<i32>,', rust)
        self.assertIn("route = reader.varint(field.wireType);", dart)

        # TransferCompletedEvent
        self.assertIn("string peer_id = 3;", proto)
        self.assertIn('pub struct TransferCompletedEvent', rust)
        self.assertIn('pub peer_id: String,', rust)

        # TransferFailedEvent
        self.assertIn("string peer_id = 3;", proto)
        self.assertIn('pub struct TransferFailedEvent', rust)
        self.assertIn('pub peer_id: String,', rust)

        # ConnectPeerCommand
        self.assertIn("CommunicationClass communication_class = 3;", proto)
        self.assertIn('pub communication_class: i32,', rust)
        self.assertIn("communicationClass.wireValue", dart)

    def test_forbidden_stale_production_concepts_are_absent(self) -> None:
        """Static drift guard; this does not assert runtime lifecycle behavior."""
        if os.environ.get("SSH_MOBILE_ACCEPTANCE_STRICT") != "1":
            self.skipTest("architecture guards run in strict acceptance")
        forbidden = (
            "network.v1",
            "ConnectionRegistry",
            "NeedsReplacement",
            "RelayDataReady",
        )
        offenders = []
        for path in _production_sources():
            source = _without_comments(path.read_text(encoding="utf-8"))
            for concept in forbidden:
                if concept in source:
                    offenders.append(f"{path.relative_to(ROOT)}: {concept}")
        self.assertEqual([], offenders, "stale production concepts: " + ", ".join(offenders))

        session_source = _without_comments(
            _read("native/network_core/crates/network-core/src/session.rs")
        )
        self.assertNotRegex(
            session_source,
            r"required_capabilities|current_route|current_relay_data",
        )

    def test_frozen_field_shapes_have_no_stale_compatibility_fields(self) -> None:
        if os.environ.get("SSH_MOBILE_ACCEPTANCE_STRICT") != "1":
            self.skipTest("architecture guards run in strict acceptance")
        proto = _without_comments(_read("protocol/proto/relay/v2/relay_v2.proto"))
        offer = re.search(
            r"message\s+ConnectivityOffer\s*\{(.*?)\n\}", proto, flags=re.DOTALL
        )
        signal = re.search(
            r"message\s+RealtimeSignal\s*\{(.*?)\n\}", proto, flags=re.DOTALL
        )
        self.assertIsNotNone(offer)
        self.assertIsNotNone(signal)
        assert offer is not None and signal is not None
        self.assertNotIn("target_device_id", offer.group(1))
        self.assertIn("source_device_id", signal.group(1))

    def test_relay_bootstrap_v1_retirement_guards(self) -> None:
        """Ensure active code, test, and scripts contain no Relay Bootstrap V1 routes or transcripts."""
        ignored_parts = {"build", ".dart_tool", "target", ".git", "node_modules", ".cache"}
        ignored_files = {"relay_v2_contract.sh", "test_frozen_network_contract.py"}
        scoped_dirs = [
            ROOT / "relay",
            ROOT / "packages/infrastructure/network_sdk",
            ROOT / "packages/features/feature_lan_share",
            ROOT / "native/network_core",
            ROOT / "apps",
            ROOT / "scripts",
        ]
        route_pattern = re.compile(r"/v1/devices/(?:enroll|refresh)")
        for directory in scoped_dirs:
            if not directory.exists():
                continue
            for path in directory.rglob("*"):
                if not path.is_file() or path.name.startswith(".") or path.name in ignored_files:
                    continue
                if any(part in ignored_parts for part in path.parts):
                    continue
                try:
                    content = path.read_text(encoding="utf-8", errors="ignore")
                except Exception:
                    continue
                match = route_pattern.search(content)
                self.assertIsNone(
                    match,
                    f"Forbidden Relay Bootstrap V1 route found in {path.relative_to(ROOT)}: {match.group(0) if match else ''}",
                )

        transcript_dirs = [
            ROOT / "relay",
            ROOT / "packages",
            ROOT / "native",
            ROOT / "apps",
            ROOT / "scripts",
        ]
        transcript_pattern = re.compile(r"POST\\n/v1/devices/refresh")
        for directory in transcript_dirs:
            if not directory.exists():
                continue
            for path in directory.rglob("*"):
                if not path.is_file() or path.name.startswith(".") or path.name in ignored_files:
                    continue
                if any(part in ignored_parts for part in path.parts):
                    continue
                try:
                    content = path.read_text(encoding="utf-8", errors="ignore")
                except Exception:
                    continue
                match = transcript_pattern.search(content)
                self.assertIsNone(
                    match,
                    f"Forbidden Relay Bootstrap V1 transcript found in {path.relative_to(ROOT)}",
                )


    def test_runtime_has_no_obvious_second_strong_physical_path_registry(self) -> None:
        """A source-shape guard for duplicate carrier ownership, not a lifecycle proof."""
        if os.environ.get("SSH_MOBILE_ACCEPTANCE_STRICT") != "1":
            self.skipTest("architecture guards run in strict acceptance")
        runtime = _read("native/network_core/crates/network-core/src/runtime.rs")
        self.assertNotRegex(
            runtime,
            r"struct\s+OwnedTransportPath\s*\{.*?\broute:\s*Arc<PhysicalRoute>",
        )
        self.assertNotIn(
            "transport_paths: RwLock<HashMap<String, Vec<OwnedTransportPath>>>",
            runtime,
        )


if __name__ == "__main__":
    unittest.main()
