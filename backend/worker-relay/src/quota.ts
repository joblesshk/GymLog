export const MONTHLY_LIMIT = 1000;
type Stage = "asr" | "cleanup";
interface Operation { exp: number; charged: boolean; asr: boolean; cleanup: boolean }
export interface State { month: string; used: number; operations: Record<string, Operation> }
export function monthAt(now: number): string { return new Date(now + 8 * 3600_000).toISOString().slice(0, 7); }
export function resetAt(now: number): number {
  const local = new Date(now + 8 * 3600_000);
  return Date.UTC(local.getUTCFullYear(), local.getUTCMonth() + 1, 1) - 8 * 3600_000;
}
export function transition(state: State | undefined, action: string, id: string, now: number) {
  state ??= { month: monthAt(now), used: 0, operations: {} };
  if (state.month !== monthAt(now)) { state.month = monthAt(now); state.used = 0; }
  for (const [key, op] of Object.entries(state.operations)) if (op.exp <= now / 1000) delete state.operations[key];
  const usage = () => ({ used: state!.used, limit: MONTHLY_LIMIT, remaining: Math.max(0, MONTHLY_LIMIT - state!.used), resetsAt: resetAt(now) / 1000 });
  if (action === "status") return { state, status: 200, body: usage() };
  if (!/^[a-f0-9-]{36}$/.test(id)) return { state, status: 400, body: { error: "invalid_operation" } };
  if (action === "grant") {
    const existing = state.operations[id];
    if (existing) return { state, status: 200, body: { expiresAt: existing.exp, ...usage() } };
    if (state.used >= MONTHLY_LIMIT) return { state, status: 429, body: { error: "monthly_limit", ...usage() } };
    if (Object.keys(state.operations).length >= 128) return { state, status: 429, body: { error: "operation_limit", retryAfter: 600 } };
    const exp = Math.floor(now / 1000) + 600;
    state.operations[id] = { exp, charged: false, asr: false, cleanup: false };
    return { state, status: 200, body: { expiresAt: exp, ...usage() } };
  }
  if (action !== "asr" && action !== "cleanup") return { state, status: 400, body: { error: "invalid_stage" } };
  const op = state.operations[id];
  if (!op || op[action as Stage] || (action === "asr" && op.cleanup)) return { state, status: 409, body: { error: "operation_already_used_or_expired" } };
  if (!op.charged) {
    if (state.used >= MONTHLY_LIMIT) return { state, status: 429, body: { error: "monthly_limit", ...usage() } };
    state.used += 1; op.charged = true;
  }
  op[action as Stage] = true;
  return { state, status: 200, body: { ok: true, ...usage() } };
}
// Service-wide daily cap on upstream calls, independent of installation identities
// (which anyone can mint). Resets at UTC+8 midnight, like the monthly quota.
export interface BudgetState { day: string; counts: Record<string, number> }
export function dayAt(now: number): string { return new Date(now + 8 * 3600_000).toISOString().slice(0, 10); }
export function budgetTransition(state: BudgetState | undefined, stage: string, limit: number, now: number) {
  if (!state || state.day !== dayAt(now)) state = { day: dayAt(now), counts: {} };
  const used = state.counts[stage] ?? 0;
  if (used >= limit) {
    const resetsAt = (Date.parse(state.day + "T00:00:00Z") + 16 * 3600_000) / 1000;
    return { state, status: 503, body: { error: "service_daily_budget_exhausted", resetsAt } };
  }
  state.counts[stage] = used + 1;
  return { state, status: 200, body: { ok: true } };
}
// Both checks execute while the subject DO is serialized. The tentative
// monthly mutation is not persisted until the global budget accepts it.
// Rejected/replayed requests never reach the global budget. Upstream failures
// AFTER admission remain charged, as before. A storage failure after global
// admission may conservatively consume a global slot, but cannot overspend it.
export class QuotaDO implements DurableObject {
  constructor(private state: DurableObjectState, private env: QuotaEnvironment) {}
  async fetch(request: Request): Promise<Response> {
    const body = await request.json().catch(() => ({})) as { id?: string; stage?: string; limit?: number };
    const action = new URL(request.url).pathname.slice(1);
    return this.state.blockConcurrencyWhile(async () => {
      const now = Date.now();
      if (action === "budget") {
        const result = budgetTransition(await this.state.storage.get<BudgetState>("budget"), body.stage ?? "", body.limit ?? 0, now);
        await this.state.storage.put("budget", result.state);
        return quotaResponse(result, now);
      }
      const result = transition(await this.state.storage.get<State>("state"), action, body.id ?? "", now);
      if (result.status === 200 && (action === "asr" || action === "cleanup")) {
        if (!Number.isInteger(body.limit) || body.limit! <= 0) {
          return quotaResponse({ status: 400, body: { error: "invalid_budget_limit" } }, now);
        }
        const budget = await this.env.QUOTA.get(this.env.QUOTA.idFromName("global:budget"))
          .fetch("https://quota/budget", { method: "POST", body: JSON.stringify({ stage: action, limit: body.limit }) });
        if (!budget.ok) return budget;
      }
      await this.state.storage.put("state", result.state);
      return quotaResponse(result, now);
    });
  }
}
function quotaResponse(result: { status: number; body: object }, now: number): Response {
  const body = result.body as { resetsAt?: number; retryAfter?: number };
  const headers: Record<string, string> = { "content-type": "application/json", "cache-control": "no-store" };
  if (result.status >= 400) {
    const retryAfter = body.retryAfter ?? (body.resetsAt ? Math.max(1, Math.ceil(body.resetsAt - now / 1000)) : undefined);
    if (retryAfter) headers["retry-after"] = String(retryAfter);
  }
  return new Response(JSON.stringify(result.body), { status: result.status, headers });
}
export interface QuotaEnvironment { QUOTA: DurableObjectNamespace }
export async function quota(env: QuotaEnvironment, subject: string, action: string, id = "", limit?: number) {
  return env.QUOTA.get(env.QUOTA.idFromName(subject)).fetch("https://quota/" + action, { method: "POST", body: JSON.stringify({ id, limit }) });
}
export async function reserveQuota(env: QuotaEnvironment, subject: string, id: string, stage: Stage, globalLimit: number): Promise<Response> {
  try {
    return await quota(env, subject, stage, id, globalLimit);
  } catch {
    return quotaResponse({ status: 503, body: { error: "quota_unavailable" } }, Date.now());
  }
}
// A submitted operation is charged once, regardless of upstream failure/cancellation.
export async function finishQuota(_env: QuotaEnvironment, _subject: string, _committed: boolean): Promise<void> {}
