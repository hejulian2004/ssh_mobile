use super::diagnostics::ssh_net_runtime_create_with_diagnostics;
use super::*;

#[test]
fn diagnostic_creation_validates_input_and_closes_owned_output() {
    let directory = std::env::temp_dir().join(format!(
        "ffi-log-{}-{}",
        std::process::id(),
        unix_timestamp_ms()
    ));
    let text = directory.to_string_lossy();
    let run = b"test-run";
    let mut handle = std::ptr::null_mut();
    unsafe {
        assert_eq!(
            ssh_net_runtime_create_with_diagnostics(
                [255_u8].as_ptr(),
                1,
                run.as_ptr(),
                run.len(),
                &mut handle
            ),
            -1
        );
        assert_eq!(
            ssh_net_runtime_create_with_diagnostics(
                text.as_ptr(),
                text.len(),
                [255_u8].as_ptr(),
                1,
                &mut handle
            ),
            -1
        );
        assert_eq!(
            ssh_net_runtime_create_with_diagnostics(
                std::ptr::null(),
                0,
                run.as_ptr(),
                run.len(),
                &mut handle
            ),
            -1
        );
        assert_eq!(
            ssh_net_runtime_create_with_diagnostics(
                text.as_ptr(),
                text.len(),
                b"../bad".as_ptr(),
                6,
                &mut handle
            ),
            -2
        );
        assert_eq!(
            ssh_net_runtime_create_with_diagnostics(
                text.as_ptr(),
                text.len(),
                run.as_ptr(),
                run.len(),
                &mut handle
            ),
            0
        );
        assert_eq!(ssh_net_runtime_start(handle), 0);
        assert_eq!(ssh_net_runtime_stop(handle), 0);
        assert_eq!(ssh_net_runtime_destroy(handle), 0);
    }
    let health = std::fs::read_dir(&directory)
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| p.to_string_lossy().ends_with("health.json"))
        .unwrap();
    assert!(std::fs::read_to_string(health)
        .unwrap()
        .contains("\"closed\":true"));
    std::fs::remove_dir_all(directory).unwrap();
}
