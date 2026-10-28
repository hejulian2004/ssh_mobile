import { loadEnv } from 'vite';
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { diagnosticsPlugin } from './diagnostics-plugin';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const relayApiOrigin = env.RELAY_DEV_API_ORIGIN;
  const adminApiOrigin = env.ADMIN_DEV_API_ORIGIN || relayApiOrigin;
  const devPort = Number(env.FRONT_DEV_PORT);

  return {
    plugins: [react(), diagnosticsPlugin(env.VITE_SSH_MOBILE_LOG_RUN_ID)],
    server: {
      ...(env.VITE_SSH_MOBILE_LOG_RUN_ID ? { host: '127.0.0.1', strictPort: true } : {}),
      ...(Number.isInteger(devPort) && devPort > 0 ? { port: devPort } : {}),
      proxy: {
        ...(adminApiOrigin ? { '/api/admin/v1': adminApiOrigin } : {}),
        ...(relayApiOrigin
          ? {
              '/healthz': relayApiOrigin,
              '/v2': relayApiOrigin,
            }
          : {}),
      },
    },
    test: {
      environment: 'jsdom',
      globals: true,
      setupFiles: './src/test/setup.ts',
      coverage: {
        provider: 'v8',
        reporter: ['text', 'json-summary', 'lcov'],
        reportsDirectory: './coverage',
        include: ['src/**/*.{ts,tsx}', 'diagnostics-plugin.ts'],
        exclude: [
          'src/**/*.test.{ts,tsx}',
          'src/test/**',
          'src/main.tsx',
          'src/vite-env.d.ts',
        ],
        thresholds: {
          lines: 90,
          functions: 90,
          branches: 90,
          statements: 90,
        },
      },
      include: [
        'src/**/*.{test,spec}.{ts,tsx}',
        'tests/**/*.{test,spec}.{ts,tsx}',
      ],
    },
  };
});
