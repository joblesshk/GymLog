import { signRelayToken, verifyRelayToken, type RelayClaims, type RelayScope } from "./auth";
import { finishQuota, reserveQuota, quota, QuotaDO, type QuotaEnvironment } from "./quota";

export { QuotaDO };

export interface Env extends QuotaEnvironment {
  RELAY_TOKEN_SIGNING_SECRET?: string;
  MOCK_UPSTREAM?: string;
  UPSTREAM_ASR_WS_URL?: string;
  UPSTREAM_LLM_URL?: string;
  UPSTREAM_LLM_WARMUP_URL?: string;
  UPSTREAM_ASR_APP_ID?: string;
  UPSTREAM_ASR_ACCESS_TOKEN?: string;
  UPSTREAM_ASR_RESOURCE_ID?: string;
  UPSTREAM_LLM_API_KEY?: string;
  MAX_ASR_MESSAGE_BYTES?: string;
  MAX_ASR_AUDIO_BYTES?: string;
  MAX_INPUT_CHARS?: string;
  MAX_OUTPUT_TOKENS?: string;
  ALLOWED_CLEANUP_MODELS?: string;
}

const encoder = new TextEncoder();

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if ((url.pathname === "/v1/trial/session" && request.method === "POST") ||
        (url.pathname === "/v1/usage" && request.method === "GET")) {
      if (!env.RELAY_TOKEN_SIGNING_SECRET) return unauthorized();
      const credential = request.headers.get("Authorization") ?? "";
      if (!/^Bearer trial_[a-f0-9]{64}$/.test(credential)) return unauthorized();
      const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(credential.slice(7)))))
        .map(v => v.toString(16).padStart(2, "0")).join("");
      const subject = "gymlog:" + digest;
      if (url.pathname === "/v1/usage") return quota(env, subject, "status");
      const id = request.headers.get("X-Operation-ID") ?? "";
      const reservation = await quota(env, subject, "grant", id);
      if (!reservation.ok) return reservation;
      const usage = await reservation.json() as { expiresAt: number };
      const token = await signRelayToken({ sub: subject, exp: usage.expiresAt, scopes: ["asr", "cleanup"], jti: id }, env.RELAY_TOKEN_SIGNING_SECRET);
      return json({ token, ...usage });
    }
    if (url.pathname === "/healthz" && request.method === "GET") {
      return json({ ok: true, service: "gymlog-cloud-relay", billing: false });
    }

    if (url.pathname === "/warmup" && (request.method === "GET" || request.method === "POST" || request.method === "HEAD")) {
      const claims = await authenticate(request, env, "cleanup");
      if (!claims) return unauthorized();
      const upstreamProbe = await probeLLMUpstream(env);
      const headers = { "x-worker-upstream-probe": upstreamProbe };
      if (request.method === "HEAD") return new Response(null, { status: 204, headers });
      return json({ ok: true, subject: claims.sub, upstreamProbe, billing: false }, 200, headers);
    }

    if (url.pathname === "/v1/cleanup/chat/completions" && request.method === "POST") {
      return cleanup(request, env, ctx);
    }

    if (url.pathname === "/v1/asr/bigmodel_nostream" && request.method === "GET") {
      return asrWebSocket(request, env);
    }
    return json({ error: { message: "Not found", type: "not_found" } }, 404);
  },
};

async function cleanup(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const claims = await authenticate(request, env, "cleanup");
  if (!claims) return unauthorized();
  const payload = await readJSON(request, env.MAX_INPUT_CHARS);
  if (!payload.ok) return payload.response;
  const model = typeof payload.value.model === "string" ? payload.value.model : "";
  const allowedModels = (env.ALLOWED_CLEANUP_MODELS ?? "deepseek-flash").split(",").map((v) => v.trim()).filter(Boolean);
  if (!allowedModels.includes(model)) return json({ error: { message: "Model is not allowed", type: "invalid_request_error" } }, 400);
  if (payload.value.stream !== true) return json({ error: { message: "stream must be true", type: "invalid_request_error" } }, 400);
  if (!Array.isArray(payload.value.messages) || payload.value.messages.length === 0) {
    return json({ error: { message: "messages is required", type: "invalid_request_error" } }, 400);
  }
  const requestedMaxTokens = payload.value.max_tokens ?? payload.value.max_completion_tokens;
  if (requestedMaxTokens === undefined) payload.value.max_tokens = integerEnv(env.MAX_OUTPUT_TOKENS, 4096);
  if (requestedMaxTokens !== undefined) {
    const maxOutputTokens = integerEnv(env.MAX_OUTPUT_TOKENS, 4096);
    if (!Number.isInteger(requestedMaxTokens) || requestedMaxTokens <= 0) {
      return json({ error: { message: "max_tokens must be a positive integer", type: "invalid_request_error" } }, 400);
    }
    if (requestedMaxTokens > maxOutputTokens) {
      return json({ error: { message: `max_tokens exceeds relay limit (${maxOutputTokens})`, type: "invalid_request_error" } }, 400);
    }
  }
  const reserved = await reserveQuota(env, claims.sub, claims.jti ?? "", "cleanup");
  if (!reserved) return quotaExceeded();

  let upstream: Response;
  try {
    upstream = env.MOCK_UPSTREAM === "1"
      ? mockCleanupResponse(payload.value)
      : await fetchFixed(env.UPSTREAM_LLM_URL, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${required(env.UPSTREAM_LLM_API_KEY, "UPSTREAM_LLM_API_KEY")}`,
        },
        body: JSON.stringify(payload.value),
      });
  } catch {
    await finishQuota(env, claims.sub, false);
    return upstreamFailure();
  }
  if (!upstream.ok || !upstream.body) {
    await finishQuota(env, claims.sub, false);
    return sanitizedUpstreamError(upstream.status);
  }
  const body = streamWithQuota(upstream.body, env, claims.sub, ctx);
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-transform",
      "x-accel-buffering": "no",
    },
  });
}

async function asrWebSocket(request: Request, env: Env): Promise<Response> {
  const claims = await authenticate(request, env, "asr");
  if (!claims) return unauthorized();
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return json({ error: { message: "WebSocket upgrade required", type: "invalid_request_error" } }, 426);
  }
  const reserved = await reserveQuota(env, claims.sub, claims.jti ?? "", "asr");
  if (!reserved) return quotaExceeded();
  if (env.MOCK_UPSTREAM === "1") {
    // Mock mode intentionally does not fake a Cloudflare 101 response. The bridge is tested
    // independently with a fake upstream, while local HTTP protocol tests remain deterministic.
    await finishQuota(env, claims.sub, false);
    return json({ error: { message: "WebSocket mock requires a bridge harness", type: "mock_mode" } }, 501);
  }
  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetchFixed(env.UPSTREAM_ASR_WS_URL, {
      headers: {
        Upgrade: "websocket",
        Connection: "Upgrade",
        "X-Api-App-Key": required(env.UPSTREAM_ASR_APP_ID, "UPSTREAM_ASR_APP_ID"),
        "X-Api-Access-Key": required(env.UPSTREAM_ASR_ACCESS_TOKEN, "UPSTREAM_ASR_ACCESS_TOKEN"),
        "X-Api-Resource-Id": required(env.UPSTREAM_ASR_RESOURCE_ID, "UPSTREAM_ASR_RESOURCE_ID"),
        "X-Api-Request-Id": crypto.randomUUID(),
        "X-Api-Connect-Id": crypto.randomUUID(),
        "X-Api-Sequence": "-1",
      },
    });
  } catch {
    await finishQuota(env, claims.sub, false);
    return upstreamFailure();
  }
  const upstream = (upstreamResponse as Response & { webSocket?: WebSocket }).webSocket;
  if (upstreamResponse.status !== 101 || !upstream) {
    await finishQuota(env, claims.sub, false);
    return sanitizedUpstreamError(upstreamResponse.status);
  }

  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  const maxMessageBytes = integerEnv(env.MAX_ASR_MESSAGE_BYTES, 4 * 1024 * 1024);
  const maxAudioBytes = integerEnv(env.MAX_ASR_AUDIO_BYTES, 16 * 1024 * 1024);
  bridgeWebSockets(server, upstream, {
    maxMessageBytes,
    maxAudioBytes,
    maxDurationMs: 120 * 1000,
    onFinished: (committed) => finishQuota(env, claims.sub, committed),
  });
  return new Response(null, { status: 101, webSocket: client });
}

export interface BridgeOptions {
  maxMessageBytes: number;
  maxAudioBytes: number;
  maxDurationMs: number;
  onFinished: (committed: boolean) => Promise<void> | void;
}

export function bridgeWebSockets(front: WebSocket, upstream: WebSocket, options: BridgeOptions): void {
  let totalBytes = 0;
  let finished = false;
  let sawEndFrame = false;
  let sendQueue = Promise.resolve();
  const finish = (committed: boolean, code = 1000, reason = "") => {
    if (finished) return;
    finished = true;
    void options.onFinished(committed);
    if (front.readyState < 2) front.close(code, reason);
    if (upstream.readyState < 2) upstream.close(code, reason);
  };
  const fail = (reason: string) => finish(false, 1011, reason.slice(0, 120));

  front.binaryType = "arraybuffer";
  upstream.binaryType = "arraybuffer";
  front.accept({ allowHalfOpen: true });
  upstream.accept({ allowHalfOpen: true });
  const timeout = setTimeout(() => fail("session_timeout"), options.maxDurationMs);

  front.addEventListener("message", (event) => {
    sendQueue = sendQueue.then(async () => {
      if (finished) return;
      const data = await normalizeWebSocketData(event.data);
      const byteLength = typeof data === "string" ? encoder.encode(data).byteLength : data.byteLength;
      if (byteLength > options.maxMessageBytes || totalBytes + byteLength > options.maxAudioBytes) {
        fail("audio_limit_exceeded");
        return;
      }
      totalBytes += byteLength;
      // The Worker deliberately treats the vendor frame as opaque. It does not parse, reorder,
      // transcode, base64 encode, or persist audio. The negative final sequence remains intact.
      if (typeof data === "string") upstream.send(data);
      else upstream.send(data);
      if (byteLength >= 8 && typeof data !== "string") {
        // This is only an observability hint; the bridge never rewrites or closes on the frame.
        sawEndFrame = sawEndFrame || isVolcFinalAudioFrame(data);
      }
    }).catch(() => fail("client_to_upstream_error"));
  });
  upstream.addEventListener("message", (event) => {
    if (finished) return;
    try {
      front.send(event.data);
    } catch {
      fail("upstream_to_client_error");
    }
  });
  front.addEventListener("error", () => fail("client_socket_error"));
  upstream.addEventListener("error", () => fail("upstream_socket_error"));
  front.addEventListener("close", (event) => {
    clearTimeout(timeout);
    if (!finished) {
      finished = true;
      void options.onFinished(false);
      if (upstream.readyState < 2) upstream.close(event.code, "client_closed");
    }
  });
  upstream.addEventListener("close", (event) => {
    clearTimeout(timeout);
    if (!finished) {
      finished = true;
      void options.onFinished(sawEndFrame);
      if (front.readyState < 2) front.close(event.code, event.reason || "upstream_closed");
    }
  });
}

function isVolcFinalAudioFrame(data: ArrayBuffer): boolean {
  const bytes = new Uint8Array(data);
  if (bytes.length < 8) return false;
  const headerSize = (bytes[0] & 0x0f) * 4;
  const messageType = (bytes[1] >> 4) & 0x0f;
  const flags = bytes[1] & 0x0f;
  return headerSize >= 4 && headerSize + 4 <= bytes.length
    && messageType === 0x2 && (flags & 0x3) === 0x3;
}

async function normalizeWebSocketData(data: unknown): Promise<string | ArrayBuffer> {
  if (typeof data === "string") return data;
  if (data instanceof ArrayBuffer) return data;
  if (ArrayBuffer.isView(data)) {
    const view = new Uint8Array(data.buffer as ArrayBuffer, data.byteOffset, data.byteLength);
    const copy = new Uint8Array(view.byteLength);
    copy.set(view);
    return copy.buffer;
  }
  if (data instanceof Blob) return data.arrayBuffer();
  throw new TypeError("unsupported_websocket_message");
}

async function authenticate(request: Request, env: Env, scope: RelayScope): Promise<RelayClaims | null> {
  return verifyRelayToken(request.headers.get("Authorization"), env.RELAY_TOKEN_SIGNING_SECRET, scope);
}

async function readJSON(request: Request, maxCharsValue: string | undefined): Promise<
  { ok: true; value: Record<string, any> } | { ok: false; response: Response }
> {
  const maxChars = integerEnv(maxCharsValue, 200_000);
  const body = await readBoundedBody(request, maxChars * 4);
  if (!body.ok) return body;
  const text = new TextDecoder().decode(body.bytes);
  if (text.length > maxChars) return { ok: false, response: json({ error: { message: "Input is too large", type: "invalid_request_error" } }, 413) };
  try {
    const value = JSON.parse(text) as Record<string, any>;
    return { ok: true, value };
  } catch {
    return { ok: false, response: json({ error: { message: "Request body must be JSON", type: "invalid_request_error" } }, 400) };
  }
}

async function readBoundedBody(request: Request, maximum: number): Promise<{ ok: true; bytes: Uint8Array } | { ok: false; response: Response }> {
  if (!request.body) return { ok: false, response: json({ error: { message: "Request body is required", type: "invalid_request_error" } }, 400) };
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > maximum) {
        await reader.cancel("body_limit_exceeded");
        return { ok: false, response: json({ error: { message: "Request body is too large", type: "invalid_request_error" } }, 413) };
      }
      chunks.push(next.value);
    }
  } catch {
    return { ok: false, response: upstreamFailure() };
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { ok: true, bytes };
}

function streamWithQuota(body: ReadableStream<Uint8Array>, env: Env, subject: string, ctx: ExecutionContext): ReadableStream<Uint8Array> {
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  ctx.waitUntil(body.pipeTo(writable).then(
    () => finishQuota(env, subject, true),
    () => finishQuota(env, subject, false),
  ));
  return readable;
}

async function fetchFixed(urlValue: string | undefined, init: RequestInit): Promise<Response> {
  if (!urlValue) throw new Error("upstream_not_configured");
  const url = new URL(urlValue);
  if (url.protocol !== "https:") throw new Error("upstream_must_use_https");
  return fetch(url, init);
}

type UpstreamProbe = "ok" | "failed" | "not_configured";

async function probeLLMUpstream(env: Env): Promise<UpstreamProbe> {
  // A warmup is deliberately best-effort. It establishes an authenticated request
  // to the configured provider endpoint, but Cloudflare may still choose a fresh
  // socket for the later chat request. It never reserves quota or generates text.
  if (env.MOCK_UPSTREAM === "1" || !env.UPSTREAM_LLM_WARMUP_URL) return "not_configured";
  try {
    const upstream = await fetchFixed(env.UPSTREAM_LLM_WARMUP_URL, {
      method: "GET",
      headers: {
        accept: "application/json",
        authorization: `Bearer ${required(env.UPSTREAM_LLM_API_KEY, "UPSTREAM_LLM_API_KEY")}`,
      },
    });
    // Consume the small metadata response so the runtime has the best chance of
    // reusing the provider connection for the subsequent chat request.
    await upstream.arrayBuffer();
    return upstream.ok ? "ok" : "failed";
  } catch {
    // Warmup must not make recording or later cleanup fail. The actual cleanup
    // request remains the source of truth for provider availability.
    return "failed";
  }
}

function mockCleanupResponse(payload: Record<string, any>): Response {
  const lastUser = [...(payload.messages as Array<Record<string, unknown>>)].reverse().find((message) => message.role === "user");
  const content = typeof lastUser?.content === "string" ? lastUser.content : "mock cleanup";
  const visible = content.replace(/```[\s\S]*?```/g, "").trim().slice(0, 120) || "mock cleanup";
  const events = [
    `data: ${JSON.stringify({ choices: [{ delta: { content: visible.slice(0, Math.ceil(visible.length / 2)) } }] })}\n\n`,
    `data: ${JSON.stringify({ choices: [{ delta: { content: visible.slice(Math.ceil(visible.length / 2)) } }] })}\n\n`,
    `data: ${JSON.stringify({ choices: [], usage: { prompt_tokens: 8, completion_tokens: visible.length, prompt_cache_hit_tokens: 0 } })}\n\n`,
    "data: [DONE]\n\n",
  ].join("");
  return new Response(events, { status: 200, headers: { "content-type": "text/event-stream" } });
}

function required(value: string | undefined, name: string): string {
  if (!value) throw new Error(`${name}_not_configured`);
  return value;
}

function integerEnv(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function unauthorized(): Response {
  return json({ error: { message: "Unauthorized", type: "authentication_error" } }, 401, { "www-authenticate": "Bearer" });
}

function quotaExceeded(): Response {
  return json({ error: { message: "Installation quota or concurrency limit exceeded", type: "rate_limit_error" } }, 429);
}

function upstreamFailure(): Response {
  return json({ error: { message: "Upstream unavailable", type: "upstream_error" } }, 502);
}

function sanitizedUpstreamError(status: number): Response {
  return json({ error: { message: `Upstream returned HTTP ${status}`, type: "upstream_error" } }, 502);
}

function json(value: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extraHeaders },
  });
}
