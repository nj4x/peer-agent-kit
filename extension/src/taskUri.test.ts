import { test } from "node:test";
import assert from "node:assert/strict";
import { URI } from "vscode-uri";
import { buildTaskUriComponents } from "./taskUri";

// Mirrors cline-sr's registered URI handler (dist/extension.js, v1.26.0).
function simulateClineSr(uriString: string): string | null {
  const m = decodeURIComponent(uriString);
  const r = new URL(m);
  const s = new URLSearchParams(r.search.slice(1).replace(/\+/g, "%2B"));
  return s.get("prompt");
}

const prompts = [
  "High-effort code review of PR #697 federation-add-member",
  "a & b = c ? d",
  "100% done + more",
  "Your full task brief is at `/Users/x/.vscode-agent-bridge/briefs/brief-abc.md` — read it first, then proceed.",
  "line1\nline2 — ünïcödé 日本語",
  "hello world",
];

for (const prompt of prompts) {
  test(`round-trips through cline-sr decode: ${JSON.stringify(prompt).slice(0, 40)}`, () => {
    const uriString = URI.from(buildTaskUriComponents("vscode", prompt)).toString();
    assert.equal(simulateClineSr(uriString), prompt);
  });
}

test("regression: Uri.parse with single encoding truncates at '#'", () => {
  const oldUriString = URI.parse(
    `vscode://cline-sr.cline-sr/task?prompt=${encodeURIComponent("PR #697 x")}`
  ).toString();
  assert.equal(simulateClineSr(oldUriString), "PR ");
});
