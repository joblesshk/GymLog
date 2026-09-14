import { test } from "node:test";
import assert from "node:assert/strict";
import { transition, monthAt, resetAt, type State } from "../src/quota";
import { randomUUID } from "node:crypto";
const now = Date.parse("2026-09-14T12:00:00Z");
test("ASR plus cleanup charges once; each phase is one-use", () => {
  const id = randomUUID(); let state = transition(undefined, "grant", id, now).state;
  state = transition(state, "asr", id, now).state;
  assert.equal(state.used, 1);
  assert.equal(transition(state, "asr", id, now).status, 409);
  state = transition(state, "cleanup", id, now).state;
  assert.equal(state.used, 1);
  assert.equal(transition(state, "cleanup", id, now).status, 409);
});
test("1000 allowed, 1001 denied with no concurrent overshoot", () => {
  let state: State | undefined;
  for (let i = 0; i < 1000; i++) {
    const id = randomUUID(); const time = now + i * 601_000;
    state = transition(state, "grant", id, time).state;
    const result = transition(state, "cleanup", id, time);
    assert.equal(result.status, 200); state = result.state;
  }
  assert.equal(state!.used, 1000);
  assert.equal(transition(state, "grant", randomUUID(), now + 1000 * 601_000).status, 429);
});
test("parallel final slots checked on consumption, not just grant", () => {
  let state: State = { month: monthAt(now), used: 999, operations: {} };
  const a = randomUUID(), b = randomUUID();
  state = transition(state, "grant", a, now).state;
  state = transition(state, "grant", b, now).state;
  assert.equal(transition(state, "cleanup", a, now).status, 200);
  assert.equal(transition(state, "cleanup", b, now).status, 429);
});
test("Hong Kong month boundary resets quota; status and unused grants cost zero", () => {
  const before = Date.parse("2026-09-30T15:59:59Z");
  const after = before + 1000;
  let state: State = { month: monthAt(before), used: 1000, operations: {} };
  assert.equal(resetAt(before), after);
  assert.equal(transition(state, "status", "", before).state.used, 1000);
  state = transition(state, "status", "", after).state;
  assert.equal(state.used, 0);
  const id = randomUUID();
  state = transition(state, "grant", id, after).state;
  assert.equal(state.used, 0);
  assert.equal(transition(state, "asr", id, after + 601_000).status, 409);
});
test("grant retry idempotent; independent devices have independent state", () => {
  const id = randomUUID(); let a = transition(undefined, "grant", id, now);
  const again = transition(a.state, "grant", id, now + 100);
  assert.deepEqual(again.body, a.body);
  a = transition(a.state, "cleanup", id, now);
  assert.equal(a.state.used, 1);
  assert.equal(transition(undefined, "status", "", now).state.used, 0);
});
