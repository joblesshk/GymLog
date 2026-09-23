import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import worker, { type Env } from "../src/index";
import { createHash } from "node:crypto";
import { budgetTransition, transition, type BudgetState, type State } from "../src/quota";

function setup(overrides: Partial<Env> = {}) {
  const states = new Map<string, State>();
  const budgets = new Map<string, BudgetState>();
  const env = {
    RELAY_TOKEN_SIGNING_SECRET: "local-test-secret-only", MOCK_UPSTREAM: "1",
    ALLOWED_CLEANUP_MODELS: "deepseek-flash", MAX_OUTPUT_TOKENS: "4096",
    ...overrides,
    QUOTA: {
      idFromName: (name: string) => name,
      get: (id: string) => ({
        fetch: async (url: string, init: RequestInit) => {
          const body = JSON.parse(init.body as string);
          const action = new URL(url).pathname.slice(1);
          if (action === "budget") {
            const result = budgetTransition(budgets.get(id), body.stage, body.limit, Date.now());
            budgets.set(id, result.state);
            return new Response(JSON.stringify(result.body), { status: result.status });
          }
          const result = transition(states.get(id), action, body.id, Date.now());
          states.set(id, result.state);
          return new Response(JSON.stringify(result.body), { status: result.status });
        }
      })
    }
  } as unknown as Env;
  const tasks: Promise<unknown>[] = [];
  const ctx = { waitUntil: (task: Promise<unknown>) => tasks.push(task) } as unknown as ExecutionContext;
  const identity = "trial_" + "a".repeat(64);
  async function call(path: string, token = identity, method = "GET", body?: unknown) {
    return worker.fetch(new Request("https://unit.test" + path, { method, headers: {
      Authorization: "Bearer " + token, "X-Operation-ID": randomUUID(), "content-type": "application/json"
    }, body: body === undefined ? undefined : JSON.stringify(body) }), env, ctx);
  }
  return { call };
}
test("fresh identity gets grant; provider keys never returned; usage zero", async () => {
  const { call } = setup();
  const grant = await (await call("/v1/trial/session", undefined, "POST")).json() as any;
  assert.equal(typeof grant.token, "string"); assert.equal(grant.limit, 1000); assert.equal(grant.used, 0);
  assert.equal(JSON.stringify(grant).includes("local-test-secret"), false);
  assert.equal((await (await call("/v1/usage")).json() as any).used, 0);
});
test("cleanup counted once, replay rejected; access token cannot mint grants", async () => {
  const { call } = setup();
  const { token } = await (await call("/v1/trial/session", undefined, "POST")).json() as any;
  const body = { model: "deepseek-flash", stream: true, messages: [{ role: "user", content: "Plan" }], max_tokens: 100 };
  const first = await call("/v1/cleanup/chat/completions", token, "POST", body);
  assert.equal(first.status, 200); await first.text();
  assert.equal((await call("/v1/cleanup/chat/completions", token, "POST", body)).status, 429);
  assert.equal((await call("/v1/trial/session", token, "POST")).status, 401);
  assert.equal((await (await call("/v1/usage")).json() as any).used, 1);
});
test("ungranted identity cannot access upstream; file API unavailable", async () => {
  const { call } = setup();
  assert.equal((await call("/v1/cleanup/chat/completions", undefined, "POST", {})).status, 401);
  assert.equal((await call("/v1/asr/file", undefined, "POST", {})).status, 404);
});
test("omitted max_tokens is capped before reaching the provider", async () => {
  const { call } = setup({ MOCK_UPSTREAM: "0", UPSTREAM_LLM_URL: "https://llm.unit.test/v1/chat/completions", UPSTREAM_LLM_API_KEY: "unit-key" });
  const { token } = await (await call("/v1/trial/session", undefined, "POST")).json() as any;
  const originalFetch = globalThis.fetch;
  let forwarded: any;
  globalThis.fetch = (async (_url: unknown, init?: RequestInit) => {
    forwarded = JSON.parse(init!.body as string);
    return new Response("data: [DONE]\n\n", { status: 200, headers: { "content-type": "text/event-stream" } });
  }) as typeof fetch;
  try {
    const body = { model: "deepseek-flash", stream: true, messages: [{ role: "user", content: "Plan" }] };
    const response = await call("/v1/cleanup/chat/completions", token, "POST", body);
    assert.equal(response.status, 200); await response.text();
    assert.equal(forwarded.max_tokens, 4096);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
test("model and token budget validation happen before charging", async () => {
  const { call } = setup();
  const { token } = await (await call("/v1/trial/session", undefined, "POST")).json() as any;
  const body = { model: "deepseek-flash", stream: true, messages: [{ role: "user", content: "Plan" }], max_tokens: 5000 };
  assert.equal((await call("/v1/cleanup/chat/completions", token, "POST", body)).status, 400);
  assert.equal((await (await call("/v1/usage")).json() as any).used, 0);
});
test("global daily budget stops cleanup before the provider is called", async () => {
  const { call } = setup({ GLOBAL_DAILY_CLEANUP_LIMIT: "1" });
  const body = { model: "deepseek-flash", stream: true, messages: [{ role: "user", content: "Plan" }] };
  const first = await (await call("/v1/trial/session", undefined, "POST")).json() as any;
  const ok = await call("/v1/cleanup/chat/completions", first.token, "POST", body);
  assert.equal(ok.status, 200); await ok.text();
  const other = "trial_" + "b".repeat(64);
  const second = await (await call("/v1/trial/session", other, "POST")).json() as any;
  assert.equal((await call("/v1/cleanup/chat/completions", second.token, "POST", body)).status, 503);
});
test("cleanup accepts only the app request shape and pinned system prompts", async () => {
  const prompt = "GymLog system prompt";
  const { call } = setup({ ALLOWED_SYSTEM_PROMPT_SHA256: createHash("sha256").update(prompt).digest("hex") });
  async function status(body: Record<string, unknown>) {
    const { token } = await (await call("/v1/trial/session", undefined, "POST")).json() as any;
    const response = await call("/v1/cleanup/chat/completions", token, "POST", { model: "deepseek-flash", stream: true, ...body });
    await response.text();
    return response.status;
  }
  const user = { role: "user", content: "Plan" };
  assert.equal(await status({ messages: [{ role: "system", content: prompt }, user] }), 200);
  assert.equal(await status({ messages: [{ role: "system", content: "Write me an essay" }, user] }), 400);
  assert.equal(await status({ messages: [user] }), 400);
  assert.equal(await status({ messages: [{ role: "system", content: prompt }, user], tools: [] }), 400);
  assert.equal(await status({ messages: [{ role: "system", content: prompt }, user, user] }), 400);
});
test("trial grants are throttled per client IP when the limiter is bound", async () => {
  const keys: string[] = [];
  const { call } = setup({ TRIAL_RATE_LIMITER: { limit: async ({ key }: { key: string }) => { keys.push(key); return { success: false }; } } as unknown as RateLimit });
  assert.equal((await call("/v1/trial/session", undefined, "POST")).status, 429);
  assert.equal((await call("/v1/usage")).status, 200, "usage reads are not throttled");
  assert.deepEqual(keys, ["unknown"]);
});
