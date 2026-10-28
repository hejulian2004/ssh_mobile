const events = new Set(['browser_ready', 'browser_error', 'unhandled_rejection', 'api_completed', 'diagnostic_dropped']);

/** Local envelope containing typed metadata, never browser/request content. */
export function browserRecord(run: string, event: string, values: Record<string, unknown>) {
  if (!/^[A-Za-z0-9_-]{1,96}$/.test(run) || !events.has(event)) return null;
  const attributes: Record<string, number | string> = {};
  for (const key of ['duration_ms', 'status_code', 'count']) {
    const value = values[key];
    if (typeof value === 'number' && Number.isFinite(value) && value >= 0) attributes[key] = Math.round(value);
  }
  if (typeof values.method === 'string' && /^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$/.test(values.method)) attributes.method = values.method;
  return {
    schema_version: 1, occurred_at: new Date().toISOString(), run_id: run,
    instance_id: 'browser', component: 'front', event, message: event,
    level: event === 'browser_error' || event === 'unhandled_rejection' || event === 'diagnostic_dropped'
      || Number(attributes.status_code) >= 400 ? 'error' : 'info', attributes,
  };
}
