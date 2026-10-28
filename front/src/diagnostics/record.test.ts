import { describe, expect, it } from 'vitest';
import { browserRecord } from './record';

describe('local browser diagnostics', () => {
  it('keeps only typed metadata and never request content', () => {
    const record = browserRecord('test-run', 'api_completed', {
      duration_ms: 12, status_code: 500, method: 'GET', payload: 'private-value',
    });
    expect(record?.attributes).toEqual({ duration_ms: 12, status_code: 500, method: 'GET' });
    expect(JSON.stringify(record)).not.toContain('private-value');
  });
  it('rejects unknown events, invalid identifiers and unsafe metadata', () => {
    expect(browserRecord('../bad', 'browser_error', {})).toBeNull();
    expect(browserRecord('run', 'private-value', {})).toBeNull();
    expect(browserRecord('run', 'api_completed', { duration_ms: Infinity, method: 'private-value' })?.attributes).toEqual({});
  });
});
