use super::*;

fn valid_manifest() -> FileManifest {
    FileManifest {
        transfer_id: "transfer-01_ok".into(),
        file_name: "payload.bin".into(),
        file_size: 7,
        modified_at: 0,
        content_hash: "ab".repeat(32),
        protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
    }
}

#[test]
fn single_safe_file_name_matches_manifest_component_rules() {
    assert!(single_safe_file_name("payload.bin"));
    assert!(single_safe_file_name(&"b".repeat(255)));
    assert!(!single_safe_file_name(""));
    assert!(!single_safe_file_name("dir/file"));
    assert!(!single_safe_file_name(r"dir\file"));
    assert!(!single_safe_file_name(".."));
    assert!(!single_safe_file_name("."));
    assert!(!single_safe_file_name(&"x".repeat(256)));
}

#[test]
fn manifest_validation_accepts_safe_boundary_values() {
    let mut manifest = valid_manifest();
    manifest.transfer_id = "a".repeat(128);
    manifest.file_name = "b".repeat(255);
    manifest.content_hash = "A1".repeat(32);
    assert_eq!(manifest.validate(), Ok(()));
}

#[test]
fn manifest_validation_rejects_identity_path_hash_and_version_errors() {
    let cases = [
        (
            "empty transfer id",
            FileManifest {
                transfer_id: String::new(),
                ..valid_manifest()
            },
        ),
        (
            "unsafe transfer id",
            FileManifest {
                transfer_id: "bad/id".into(),
                ..valid_manifest()
            },
        ),
        (
            "long transfer id",
            FileManifest {
                transfer_id: "x".repeat(129),
                ..valid_manifest()
            },
        ),
        (
            "empty file name",
            FileManifest {
                file_name: String::new(),
                ..valid_manifest()
            },
        ),
        (
            "path separator",
            FileManifest {
                file_name: "dir/file".into(),
                ..valid_manifest()
            },
        ),
        (
            "parent path",
            FileManifest {
                file_name: "..".into(),
                ..valid_manifest()
            },
        ),
        (
            "long file name",
            FileManifest {
                file_name: "x".repeat(256),
                ..valid_manifest()
            },
        ),
        (
            "short hash",
            FileManifest {
                content_hash: "00".into(),
                ..valid_manifest()
            },
        ),
        (
            "non-hex hash",
            FileManifest {
                content_hash: "zz".repeat(32),
                ..valid_manifest()
            },
        ),
        (
            "wrong version",
            FileManifest {
                protocol_version: 99,
                ..valid_manifest()
            },
        ),
    ];
    for (label, manifest) in cases {
        assert!(manifest.validate().is_err(), "{label} must be rejected");
    }
}
