import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { importAsModule, installIntoTempHome } from "./helpers.mjs";

let env;
let mod;

before(async () => {
  env = installIntoTempHome();
  mod = await importAsModule(env.plugin, env.base);
});

after(() => {
  assert.equal(env.uninstall(), 0, "uninstall should succeed");
});

test("the plugin exports only the plugin function (OpenCode loads every export)", () => {
  assert.deepEqual(Object.keys(mod), ["DownloadsGuard"]);
});

test("the installed plugin points at the install folder", () => {
  assert.ok(readFileSync(env.plugin, "utf8").includes(JSON.stringify(env.guardRoot).slice(1, -1)));
});

test("tool.execute.before throws when OpenCode runs inside Downloads", async () => {
  const hooks = await mod.DownloadsGuard({ directory: env.inside, worktree: "/" });
  await assert.rejects(
    hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "ls" } }),
    /inside your Downloads folder/,
  );
});

test("tool.execute.before throws when the worktree is Downloads itself", async () => {
  const hooks = await mod.DownloadsGuard({ directory: env.work, worktree: env.downloads });
  await assert.rejects(hooks["tool.execute.before"]({ tool: "read" }, { args: {} }), /Downloads/);
});

test("tool.execute.before allows tool calls outside Downloads", async () => {
  const hooks = await mod.DownloadsGuard({ directory: env.work, worktree: "/" });
  await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "ls" } });
});

test("the plugin fails closed when the shared check cannot run", async () => {
  const broken = join(env.base, "broken-plugin.js");
  const text = readFileSync(env.plugin, "utf8").replace(
    /const INSTALLED_ROOT = ".*?";/,
    `const INSTALLED_ROOT = ${JSON.stringify(join(env.base, "missing"))};`,
  );
  writeFileSync(broken, text);
  const m = await importAsModule(broken, env.base);
  const hooks = await m.DownloadsGuard({ directory: env.work, worktree: "/" });
  await assert.rejects(hooks["tool.execute.before"]({ tool: "bash" }, { args: {} }), /could not check/);
});
