use super::*;
use network_core::diagnostics::DiagnosticOutput;
use std::path::Path;

/// Creates a runtime with an owned, local diagnostic output. This additive ABI
/// never changes commands/events or the network protocol.
///
/// # Safety
/// Inputs must point to valid UTF-8 bytes of their specified lengths; the output
/// handle must be non-null and writable. All input bytes are copied.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_create_with_diagnostics(
    directory: *const u8,
    directory_len: usize,
    run: *const u8,
    run_len: usize,
    out_handle: *mut SshNetRuntimeHandle,
) -> i32 {
    if directory.is_null()
        || run.is_null()
        || out_handle.is_null()
        || directory_len == 0
        || directory_len > 4096
        || run_len == 0
        || run_len > 96
    {
        return -1;
    }
    catch_unwind(|| {
        let Ok(directory) =
            std::str::from_utf8(unsafe { slice::from_raw_parts(directory, directory_len) })
        else {
            return -1;
        };
        let Ok(run) = std::str::from_utf8(unsafe { slice::from_raw_parts(run, run_len) }) else {
            return -1;
        };
        let Ok(output) = DiagnosticOutput::new(Path::new(directory), run) else {
            return -2;
        };
        let result = tracing::dispatcher::with_default(output.dispatch(), SshNetRuntime::new);
        let Ok(mut runtime) = result else {
            return -2;
        };
        runtime.diagnostics = Some(output);
        unsafe {
            *out_handle = Box::into_raw(Box::new(runtime)) as SshNetRuntimeHandle;
        }
        0
    })
    .unwrap_or(-99)
}
