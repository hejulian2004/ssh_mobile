// @vitest-environment node
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createServer, type ViteDevServer } from 'vite';
import { diagnosticsPlugin } from '../diagnostics-plugin';

let server: ViteDevServer | undefined;
afterEach(async () => { vi.restoreAllMocks(); await server?.close(); server = undefined; });

describe('local diagnostic receiver', () => {
  it('accepts only same-origin bounded typed records', async () => {
    server = await createServer({ configFile: false, logLevel: 'silent',
      plugins: [diagnosticsPlugin('test-run')], server: { host: '127.0.0.1', port: 0 } });
    await server.listen();
    const address = server.httpServer!.address();
    if (!address || typeof address === 'string') throw new Error('missing loopback address');
    const origin = `http://127.0.0.1:${address.port}`;
    const send = (body: string, requestOrigin = origin) => fetch(`${origin}/__agent_diagnostics`, {
      method: 'POST', headers: { Origin: requestOrigin, 'Content-Type': 'application/json' }, body,
    });
    expect((await send('{}', 'https://invalid.example')).status).toBe(403);
    expect((await send('invalid-json')).status).toBe(400);
    expect((await send('x'.repeat(65537))).status).toBe(413);
    expect((await send(JSON.stringify({run_id: 'other', event: 'browser_error', attributes: {}}))).status).toBe(400);
    expect((await send(JSON.stringify({run_id: 'test-run', event: 'invalid_event', attributes: {}}))).status).toBe(400);
    const output = vi.spyOn(process.stdout, 'write').mockReturnValue(true);
    expect((await send(JSON.stringify({run_id: 'test-run', event: 'browser_error', attributes: {payload: 'private-value'}}))).status).toBe(204);
    const record = output.mock.calls.map((call) => String(call[0])).find((value) => value.includes('browser_error'))!;
    expect(record).not.toContain('private-value');
    for (let i = 0; i < 32; i++) await send('{}');
    expect((await send('{}')).status).toBe(429);
    expect((await fetch(`${origin}/__agent_stop`, {method: 'POST', headers: { Origin: origin }})).status).toBe(403);
    expect((await fetch(`${origin}/__agent_stop`, {method: 'POST', headers: { 'x-ssh-mobile-run': 'test-run' }})).status).toBe(204);
  });
  it('stays disabled without an explicit run', () => {
    expect(diagnosticsPlugin(undefined).apply).toBe('serve');
  });
});
