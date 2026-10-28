import { browserRecord } from './record';

let pending = 0;
let dropped = 0;
export function emitDiagnostic(event: string, attributes: Record<string, unknown> = {}) {
  if (!import.meta.env.DEV) return;
  const run = import.meta.env.VITE_SSH_MOBILE_LOG_RUN_ID as string | undefined;
  if (!run) return;
  const record = browserRecord(run, event, attributes);
  if (!record) return;
  if (pending >= 16) { dropped = Math.min(Number.MAX_SAFE_INTEGER, dropped + 1); return; }
  void send(record);
}

async function send(record: NonNullable<ReturnType<typeof browserRecord>>) {
  pending++;
  let delivered = false;
  try {
    const response = await fetch('/__agent_diagnostics', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(record), credentials: 'omit', signal: AbortSignal.timeout(2000),
    });
    delivered = response.ok;
  } catch { /* Retry only a loss count after later successful traffic. */ }
  finally { pending--; }
  if (!delivered) {
    dropped = Math.min(Number.MAX_SAFE_INTEGER, dropped + (record.event === 'diagnostic_dropped' ? Number(record.attributes.count) : 1));
  } else if (dropped > 0 && pending < 16) {
    const count = dropped; dropped = 0;
    void send(browserRecord(record.run_id, 'diagnostic_dropped', {count})!);
  }
}

/** The caller owns and releases only these listeners. */
export function installBrowserDiagnostics() {
  if (!import.meta.env.DEV || !import.meta.env.VITE_SSH_MOBILE_LOG_RUN_ID) return () => {};
  const onError = () => emitDiagnostic('browser_error');
  const onRejection = () => emitDiagnostic('unhandled_rejection');
  window.addEventListener('error', onError);
  window.addEventListener('unhandledrejection', onRejection);
  emitDiagnostic('browser_ready');
  return () => {
    window.removeEventListener('error', onError);
    window.removeEventListener('unhandledrejection', onRejection);
  };
}
