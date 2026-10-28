import { afterEach, describe, expect, it, vi } from 'vitest';
import { emitDiagnostic, installBrowserDiagnostics } from './browser';

afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); });
describe('browser diagnostic lifecycle', () => {
  it('is inactive without a development run and in production', () => {
    const fetcher = vi.fn(); vi.stubGlobal('fetch', fetcher);
    vi.stubEnv('VITE_SSH_MOBILE_LOG_RUN_ID', '');
    installBrowserDiagnostics()(); emitDiagnostic('browser_error');
    vi.stubEnv('VITE_SSH_MOBILE_LOG_RUN_ID', 'run'); vi.stubEnv('DEV', false);
    installBrowserDiagnostics()(); emitDiagnostic('browser_error');
    expect(fetcher).not.toHaveBeenCalled();
  });
  it('captures exceptions as metadata and removes its listeners', async () => {
    const fetcher = vi.fn().mockResolvedValue({ok: true}); vi.stubGlobal('fetch', fetcher);
    vi.stubEnv('DEV', true); vi.stubEnv('VITE_SSH_MOBILE_LOG_RUN_ID', 'test-run');
    const release = installBrowserDiagnostics();
    window.dispatchEvent(new Event('error'));
    window.dispatchEvent(new Event('unhandledrejection'));
    emitDiagnostic('invalid_event');
    await Promise.resolve();
    expect(fetcher).toHaveBeenCalledTimes(3);
    release();
    window.dispatchEvent(new Event('error'));
    expect(fetcher).toHaveBeenCalledTimes(3);
    expect(JSON.parse(fetcher.mock.calls[1][1].body).event).toBe('browser_error');
  });
  it('bounds in-flight requests and reports dropped records after recovery', async () => {
    vi.stubEnv('DEV', true); vi.stubEnv('VITE_SSH_MOBILE_LOG_RUN_ID', 'test-run');
    const fetcher = vi.fn().mockRejectedValue(new Error('offline'));
    vi.stubGlobal('fetch', fetcher);
    for (let i = 0; i < 40; i++) emitDiagnostic('browser_error');
    expect(fetcher.mock.calls.length).toBeLessThanOrEqual(16);
    await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(16));
    await new Promise((resolve) => setTimeout(resolve, 0));
    fetcher.mockResolvedValue({ok: true});
    emitDiagnostic('browser_ready');
    await vi.waitFor(() => expect(fetcher.mock.calls.some((call) => JSON.parse(call[1].body).event === 'diagnostic_dropped')).toBe(true));
    const report = fetcher.mock.calls.map((call) => JSON.parse(call[1].body)).find((record) => record.event === 'diagnostic_dropped');
    expect(report.attributes.count).toBe(40);
  });
  it('treats HTTP rejection as a delivery gap without a retry loop', async () => {
    vi.stubEnv('DEV', true); vi.stubEnv('VITE_SSH_MOBILE_LOG_RUN_ID', 'test-run');
    const fetcher = vi.fn().mockResolvedValue({ok: false}); vi.stubGlobal('fetch', fetcher);
    emitDiagnostic('browser_error');
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(fetcher).toHaveBeenCalledTimes(1);
    fetcher.mockResolvedValue({ok: true});
    emitDiagnostic('browser_ready');
    await vi.waitFor(() => expect(fetcher.mock.calls.some((call) => JSON.parse(call[1].body).event === 'diagnostic_dropped')).toBe(true));
  });
});
