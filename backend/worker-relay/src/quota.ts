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
    if (state.used >= MONTHLY_LIMIT || Object.keys(state.operations).length >= 128) return { state, status: 429, body: { error: "monthly_limit", ...usage() } };
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
export class QuotaDO implements DurableObject {
  constructor(private state: DurableObjectState) {}
  async fetch(request: Request): Promise<Response> {
    const body = await request.json().catch(() => ({})) as { id?: string };
    return this.state.blockConcurrencyWhile(async () => {
      const result = transition(await this.state.storage.get<State>("state"), new URL(request.url).pathname.slice(1), body.id ?? "", Date.now());
      await this.state.storage.put("state", result.state);
      return new Response(JSON.stringify(result.body), { status: result.status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
    });
  }
}
export interface QuotaEnvironment { QUOTA: DurableObjectNamespace }
export async function quota(env: QuotaEnvironment, subject: string, action: string, id = "") {
  return env.QUOTA.get(env.QUOTA.idFromName(subject)).fetch("https://quota/" + action, { method: "POST", body: JSON.stringify({ id }) });
}
export async function reserveQuota(env: QuotaEnvironment, subject: string, id: string, stage: Stage): Promise<boolean> {
  return (await quota(env, subject, stage, id)).ok;
}
// A submitted operation is charged once, regardless of upstream failure/cancellation.
export async function finishQuota(_env: QuotaEnvironment, _subject: string, _committed: boolean): Promise<void> {}
