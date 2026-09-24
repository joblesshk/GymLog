import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("deployment allowlist includes the hashes checked against the actual Swift prompts", () => {
  const config = JSON.parse(readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8"));
  const swiftTests = readFileSync(new URL("../../../GymLog/GymLogTests/CloudPromptPinTests.swift", import.meta.url), "utf8");
  const expected = [...swiftTests.matchAll(/XCTAssertEqual\(sha256\([^\n]+?\), "([a-f0-9]{64})"/g)].map(match => match[1]);
  assert.equal(expected.length, 2, "Keep this check in sync with the two Swift prompt tests");
  const deployed = config.vars.ALLOWED_SYSTEM_PROMPT_SHA256.split(",").map((hash: string) => hash.trim());
  for (const hash of expected) assert.ok(deployed.includes(hash), "Swift prompt hash is missing from the deployment allowlist");
});
