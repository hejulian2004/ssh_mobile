import type { Plugin } from 'vite';
import { browserRecord } from './src/diagnostics/record';

/** Loopback-only development receiver; host tooling owns file output. */
export function diagnosticsPlugin(run: string | undefined): Plugin {
  return {
    name: 'ssh-mobile-local-diagnostics', apply: 'serve',
    configureServer(server) {
      if (!run || !/^[A-Za-z0-9_-]{1,96}$/.test(run)) return;
      server.middlewares.use('/__agent_stop', (request, response) => {
        if (request.method !== 'POST' || request.headers.origin
          || request.headers['x-ssh-mobile-run'] !== run) {
          response.writeHead(403).end(); return;
        }
        response.writeHead(204).end();
        setImmediate(() => { void server.close(); });
      });
      let count = 0;
      let windowStart = Date.now();
      server.middlewares.use('/__agent_diagnostics', (request, response) => {
        const host = request.headers.host ?? '';
        if (request.method !== 'POST' || !/^(127\.0\.0\.1|localhost):\d+$/.test(host)
          || request.headers.origin !== `http://${host}`
          || request.headers['content-type'] !== 'application/json') {
          response.writeHead(403).end(); return;
        }
        if (Date.now() - windowStart > 1000) { count = 0; windowStart = Date.now(); }
        if (++count > 32) { response.writeHead(429).end(); return; }
        let bytes = 0;
        let body = '';
        let exceeded = false;
        request.on('data', (chunk: Buffer) => {
          bytes += chunk.length;
          if (bytes > 65536) { exceeded = true; body = ''; }
          if (!exceeded) body += chunk.toString('utf8');
        });
        request.on('end', () => {
          if (exceeded) { response.writeHead(413).end(); return; }
          try {
            const input = JSON.parse(body) as Record<string, unknown>;
            if (input.run_id !== run || typeof input.event !== 'string'
              || typeof input.attributes !== 'object' || input.attributes === null) throw new Error('invalid');
            const record = browserRecord(run, input.event, input.attributes as Record<string, unknown>);
            if (!record) throw new Error('invalid');
            process.stdout.write(`${JSON.stringify(record)}\n`);
            response.writeHead(204).end();
          } catch { response.writeHead(400).end(); }
        });
      });
    },
  };
}
