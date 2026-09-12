try:
    from .frozen_contract_support import *
except ImportError:
    from frozen_contract_support import *


class FrozenContractInventoryMixin:
    def test_acceptance_matrix_is_complete_and_statused(self) -> None:
        matrix = _load_matrix()
        cases = matrix.get("cases")
        self.assertIsInstance(cases, list)
        assert isinstance(cases, list)

        case_ids = [case.get("id") for case in cases if isinstance(case, dict)]
        self.assertEqual(len(case_ids), len(set(case_ids)))
        self.assertEqual(set(case_ids), REQUIRED_CASE_IDS)

        allowed_statuses = {"covered", "characterized", "gap"}
        for case in cases:
            self.assertIsInstance(case, dict)
            assert isinstance(case, dict)
            self.assertIn(case.get("status"), allowed_statuses)
            self.assertTrue(case.get("acceptance"))
            self.assertTrue(case.get("evidence"))

        if os.environ.get("SSH_MOBILE_ACCEPTANCE_STRICT") == "1":
            open_cases = [
                case["id"] for case in cases if case["status"] != "covered"
            ]
            self.assertFalse(
                open_cases,
                "final acceptance remains open for: " + ", ".join(open_cases),
            )

    def test_matrix_evidence_paths_and_markers_are_present(self) -> None:
        matrix = _load_matrix()
        cases = matrix["cases"]
        assert isinstance(cases, list)
        for case in cases:
            assert isinstance(case, dict)
            for evidence in case["evidence"]:
                self.assertIsInstance(evidence, dict)
                assert isinstance(evidence, dict)
                relative_path = evidence["path"]
                path = ROOT / relative_path
                sources = _source_paths(path)
                self.assertTrue(sources, f"missing evidence file: {path}")
                source = "\n".join(
                    candidate.read_text(encoding="utf-8") for candidate in sources
                )
                for marker in evidence.get("contains", []):
                    self.assertIn(
                        marker,
                        source,
                        f"evidence marker {marker!r} missing from {path}",
                    )

    def test_relay_v2_golden_fixtures_are_framed_and_manifest_complete(self) -> None:
        manifest = _load_json(MANIFEST_PATH)
        self.assertIsInstance(manifest, dict)
        assert isinstance(manifest, dict)
        self.assertEqual(manifest.get("schema_version"), 2)

        constants = manifest.get("constants")
        self.assertIsInstance(constants, dict)
        assert isinstance(constants, dict)
        self.assertEqual(constants.get("RELAY_V2_VERSION"), 2)
        self.assertEqual(constants.get("FRAME_LENGTH_PREFIX_BYTES"), 4)
        self.assertEqual(constants.get("PRESENCE_TTL_S"), 60)

        fixtures = manifest.get("fixtures")
        self.assertIsInstance(fixtures, list)
        assert isinstance(fixtures, list)
        self.assertEqual(len(fixtures), 23)

        max_frame_bytes = constants["MAX_RELAY_FRAME_BYTES"]
        self.assertEqual(max_frame_bytes, constants["MAX_RELAY_DATA_FRAME_BYTES"])
        for fixture in fixtures:
            self.assertIsInstance(fixture, dict)
            assert isinstance(fixture, dict)
            path = MANIFEST_PATH.parent / fixture["file"]
            self.assertTrue(path.is_file(), f"missing fixture: {path}")
            payload = path.read_bytes()
            self.assertGreaterEqual(len(payload), 4, path.name)
            declared_length = struct.unpack(">I", payload[:4])[0]
            self.assertEqual(declared_length, len(payload) - 4, path.name)
            self.assertLessEqual(len(payload), max_frame_bytes, path.name)

        sequence = _load_json(
            ROOT / "protocol/relay_v2_testdata/session_sequence.golden.json"
        )
        self.assertIsInstance(sequence, dict)
        assert isinstance(sequence, dict)
        self.assertTrue(sequence.get("sequence"))
