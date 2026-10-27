import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { importAsModule, installIntoTempHome } from "./helpers.mjs";

let env;
let handlers;

function fakePi() {
  const h = {};
  return { h, api: { on(name, fn) { (h[name] ||= []).push(fn); return () => {}; } } };
}

function ctx(cwd, extra = {}) {
  const calls = { shutdown: 0, notify: [] };
  return {
    calls,
    cwd,
    hasUI: true,
    mode: "tui",
    ui: { notify: (m, level) => calls.notify.push([m, level]) },
    shutdown: () => { calls.shutdown++; },
    ...extra,
  };
}

async function load(file) {
  const mod = await importAsModule(file, env.base);
  const { h, api } = fakePi();
  mod.default(api);
  return h;
}

before(async () => {
  env = installIntoTempHome();
  handlers = await load(env.extension);
});

after(() => {
  assert.equal(env.uninstall(), 0, "uninstall should succeed");
});

test("registers project_trust, session_start and tool_call handlers", () => {
  for (const e of ["project_trust", "session_start", "tool_call"]) assert.equal(handlers[e]?.length, 1, e);
});

test("project_trust answers no inside Downloads", async () => {
  const c = ctx(env.inside);
  assert.deepEqual(await handlers.project_trust[0]({ type: "project_trust", cwd: env.inside }, c), { trusted: "no", remember: false });
});

test("project_trust leaves the decision to Pi outside Downloads", async () => {
  const c = ctx(env.work);
  assert.deepEqual(await handlers.project_trust[0]({ type: "project_trust", cwd: env.work }, c), { trusted: "undecided" });
});

test("session_start asks Pi to shut down inside Downloads", async () => {
  const c = ctx(env.inside);
  await handlers.session_start[0]({ type: "session_start", reason: "startup" }, c);
  assert.equal(c.calls.shutdown, 1);
  assert.match(c.calls.notify[0][0], /inside your Downloads folder/);
});

test("session_start does nothing outside Downloads", async () => {
  const c = ctx(env.work);
  await handlers.session_start[0]({ type: "session_start", reason: "startup" }, c);
  assert.equal(c.calls.shutdown, 0);
});

test("every tool call is blocked inside Downloads", async () => {
  for (const ev of [
    { toolName: "read", input: { path: "notes.txt" } },
    { toolName: "bash", input: { command: "ls" } },
    { toolName: "write", input: { path: "x.txt", content: "" } },
  ]) {
    const r = await handlers.tool_call[0]({ type: "tool_call", toolCallId: "1", ...ev }, ctx(env.inside));
    assert.equal(r?.block, true, ev.toolName);
    assert.match(r.reason, /Downloads/);
  }
});

test("ordinary tool calls outside Downloads are allowed", async () => {
  for (const ev of [
    { toolName: "write", input: { path: "src/app.ts", content: "x" } },
    { toolName: "edit", input: { path: join(env.work, "README.md"), edits: [] } },
    { toolName: "bash", input: { command: "npm test" } },
    { toolName: "read", input: { path: join(env.home, ".pi", "agent", "settings.json") } },
  ]) {
    const r = await handlers.tool_call[0]({ type: "tool_call", toolCallId: "1", ...ev }, ctx(env.work));
    assert.equal(r, undefined, ev.toolName);
  }
});

test("writes to Pi's own configuration are blocked everywhere", async () => {
  for (const ev of [
    { toolName: "write", input: { path: join(env.home, ".pi", "agent", "settings.json"), content: "{}" } },
    { toolName: "write", input: { path: "~/.pi/agent/models.json", content: "{}" } },
    { toolName: "edit", input: { path: ".pi/settings.json", edits: [] } },
    { toolName: "write", input: { path: ".pi/extensions/evil.ts", content: "" } },
    { toolName: "write", input: { path: join(env.guardRoot, "config"), content: "" } },
    { toolName: "bash", input: { command: "echo x > ~/.pi/agent/models.json" } },
    { toolName: "bash", input: { command: "rm -rf ~/.downloads-guard" } },
    { toolName: "bash", input: { command: "cat > .pi/settings.json" } },
  ]) {
    const r = await handlers.tool_call[0]({ type: "tool_call", toolCallId: "1", ...ev }, ctx(env.work));
    assert.equal(r?.block, true, JSON.stringify(ev));
  }
});

test("the extension fails closed when the shared check cannot run", async () => {
  const broken = join(env.base, "broken-ext.ts");
  const text = readFileSync(env.extension, "utf8").replace(
    /const INSTALLED_ROOT = ".*?";/,
    `const INSTALLED_ROOT = ${JSON.stringify(join(env.base, "missing"))};`,
  );
  writeFileSync(broken, text);
  const h = await load(broken);
  const r = await h.tool_call[0]({ type: "tool_call", toolCallId: "1", toolName: "bash", input: { command: "ls" } }, ctx(env.work));
  assert.equal(r?.block, true);
  assert.match(r.reason, /could not check/);
  assert.deepEqual(await h.project_trust[0]({ type: "project_trust", cwd: env.work }, ctx(env.work)), { trusted: "no", remember: false });
});
