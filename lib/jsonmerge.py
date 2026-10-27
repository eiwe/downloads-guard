#!/usr/bin/env python3
"""Merge downloads-guard entries into harness JSON config files, and take them out again.

Used by install.sh on macOS and Linux. install.ps1 carries the same logic in PowerShell.

Every change is recorded in a state file so that --uninstall removes exactly what was
added: hook entries are found by the "downloads-guard" marker in their command, list
values and map keys are removed only if they are still the values we wrote, scalars are
restored to their previous value, and containers or files we created are removed only
when they are empty again.

Usage:
  jsonmerge.py apply  --profile NAME --file PATH --state PATH [profile options] [--dry-run]
  jsonmerge.py revert --state PATH [--dry-run]
  jsonmerge.py render --profile claude-managed --hook-command CMD [--deny RULE ...]
  jsonmerge.py strip  --profile NAME --file PATH [--deny RULE ...] [--pattern P ...] [--dry-run]
                      (no state file: remove our hook entries by marker, rules by exact value)
"""

import argparse
import copy
import json
import os
import sys
import tempfile

MARKER = "downloads-guard"


class MergeError(Exception):
    pass


# ---------------------------------------------------------------- helpers


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if text.strip() == "":
        return {}
    try:
        doc = json.loads(text)
    except ValueError as e:
        raise MergeError("%s is not valid JSON (%s); not touching it" % (path, e))
    if not isinstance(doc, dict):
        raise MergeError("%s does not hold a JSON object; not touching it" % path)
    return doc


def read_text(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def same_json(text, doc):
    try:
        return (json.loads(text) if text.strip() else {}) == doc
    except ValueError:
        return False


def atomic_write_json(path, doc, mode=None):
    atomic_write_text(path, json.dumps(doc, indent=2, ensure_ascii=False) + "\n", mode)


def atomic_write_text(path, text, mode=None):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".dg-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def get_path(doc, path):
    cur = doc
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return None, False
        cur = cur[key]
    return cur, True


def set_path(doc, path, value):
    cur = doc
    for key in path[:-1]:
        cur = cur[key]
    cur[path[-1]] = value


def del_path(doc, path):
    cur = doc
    for key in path[:-1]:
        if not isinstance(cur, dict) or key not in cur:
            return
        cur = cur[key]
    if isinstance(cur, dict):
        cur.pop(path[-1], None)


def ensure_container(doc, path, kind, rec):
    """Walk path, creating missing dicts (and a final list/dict). Records what was created."""
    cur = doc
    for i, key in enumerate(path):
        last = i == len(path) - 1
        want = kind if last else dict
        if not isinstance(cur, dict):
            raise MergeError("expected an object at %s" % ".".join(path[:i]))
        if key not in cur:
            cur[key] = want()
            rec["created_paths"].append(list(path[: i + 1]))
        elif not isinstance(cur[key], want):
            raise MergeError(
                "%s is a %s, expected %s; not touching it"
                % (".".join(path[: i + 1]), type(cur[key]).__name__, want.__name__)
            )
        cur = cur[key]
    return cur


def has_marker(value):
    return MARKER in json.dumps(value, ensure_ascii=False)


def strip_marked_hooks(entries):
    """Remove our hook handlers from a hook event list. Returns (new_list, removed_count)."""
    out = []
    removed = 0
    for entry in entries:
        if isinstance(entry, dict) and isinstance(entry.get("hooks"), list):
            kept = [h for h in entry["hooks"] if not has_marker(h)]
            gone = len(entry["hooks"]) - len(kept)
            if gone:
                removed += gone
                if not kept:
                    continue
                entry = dict(entry)
                entry["hooks"] = kept
            out.append(entry)
        elif has_marker(entry):
            removed += 1
        else:
            out.append(entry)
    return out, removed


# ---------------------------------------------------------------- operations


def op_hook(doc, rec, path, entry):
    lst = ensure_container(doc, path, list, rec)
    cleaned, _ = strip_marked_hooks(lst)
    lst[:] = cleaned
    lst.append(entry)
    rec["hook_paths"].append(list(path))


def op_array_add(doc, rec, path, values):
    lst = ensure_container(doc, path, list, rec)
    for v in values:
        if v not in lst:
            lst.append(v)
            rec["array_added"].append({"path": list(path), "value": v})


def op_set(doc, rec, path, value):
    if len(path) > 1:
        ensure_container(doc, path[:-1], dict, rec)
    old, had = get_path(doc, path)
    rec["scalars"].append({"path": list(path), "had": had, "old": old, "new": value})
    set_path(doc, path, value)


def op_set_default(doc, rec, path, value):
    if len(path) > 1:
        ensure_container(doc, path[:-1], dict, rec)
    _, had = get_path(doc, path)
    if not had:
        set_path(doc, path, copy.deepcopy(value))
        rec["defaults"].append({"path": list(path), "value": value})


def op_map_set(doc, rec, path, key, value):
    """Set path[key] = value, where path holds an object. A string at path (or at its parent,
    for OpenCode's "permission": "allow" shorthand) is converted to {"*": string} first."""
    for depth in range(1, len(path) + 1):
        sub = path[:depth]
        cur, had = get_path(doc, sub)
        if had and isinstance(cur, str):
            set_path(doc, sub, {"*": cur})
            rec["converted"].append({"path": list(sub), "old": cur})
    obj = ensure_container(doc, path, dict, rec)
    had = key in obj
    old = obj.get(key)
    if had and old == value:
        return
    obj.pop(key, None)  # re-insert so it sorts after "*": OpenCode uses the last matching rule
    obj[key] = value
    rec["map_entries"].append({"path": list(path), "key": key, "had": had, "old": old, "new": value})


# ---------------------------------------------------------------- profiles


def claude_handler(args):
    return {"type": "command", "command": args.hook_command, "timeout": 30, "onFailure": "block"}


def profile_ops(args):
    p = args.profile
    if p == "claude":
        h = claude_handler(args)
        ops = [
            ("hook", ["hooks", "UserPromptSubmit"], {"hooks": [h]}),
            ("hook", ["hooks", "PreToolUse"], {"matcher": "*", "hooks": [copy.deepcopy(h)]}),
        ]
        if args.deny:
            ops.append(("array_add", ["permissions", "deny"], args.deny))
        return ops
    if p == "codex":
        h = {"type": "command", "command": args.hook_command, "timeout": 30}
        return [("hook", ["hooks", "UserPromptSubmit"], {"hooks": [h]})]
    if p == "cursor-hooks":
        h = {"command": args.hook_command, "failClosed": True, "timeout": 30}
        return [("set_default", ["version"], 1), ("hook", ["hooks", "beforeSubmitPrompt"], h)]
    if p == "cursor-cli":
        return [
            ("set_default", ["version"], 1),
            ("set_default", ["editor"], {"vimMode": False}),
            ("set_default", ["permissions", "allow"], []),
            ("array_add", ["permissions", "deny"], args.deny or []),
        ]
    if p in ("opencode", "opencode-managed"):
        return [("map_set", ["permission", "edit"], pat, "deny") for pat in (args.pattern or [])]
    raise MergeError("unknown profile %r" % p)


def run_ops(doc, ops, rec):
    for op in ops:
        kind = op[0]
        if kind == "hook":
            op_hook(doc, rec, op[1], op[2])
        elif kind == "array_add":
            op_array_add(doc, rec, op[1], op[2])
        elif kind == "set":
            op_set(doc, rec, op[1], op[2])
        elif kind == "set_default":
            op_set_default(doc, rec, op[1], op[2])
        elif kind == "map_set":
            op_map_set(doc, rec, op[1], op[2], op[3])
        else:
            raise MergeError("unknown op %r" % kind)


def new_record(path, profile, created_file, original_text):
    return {
        "version": 1,
        "file": path,
        "profile": profile,
        "created_file": created_file,
        # The file as it was before the first install, so an uninstall that leaves the
        # same settings behind can put back the exact original bytes and formatting.
        "original_text": original_text,
        "created_paths": [],
        "hook_paths": [],
        "array_added": [],
        "scalars": [],
        "defaults": [],
        "map_entries": [],
        "converted": [],
    }


def revert_doc(doc, rec):
    for path in rec.get("hook_paths", []):
        lst, had = get_path(doc, path)
        if had and isinstance(lst, list):
            cleaned, _ = strip_marked_hooks(lst)
            lst[:] = cleaned
    for item in rec.get("array_added", []):
        lst, had = get_path(doc, item["path"])
        if had and isinstance(lst, list):
            while item["value"] in lst:
                lst.remove(item["value"])
    for item in reversed(rec.get("map_entries", [])):
        obj, had = get_path(doc, item["path"])
        if had and isinstance(obj, dict) and obj.get(item["key"]) == item["new"]:
            if item["had"]:
                obj[item["key"]] = item["old"]
            else:
                obj.pop(item["key"], None)
    for item in reversed(rec.get("scalars", [])):
        cur, had = get_path(doc, item["path"])
        if had and cur == item["new"]:
            if item["had"]:
                set_path(doc, item["path"], item["old"])
            else:
                del_path(doc, item["path"])
    for item in reversed(rec.get("defaults", [])):
        cur, had = get_path(doc, item["path"])
        if had and cur == item["value"]:
            del_path(doc, item["path"])
    for path in sorted(rec.get("created_paths", []), key=len, reverse=True):
        cur, had = get_path(doc, path)
        if had and isinstance(cur, (dict, list)) and len(cur) == 0:
            del_path(doc, path)
    for item in reversed(rec.get("converted", [])):
        cur, had = get_path(doc, item["path"])
        if had and cur == {"*": item["old"]}:
            set_path(doc, item["path"], item["old"])
    return doc


def backup(path, backup_dir):
    """Keep one copy of the file as it was before downloads-guard first changed it."""
    if not backup_dir or not os.path.exists(path):
        return None
    os.makedirs(backup_dir, exist_ok=True)
    dest = os.path.join(backup_dir, path.strip(os.sep).replace(os.sep, "_") + ".orig")
    if os.path.exists(dest):
        return dest
    with open(path, "rb") as src, open(dest, "wb") as out:
        out.write(src.read())
    os.chmod(dest, 0o600)
    return dest


def file_mode(path):
    """Keep an existing file's mode; give a new file the mode the umask allows."""
    try:
        return os.stat(path).st_mode & 0o7777
    except OSError:
        mask = os.umask(0)
        os.umask(mask)
        return 0o666 & ~mask


def cmd_apply(args):
    path = os.path.abspath(args.file)
    exists = os.path.exists(path)
    doc = load_json(path) if exists else {}
    original = copy.deepcopy(doc)
    created_file = not exists
    original_text = read_text(path) if exists else None

    # Idempotent re-install: undo the previous run's changes first, using its state.
    if os.path.exists(args.state):
        with open(args.state, "r", encoding="utf-8") as f:
            prev = json.load(f)
        doc = revert_doc(doc, prev)
        created_file = bool(prev.get("created_file")) or created_file
        original_text = prev.get("original_text")

    rec = new_record(path, args.profile, created_file, original_text)
    run_ops(doc, profile_ops(args), rec)

    if args.dry_run:
        print("would update %s:" % path)
        print(json.dumps(doc, indent=2, ensure_ascii=False))
        return 0
    if doc != original or not exists:
        backup(path, args.backup_dir)
        atomic_write_json(path, doc, file_mode(path))
    atomic_write_json(args.state, rec, 0o600)  # holds a copy of the original settings
    return 0


def cmd_revert(args):
    if not os.path.exists(args.state):
        return 0
    with open(args.state, "r", encoding="utf-8") as f:
        rec = json.load(f)
    path = rec["file"]
    if not os.path.exists(path):
        if args.dry_run:
            print("would remove state %s (file %s is gone)" % (args.state, path))
        else:
            os.unlink(args.state)
        return 0
    doc = load_json(path)
    original = copy.deepcopy(doc)
    doc = revert_doc(doc, rec)
    remove_file = rec.get("created_file") and doc == {}
    if args.dry_run:
        if remove_file:
            print("would remove %s (created by downloads-guard, now empty)" % path)
        elif doc != original:
            print("would update %s:" % path)
            print(json.dumps(doc, indent=2, ensure_ascii=False))
        return 0
    if remove_file:
        os.unlink(path)
    elif doc != original:
        restore_text = rec.get("original_text")
        if restore_text is not None and same_json(restore_text, doc):
            atomic_write_text(path, restore_text, file_mode(path))
        else:
            atomic_write_json(path, doc, file_mode(path))
    os.unlink(args.state)
    return 0


# What a settings file looks like when only downloads-guard's own scaffolding is left. A file
# that ends up exactly like this after a strip is deleted (it was made by the installer).
SKELETONS = {
    "claude": [{}],
    "codex": [{}],
    "cursor-hooks": [{}, {"version": 1}],
    "cursor-cli": [
        {},
        {"version": 1, "editor": {"vimMode": False}, "permissions": {"allow": []}},
        {"version": 1, "editor": {"vimMode": False}, "permissions": {"allow": [], "deny": []}},
    ],
    "opencode": [{}],
}


def prune_if_emptied(doc, path):
    """Delete the container at path if it is empty, then each parent that became empty."""
    for depth in range(len(path), 0, -1):
        cur, had = get_path(doc, path[:depth])
        if had and isinstance(cur, (dict, list)) and len(cur) == 0:
            del_path(doc, path[:depth])
        else:
            break


def strip_doc(doc, profile, denies, patterns):
    """Remove downloads-guard entries without a state file. Hook handlers are found by the
    marker in their command; deny rules and permission patterns only by their exact value,
    so a user's own rule that merely mentions downloads-guard is kept. Returns changed."""
    changed = False
    hooks, had = get_path(doc, ["hooks"])
    if had and isinstance(hooks, dict):
        for event in list(hooks.keys()):
            lst = hooks[event]
            if isinstance(lst, list):
                cleaned, removed = strip_marked_hooks(lst)
                if removed:
                    changed = True
                    if cleaned:
                        hooks[event] = cleaned
                    else:
                        del hooks[event]
        if changed:
            prune_if_emptied(doc, ["hooks"])
    if denies:
        lst, had = get_path(doc, ["permissions", "deny"])
        if had and isinstance(lst, list):
            kept = [v for v in lst if v not in denies]
            if len(kept) != len(lst):
                changed = True
                lst[:] = kept
                prune_if_emptied(doc, ["permissions", "deny"])
    if patterns:
        edit, had = get_path(doc, ["permission", "edit"])
        if had and isinstance(edit, dict):
            hit = [k for k in patterns if edit.get(k) == "deny"]
            if hit:
                changed = True
                for k in hit:
                    del edit[k]
                if not edit:
                    del_path(doc, ["permission", "edit"])
                    perm = doc.get("permission")
                    # Undo the installer's {"*": X} expansion of a "permission": X shorthand.
                    if isinstance(perm, dict) and list(perm.keys()) == ["*"] and isinstance(perm["*"], str):
                        doc["permission"] = perm["*"]
                    else:
                        prune_if_emptied(doc, ["permission"])
    return changed


def cmd_strip(args):
    path = os.path.abspath(args.file)
    if not os.path.exists(path):
        return 0
    doc = load_json(path)
    profile = args.profile or "claude"
    if not strip_doc(doc, profile, args.deny or [], args.pattern or []):
        return 0
    remove_file = doc in SKELETONS.get(profile, [{}])
    if args.dry_run:
        if remove_file:
            print("would remove %s (only downloads-guard's own scaffolding was left)" % path)
        else:
            print("would remove downloads-guard entries from %s:" % path)
            print(json.dumps(doc, indent=2, ensure_ascii=False))
        return 0
    if remove_file:
        os.unlink(path)
        print("removed %s (only downloads-guard's own scaffolding was left)" % path)
    else:
        atomic_write_json(path, doc, file_mode(path))
        print("removed downloads-guard entries from %s" % path)
    return 0


def cmd_render(args):
    if args.profile != "claude-managed":
        raise MergeError("render supports only claude-managed")
    h = claude_handler(args)
    doc = {
        "hooks": {
            "UserPromptSubmit": [{"hooks": [h]}],
            "PreToolUse": [{"matcher": "*", "hooks": [copy.deepcopy(h)]}],
        },
        "permissions": {"deny": list(args.deny or []), "disableBypassPermissionsMode": "disable"},
    }
    sys.stdout.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="jsonmerge.py")
    ap.add_argument("action", choices=["apply", "revert", "render", "strip"])
    ap.add_argument("--profile")
    ap.add_argument("--file")
    ap.add_argument("--state")
    ap.add_argument("--backup-dir")
    ap.add_argument("--hook-command")
    ap.add_argument("--deny", action="append")
    ap.add_argument("--pattern", action="append")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    try:
        if args.action == "apply":
            if not (args.profile and args.file and args.state):
                ap.error("apply needs --profile, --file and --state")
            return cmd_apply(args)
        if args.action == "strip":
            if not args.file:
                ap.error("strip needs --file")
            return cmd_strip(args)
        if args.action == "revert":
            if not args.state:
                ap.error("revert needs --state")
            return cmd_revert(args)
        return cmd_render(args)
    except MergeError as e:
        sys.stderr.write("downloads-guard: %s\n" % e)
        return 3


if __name__ == "__main__":
    sys.exit(main())
