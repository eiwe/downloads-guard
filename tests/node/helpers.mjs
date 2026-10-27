// Shared setup for the OpenCode plugin and Pi extension tests: install downloads-guard
// into a temporary home (USERPROFILE on Windows) and point this process at it.
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const repo = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const isWin = process.platform === "win32";

export function installIntoTempHome() {
  const base = realpathSync.native(mkdtempSync(join(tmpdir(), "dg-node-")));
  const home = join(base, "home dir");
  const downloads = join(home, "Downloads");
  const inside = join(downloads, "project");
  const work = join(home, "work");
  for (const d of [inside, work, join(home, ".config", "opencode"), join(home, ".pi", "agent")]) {
    mkdirSync(d, { recursive: true });
  }
  const env = { ...process.env, HOME: home, USERPROFILE: home };
  delete env.XDG_CONFIG_HOME;
  delete env.PI_CODING_AGENT_DIR;
  let r;
  if (isWin) {
    r = spawnSync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", join(repo, "install.ps1"),
        "--profile-path", join(home, "Documents", "PowerShell", "profile.ps1")],
      { env, encoding: "utf8", cwd: work },
    );
  } else {
    r = spawnSync("sh", [join(repo, "install.sh")], { env, encoding: "utf8", cwd: work });
  }
  if (r.status !== 0) {
    throw new Error(`install failed (${r.status}): ${r.stdout}\n${r.stderr}`);
  }
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  delete process.env.PI_CODING_AGENT_DIR;
  return {
    base,
    home,
    downloads,
    inside,
    work,
    plugin: join(home, ".config", "opencode", "plugins", "downloads-guard.js"),
    extension: join(home, ".pi", "agent", "extensions", "downloads-guard.ts"),
    guardRoot: join(home, ".downloads-guard"),
    uninstall() {
      const u = isWin
        ? spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
          join(home, ".downloads-guard", "install.ps1"), "--profile-path",
          join(home, "Documents", "PowerShell", "profile.ps1"), "--uninstall"], { env, encoding: "utf8", cwd: work })
        : spawnSync("sh", [join(home, ".downloads-guard", "install.sh"), "--uninstall"], { env, encoding: "utf8", cwd: work });
      try {
        rmSync(base, { recursive: true, force: true });
      } catch {
        // read-only decoys on Windows; the OS temp cleanup gets them
      }
      return u.status;
    },
  };
}

// Load a .ts/.js file that is plain JavaScript as an ES module.
export async function importAsModule(file, dir) {
  const target = join(dir, `${Math.random().toString(36).slice(2)}.mjs`);
  copyFileSync(file, target);
  return import(`file://${isWin ? "/" : ""}${target.replace(/\\/g, "/")}`);
}
