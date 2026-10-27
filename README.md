# downloads-guard

Keeps coding agents (Claude Code, Codex, Cursor, OpenCode and Pi) from running inside your Downloads folder, where any website you visit can drop an instruction file such as `AGENTS.md` or `CLAUDE.md`.

It works on macOS, Linux and Windows, needs no admin rights for the default install, and has no override: no flag, environment variable or allow file makes a folder inside Downloads allowed. If you need to work on something you downloaded, move it to a working folder first.

## The threat

A browser saves files into Downloads without asking. Coding agents read instruction files from the folder they start in, and most also read them from every folder above it:

- Claude Code loads `CLAUDE.md` and `CLAUDE.local.md` "from your current working directory and every directory above it", and `AGENTS.md` when there is no `CLAUDE.md` ([memory docs](https://code.claude.com/docs/en/memory.md)).
- Codex reads `AGENTS.override.md` and `AGENTS.md` from the project root down to the working folder; in a folder that is not a git repository it reads only that folder ([AGENTS.md guide](https://developers.openai.com/codex/guides/agents-md.md)).
- OpenCode reads `AGENTS.md` (and `CLAUDE.md` as a fallback) walking up from the working folder ([rules docs](https://opencode.ai/docs/rules/)), and a project `opencode.json` can change its permissions and providers ([config docs](https://opencode.ai/docs/config/)).
- The Cursor CLI reads `AGENTS.md` and `CLAUDE.md` at the project root ([CLI docs](https://cursor.com/docs/cli/using.md)).
- Pi loads `AGENTS.md`, `CLAUDE.md` and their variants from the working folder and its parents, and "context-file discovery does not require project trust" ([Pi configuration](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md), [Pi security](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/security.md)).

So the drive-by is: a page triggers a download of `AGENTS.md`; later you open a terminal in Downloads (to look at a zip, say) and start an agent; the agent follows the planted instructions. A typical goal is to make the agent rewrite its own settings: add an MCP server, point the API base URL at an attacker, or turn off approvals, so the damage outlives the session.

Two facts from browser source code keep the problem small. Chromium (Chrome, Edge) and Firefox strip leading dots from download names, so `.mcp.json`, `.cursorrules` or a `.claude/` folder cannot arrive this way ([Chromium `filename_util_internal.cc`](https://chromium.googlesource.com/chromium/src/+/main/net/base/filename_util_internal.cc), [Firefox `nsExternalHelperAppService.cpp`](https://hg.mozilla.org/mozilla-central/raw-file/tip/uriloader/exthandler/nsExternalHelperAppService.cpp)). Only flat names can: `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.override.md`, `opencode.json`. And when a name is already taken, both browsers save the new file under another name (`AGENTS (1).md` in Chromium, `AGENTS(1).md` in Firefox), which no agent reads ([Chromium download path tracker](https://chromium.googlesource.com/chromium/src/+/main/components/download/internal/common/download_path_reservation_tracker.cc), [Firefox `DownloadPaths.sys.mjs`](https://hg.mozilla.org/mozilla-central/raw-file/tip/toolkit/components/downloads/DownloadPaths.sys.mjs)).

## The three layers

**Layer 1: refuse to run in Downloads.** Shell wrappers for bash, zsh, fish and PowerShell intercept `claude`, `codex`, `opencode`, `agent` (the Cursor CLI), `cursor-agent` and `pi`. If the current folder is Downloads or anything under it, they print a plain warning and exit with status 3 without starting the tool; anywhere else they run the real program with the arguments unchanged. No AI is involved in that decision, so there is nothing to talk out of it. Native hooks are a second net for launches that skip your shell, such as IDEs:

| Harness | What downloads-guard installs | Effect inside Downloads |
|---|---|---|
| Claude Code | `UserPromptSubmit` and `PreToolUse` hooks in `~/.claude/settings.json` (merged with your settings, `onFailure: "block"`) | Every prompt and every tool call is blocked (exit code 2). Claude Code cannot be stopped at startup: `SessionStart` hooks cannot block ([hooks docs](https://code.claude.com/docs/en/hooks.md)), so the window opens but nothing you type gets through. |
| Claude Code in VS Code | `~/.downloads-guard/bin/claude-process-wrapper` (`claude-process-wrapper.cmd` on Windows), for the `claudeCode.claudeProcessWrapper` setting | The extension's Claude process does not start. You set this yourself; see below. |
| Codex | `UserPromptSubmit` hook in `~/.codex/hooks.json` | Every prompt is blocked. Codex runs a new hook only after you trust it: start `codex`, open `/hooks` and trust the downloads-guard hook ([Codex hooks](https://developers.openai.com/codex/hooks.md)). |
| Cursor (editor and CLI) | `beforeSubmitPrompt` hook with `failClosed: true` in `~/.cursor/hooks.json` | Every prompt is blocked, and a crashed or missing hook also blocks ([Cursor hooks](https://cursor.com/docs/hooks.md)). |
| OpenCode | Global plugin `~/.config/opencode/plugins/downloads-guard.js` | Every tool call throws. OpenCode has no hook that can stop a prompt ([plugins](https://opencode.ai/docs/plugins/)), so the shell wrapper is what keeps it from starting. |
| Pi | User extension `~/.pi/agent/extensions/downloads-guard.ts` | Answers "no" to project trust, blocks every tool call, and asks Pi to shut down at session start. The shutdown is best effort (see limitations). |

The folder decision lives in one place per platform family: `bin/downloads-guard` (POSIX `sh`) on macOS and Linux, and `lib/DownloadsGuard.psm1` with `bin/downloads-guard.ps1` on Windows. Every wrapper, hook, the OpenCode plugin and the Pi extension call it. If the check cannot run or cannot decide, the caller blocks.

How Downloads is found:

- **Windows:** the Known Folder `FOLDERID_Downloads` through `SHGetKnownFolderPath`, so OneDrive and policy redirects are followed ([KNOWNFOLDERID](https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid)). `%USERPROFILE%\Downloads` is protected as well, because the redirect itself is stored in your user registry.
- **Linux:** `xdg-user-dir DOWNLOAD`, or `XDG_DOWNLOAD_DIR` read (never executed) from `user-dirs.dirs`. When that is unset, XDG's own fallback is your home folder ([xdg-user-dirs](https://www.freedesktop.org/wiki/Software/xdg-user-dirs/)), which would block everything, so downloads-guard refuses any value that is your home folder or above it. `$HOME/Downloads` is always protected too, so editing `user-dirs.dirs` cannot unprotect it.
- **macOS:** `~/Downloads`.

Paths are compared after resolving symlinks, junctions and Windows 8.3 short names, and without regard to case on Windows and macOS. Extra folders can be listed, one per line, in `~/.downloads-guard/config`. An entry that is your home folder, above it, or a whole drive is ignored.

**Layer 2: lock what the attack targets.** An agent started somewhere else can still wander into Downloads (`cd ~/Downloads && cat AGENTS.md`), and layer 1 does not see that. Layer 2 makes the follow-up harder by locking the settings the planted instructions would try to change. The rules are narrow on purpose, so normal work, including Claude's memory and project files under `~/.claude`, is unaffected:

- Claude Code: `permissions.deny` rules `Edit(~/.claude.json)`, `Edit(~/.claude/settings*.json)`, `Edit(**/.claude/settings*.json)`, `Edit(**/.mcp.json)` and `Edit(~/.downloads-guard/**)`, plus `permissions.disableBypassPermissionsMode: "disable"` ([permissions](https://code.claude.com/docs/en/permissions.md)).
- Cursor CLI: `Write(...)` deny rules in `cli-config.json` for `cli-config.json`, `hooks.json`, `mcp.json` and the downloads-guard folder ([CLI permissions](https://cursor.com/docs/cli/reference/permissions.md)).
- OpenCode: `permission.edit` deny rules for `~/.config/opencode/*` and `~/.downloads-guard/*` in the global `opencode.json`. A project `opencode.json` can override the global file ([config precedence](https://opencode.ai/docs/config/)), which is why `--system` also writes them to the managed config.
- Pi has no deny syntax, so its extension blocks `write` and `edit` calls into the Pi agent folder, any `.pi` folder and the downloads-guard folder, and shell commands that name them.
- Codex already ignores base-URL and provider keys in project config ([advanced config](https://developers.openai.com/codex/config-advanced.md)), and its sandbox writes only inside the project by default, so it gets the file lock (with `--system`) and no deny rule.

**Layer 3: take the filenames.** The installer creates `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md` and `AGENTS.override.md` in Downloads (on Linux also `AGENTS.MD` and `CLAUDE.MD`, which Pi reads and which are different files on a case-sensitive disk). The text is written for you: "You opened a coding agent in your Downloads folder. Close it and move the files to a working folder." It ends with one line telling an agent to stop and do nothing. It also creates an `opencode.json` there that OpenCode reads as configuration: `"permission": "deny"` for everything. These files get a same-user lock (`chmod 444` on Linux, `chflags uchg` on macOS, the read-only attribute on Windows), or an admin lock with `--system`. If one of these names already exists and was not made by downloads-guard, the installer leaves it alone and tells you; look at it before deleting it, since it may be exactly the kind of file this tool is about.

## Install

macOS and Linux (needs `python3` to edit the agents' JSON settings safely):

```sh
git clone https://github.com/eiwe/downloads-guard.git
cd downloads-guard
./install.sh --dry-run   # print every change, write nothing
./install.sh
```

Windows (PowerShell 5.1 or 7):

```powershell
git clone https://github.com/eiwe/downloads-guard.git
cd downloads-guard
.\install.ps1 --dry-run
.\install.ps1
```

Open a new terminal afterwards so the wrappers load, then run `downloads-guard status`. It lists the protected folders, every installed piece, whether the current folder would be blocked and whether the system locks are on.

The installer sets up each agent it finds (its settings folder exists or its command is on your `PATH`), so run it again after installing a new agent. Running it again is always safe: it updates the install in place. It writes into:

- `~/.downloads-guard/` (the check, the wrappers, `config`, and `state/` with a record of every change),
- your shell startup files: a marked block in `~/.bashrc` (and `~/.bash_profile` on macOS if it exists), `~/.zshrc`, a file in `~/.config/fish/conf.d/`, or on Windows a marked block in your PowerShell 7 and Windows PowerShell profiles,
- the agent settings listed above, merged with what is there: other keys and hooks are kept, and a file that is not valid JSON is skipped with a warning rather than overwritten,
- the decoy files in Downloads.

On Windows the profile only runs if the execution policy allows local scripts. If `Get-ExecutionPolicy` says `Restricted` or `AllSigned`, run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`; `downloads-guard status` warns about this. Windows support covers PowerShell only, not `cmd.exe` or Git Bash shells.

### Uninstall

```sh
~/.downloads-guard/install.sh --uninstall
```

```powershell
& "$env:USERPROFILE\.downloads-guard\install.ps1" --uninstall
```

This removes exactly what was added: hook entries and deny rules are taken out of the agents' settings, values that were changed are put back, files and folders that downloads-guard created are deleted, and a settings file whose remaining content matches what it was before the install gets its original bytes back. Your own later edits to those files stay. `--dry-run` works with `--uninstall` too.

### The admin tier: `--system`

The default install needs no admin rights, and everything it does can be undone by any program running as you, including an agent with a shell. `--system` (sudo on macOS and Linux, an elevated PowerShell on Windows) adds what a same-user process cannot undo:

- **Claude Code managed settings**: a drop-in `managed-settings.d/50-downloads-guard.json` in `/etc/claude-code/` (Linux), `/Library/Application Support/ClaudeCode/` (macOS) or `C:\Program Files\ClaudeCode\` (Windows), with the same hooks and deny rules, pointing at an admin-owned copy of the check in `/usr/local/lib/downloads-guard` or `C:\Program Files\downloads-guard`. A project's `.claude/settings.json` can set `"disableAllHooks": true` and silence user-level hooks; it cannot silence managed hooks ([hooks docs](https://code.claude.com/docs/en/hooks.md), [managed settings](https://code.claude.com/docs/en/managed-settings.md)).
- **OpenCode managed config**: the edit deny rules in `/etc/opencode/opencode.json`, `/Library/Application Support/opencode/opencode.json` or `%ProgramData%\opencode\opencode.json`, which "override everything" ([config docs](https://opencode.ai/docs/config/)).
- **Immutability** on the global agent configs (Claude `settings.json`, Codex `hooks.json` and `config.toml`, Cursor `hooks.json`, `cli-config.json` and `mcp.json`, OpenCode `opencode.json` and the plugin, the Pi extension, `models.json` and `mcp.json`), on downloads-guard's own files, and on the decoy files: `chattr +i` on Linux, `chflags schg` on macOS, and on Windows an ACL that makes Administrators the owner and leaves you read access.

While the locks are on, you (and your agents) cannot change those files. That includes Codex saving a new project trust decision to `config.toml`, the Cursor CLI saving preferences, and edits to `~/.downloads-guard/config`. To change something:

```sh
downloads-guard unlock    # asks for sudo (an elevated PowerShell on Windows)
# ...edit...
downloads-guard lock
```

`~/.claude.json` is never locked: Claude Code writes to it all the time.

## VS Code (Claude Code extension)

The extension starts its own bundled `claude`, so shell wrappers never see it. Its `claudeCode.claudeProcessWrapper` setting names a program that is started instead, with the bundled binary path as its first argument ([VS Code docs](https://code.claude.com/docs/en/vs-code.md)). Point it at the wrapper:

```json
"claudeCode.claudeProcessWrapper": "/Users/you/.downloads-guard/bin/claude-process-wrapper"
```

On Windows use `C:\\Users\\you\\.downloads-guard\\bin\\claude-process-wrapper.cmd`. The hooks in `~/.claude/settings.json` apply to the extension either way.

## Limitations

- **Not covered:** the Claude and Codex desktop apps, cloud agents (Claude Code on the web, Codex cloud, Cursor background agents), GitHub Copilot and Windsurf.
- **Safari:** how Safari names a download whose name is taken has no primary source, and reports describe it as buggy, so layer 3 is unverified with Safari.
- **Agents started elsewhere** that later read files in Downloads are covered only by layer 2. Layer 1 checks the folder an agent starts in (and, for Claude Code, the session folder reported with each prompt and tool call).
- **Same-user locks are speed bumps.** `chmod`, `chflags uchg`, the read-only attribute, the deny rules and the hooks in your own settings files can all be undone by any process running as you, the agent included, if it has a shell. Only `--system` resists that. On Windows even the admin ACL leaves one gap: you keep the right to delete files inside folders you own, so a deleted settings file or decoy can be replaced; the managed Claude Code and OpenCode settings in admin-only folders are not affected.
- **Claude Code `disableAllHooks`:** a project `.claude/settings.json` with `"disableAllHooks": true` turns off the hooks in your user settings. A browser cannot create a `.claude/` folder (leading dots are stripped), and the prompt hook stops the agent before it could write one, but an agent started outside Downloads could. `--system` closes this, because managed hooks cannot be disabled from outside managed settings ([hooks docs](https://code.claude.com/docs/en/hooks.md)).
- **Managed settings ranking:** if your organization already delivers Claude Code policy through MDM or the registry, Claude Code may use that source and skip the file-based one ([managed settings](https://code.claude.com/docs/en/managed-settings.md)).
- **Pi shutdown is best effort.** Pi documents `ctx.shutdown()` but not whether it works inside `session_start`. If it does not, Pi stays open but every tool call is blocked and the project is not trusted.
- **Codex hook trust:** Codex skips a hook until you trust it in `/hooks`, and again after it changes. The shell wrapper does not depend on this.
- **Aliases win over wrappers.** If you have an alias named `claude` (or another wrapped name), your shell expands it before the wrapper function. Remove the alias or point it at the function.
- **Windows hooks are slower.** Each hook call starts Windows PowerShell and compiles the small helper that calls the Known Folder API, which takes noticeably longer than on macOS and Linux.
- Paths that contain a newline are not supported.

## Development

```sh
bash tests/posix/run.sh              # macOS and Linux: check, hooks, wrappers, installer
node --test "tests/node/*.test.mjs"  # OpenCode plugin and Pi extension
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\run.ps1
```

All tests use a temporary home folder and temporary Downloads folders; the `--system` tests replace `sudo`, `chattr`, `chflags`, `chown` and `icacls` with logging stand-ins. GitHub Actions runs them on Ubuntu, macOS and Windows.
