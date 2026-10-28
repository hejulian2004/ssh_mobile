import { z } from 'zod';
import { ApiRequestError, parseApiError } from './errors';
import { emitDiagnostic } from '../diagnostics/browser';

export const REQUEST_TIMEOUT_MS = 10_000;

async function parseResponse(response: Response): Promise<unknown> {
  const contentType = response.headers.get('content-type') ?? '';
  if (!contentType.includes('application/json')) {
    return null;
  }

  try {
    return await response.json();
  } catch {
    return null;
  }
}

function isAbortError(error: unknown) {
  return error instanceof Error && error.name === 'AbortError';
}

function throwIfAborted(signal: AbortSignal) {
  if (!signal.aborted) return;
  if (signal.reason instanceof Error) throw signal.reason;
  throw new DOMException('Aborted', 'AbortError');
}

export async function request<T>(
  path: string,
  schema: z.ZodType<T>,
  init?: RequestInit,
): Promise<T> {
  const requestController = new AbortController();
  const diagnosticStart = performance.now();
  let diagnosticStatus = 0;
  const callerSignal = init?.signal;
  let timedOut = false;

  const abortRequest = () => {
    requestController.abort(callerSignal?.reason);
  };

  if (callerSignal) {
    if (callerSignal.aborted) {
      abortRequest();
    } else {
      callerSignal.addEventListener('abort', abortRequest, { once: true });
    }
  }

  const timeoutId = setTimeout(() => {
    timedOut = true;
    requestController.abort();
  }, REQUEST_TIMEOUT_MS);

  try {
    const response = await fetch(path, {
      ...init,
      signal: requestController.signal,
      credentials: 'include',
      headers: {
        Accept: 'application/json',
        ...(init?.body ? { 'Content-Type': 'application/json' } : {}),
        ...init?.headers,
      },
    });
    diagnosticStatus = response.status;
    throwIfAborted(requestController.signal);

    const body = await parseResponse(response);
    throwIfAborted(requestController.signal);
    if (!response.ok) {
      const parsedError = parseApiError(body);
      const message = parsedError?.message ?? 'Relay 请求失败。';
      const pathUrl = path.split('?')[0].replace(/\/$/, '');
      if (
        response.status === 401
        && !pathUrl.endsWith('/auth/login')
        && !pathUrl.endsWith('/auth/session')
      ) {
        window.dispatchEvent(new Event('relay:unauthorized'));
      }
      throw new ApiRequestError(message, response.status, parsedError);
    }

    const parsed = schema.safeParse(response.status === 204 ? undefined : body);
    if (!parsed.success) {
      throw new ApiRequestError('Relay 返回的数据格式无效。', response.status);
    }
    return parsed.data;
  } catch (error) {
    if (timedOut) {
      throw new ApiRequestError('Relay 请求超时，请稍后重试。', 0);
    }
    if (callerSignal?.aborted || isAbortError(error)) {
      throw error;
    }
    if (error instanceof ApiRequestError) {
      throw error;
    }
    throw new ApiRequestError('无法连接 Relay 服务。', 0);
  } finally {
    emitDiagnostic('api_completed', {
      duration_ms: performance.now() - diagnosticStart,
      status_code: diagnosticStatus, method: init?.method ?? 'GET',
    });
    clearTimeout(timeoutId);
    callerSignal?.removeEventListener('abort', abortRequest);
  }
}
