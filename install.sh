#!/bin/sh
# install.sh: install, update or remove downloads-guard on macOS and Linux.
#
#   ./install.sh               install for the current user (no sudo needed)
#   ./install.sh --system      also install the admin tier (asks for sudo)
#   ./install.sh --dry-run     print every change and write nothing
#   ./install.sh --uninstall   remove exactly what was installed
#
# Running it again updates an existing install in place.

# shellcheck disable=SC2088,SC2015,SC2016 # "~/..." strings are written for the harnesses to expand
set -u
unset CDPATH
umask 022

DG_SRC=$(cd -P -- "$(dirname -- "$0")" && pwd -P) || exit 1
DRY=0
UNINSTALL=0
SYSTEM=0

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case $arg in
    --dry-run) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --system) SYSTEM=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'install.sh: unknown option %s\n' "$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

OS=$(uname -s)
case $OS in
  Linux | Darwin) ;;
  *) die "unsupported system $OS (use install.ps1 on Windows)" ;;
esac
[ -n "${HOME:-}" ] || die "HOME is not set"
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
  die "run install.sh as yourself, not with sudo; --system asks for sudo when it needs it"
fi
command -v python3 >/dev/null 2>&1 && python3 -I -c 'import json' >/dev/null 2>&1 ||
  die "python3 is needed to edit the agents' JSON settings safely; install it and run again"

DG_HOME=$HOME/.downloads-guard
STATE=$DG_HOME/state
MANIFEST=$STATE/manifest
BACKUPS=$DG_HOME/backups
CLI=$DG_HOME/bin/downloads-guard
MARK_BEGIN='# >>> downloads-guard >>>'
MARK_END='# <<< downloads-guard <<<'

SYS_PREFIX=${DG_SYSTEM_PREFIX:-}
SYS_GUARD=$SYS_PREFIX/usr/local/lib/downloads-guard
if [ "$OS" = Darwin ]; then
  CLAUDE_MANAGED_DIR="$SYS_PREFIX/Library/Application Support/ClaudeCode"
  OPENCODE_MANAGED_DIR="$SYS_PREFIX/Library/Application Support/opencode"
  ROOT_GROUP=wheel
else
  CLAUDE_MANAGED_DIR=$SYS_PREFIX/etc/claude-code
  OPENCODE_MANAGED_DIR=$SYS_PREFIX/etc/opencode
  ROOT_GROUP=root
fi
CLAUDE_DROPIN=$CLAUDE_MANAGED_DIR/managed-settings.d/50-downloads-guard.json

# Tests set DG_SUDO (even empty) to stand in for sudo.
if [ "${DG_SUDO+set}" = set ]; then
  SUDO=$DG_SUDO
elif [ "$(id -u)" = 0 ]; then
  SUDO=
else
  SUDO=sudo
fi

# ------------------------------------------------------------------ helpers

NL='
'

# Quote a string for a POSIX shell command line.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# Quote a string for fish.
fishq() { printf "'%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"; }

has() { command -v "$1" >/dev/null 2>&1; }

run() {  # run CMD...: run, or print in dry-run mode
  if [ $DRY = 1 ]; then
    say "would run: $*"
  else
    "$@"
  fi
}

priv() {  # run a command with admin rights
  if [ $DRY = 1 ]; then
    say "would run as admin: $*"
    return 0
  fi
  if [ -n "$SUDO" ]; then
    # shellcheck disable=SC2086 # SUDO may carry arguments
    $SUDO "$@"
  else
    "$@"
  fi
}

record() {  # record KIND NAME PATH [EXTRA]
  [ $DRY = 1 ] && return 0
  mkdir -p "$STATE"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$MANIFEST"
}

write_file() {  # write_file DEST MODE  (content on stdin), atomically
  _dest=$1
  _mode=$2
  if [ $DRY = 1 ]; then
    say "would write $_dest:"
    sed 's/^/    | /'
    return 0
  fi
  mkdir -p "$(dirname -- "$_dest")"
  _tmp=$_dest.dg-tmp.$$
  cat >"$_tmp" && chmod "$_mode" "$_tmp" && mv -f "$_tmp" "$_dest"
}

# note_dirs PATH: record the folders that writing PATH will create, outermost first,
# so that --uninstall can remove them again (only if they are empty by then).
# note_sysdirs PATH: the same for admin-owned folders.
note_sysdirs() {
  _missing=
  _d=$1
  while [ ! -d "$_d" ]; do
    _missing="$_d$NL$_missing"
    _d=$(dirname -- "$_d")
  done
  printf '%s' "$_missing" | while IFS= read -r _m; do
    [ -n "$_m" ] && record sysemptydir dir "$_m"
  done
}

note_dirs() {
  _missing=
  _d=$(dirname -- "$1")
  while [ ! -d "$_d" ]; do
    _missing="$_d$NL$_missing"
    _d=$(dirname -- "$_d")
  done
  printf '%s' "$_missing" | while IFS= read -r _m; do
    [ -n "$_m" ] && record dir dir "$_m"
  done
}

copy_file() {  # copy_file SRC DEST MODE
  if [ $DRY = 1 ]; then
    say "would copy $1 -> $2"
    return 0
  fi
  write_file "$2" "$3" <"$1"
}

# Replace __DG_ROOT__ in a JS/TS template with a JSON-escaped path.
render_js() {  # render_js TEMPLATE ROOT
  python3 -I -c '
import json, sys
src, root = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
sys.stdout.write(text.replace("__DG_ROOT__", json.dumps(root)[1:-1]))
' "$1" "$2"
}

jsonmerge() {
  if [ $DRY = 1 ]; then
    python3 -I "$DG_SRC/lib/jsonmerge.py" "$@" --dry-run
  else
    python3 -I "$DG_SRC/lib/jsonmerge.py" "$@"
  fi
}

# Path as written inside harness settings: "~/x" when under $HOME.
tilde() {
  case $1 in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ------------------------------------------------------------------ where things live

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CODEX_DIR=${CODEX_HOME:-$HOME/.codex}
CURSOR_DIR=$HOME/.cursor
if [ -n "${CURSOR_CONFIG_DIR:-}" ]; then
  CURSOR_CLI_CONFIG=$CURSOR_CONFIG_DIR/cli-config.json
elif [ "$OS" = Linux ] && [ -n "${XDG_CONFIG_HOME:-}" ] && [ -f "$XDG_CONFIG_HOME/cursor/cli-config.json" ]; then
  CURSOR_CLI_CONFIG=$XDG_CONFIG_HOME/cursor/cli-config.json
else
  CURSOR_CLI_CONFIG=$CURSOR_DIR/cli-config.json
fi
OPENCODE_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/opencode
PI_DIR=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
FISH_CONF=${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/downloads-guard.fish

want_claude() { [ -d "$CLAUDE_DIR" ] || has claude; }
want_codex() { [ -d "$CODEX_DIR" ] || has codex; }
want_cursor() { [ -d "$CURSOR_DIR" ] || has agent || has cursor-agent || has cursor; }
want_opencode() { [ -d "$OPENCODE_DIR" ] || has opencode; }
want_pi() { [ -d "$PI_DIR" ] || has pi; }

# ------------------------------------------------------------------ rc blocks

remove_block() {  # remove_block FILE CREATED(yes|no)
  _f=$1
  [ -f "$_f" ] || return 0
  grep -qF "$MARK_BEGIN" "$_f" || return 0
  if [ $DRY = 1 ]; then
    say "would remove the downloads-guard block from $_f"
    return 0
  fi
  _tmp=$_f.dg-tmp.$$
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { print }' "$_f" >"$_tmp" || return 1
  if [ "$2" = yes ] && ! grep -q '[^[:space:]]' "$_tmp"; then
    rm -f "$_tmp" "$_f"
  else
    cat "$_tmp" >"$_f" && rm -f "$_tmp" # keep the original inode, owner and mode
  fi
}

add_block() {  # add_block FILE NAME [bash-only]
  _f=$1
  _created=no
  [ -e "$_f" ] || _created=yes
  remove_block "$_f" no
  # ~/.profile is also read by other sh-family shells; load the bash/zsh wrappers only in bash.
  _cond=
  [ "${3:-}" = bash-only ] && _cond='[ -n "${BASH_VERSION:-}" ] && '
  _body="$MARK_BEGIN
# Added by downloads-guard. Remove with: ~/.downloads-guard/install.sh --uninstall
_dg_cli=$(shq "$CLI")
${_cond}[ -r $(shq "$DG_HOME/shell/guard.sh") ] && . $(shq "$DG_HOME/shell/guard.sh")
$MARK_END"
  if [ $DRY = 1 ]; then
    say "would add to $_f:"
    printf '%s\n' "$_body" | sed 's/^/    | /'
  else
    mkdir -p "$(dirname -- "$_f")"
    # Start on a new line even if the file does not end with one.
    if [ -s "$_f" ] && [ -n "$(tail -c 1 "$_f")" ]; then printf '\n' >>"$_f"; fi
    printf '%s\n' "$_body" >>"$_f"
  fi
  record rc "$2" "$_f" "$_created"
}

# ------------------------------------------------------------------ layer 3 files

SQUAT_NAMES="AGENTS.md CLAUDE.md CLAUDE.local.md AGENTS.override.md"
[ "$OS" = Linux ] && SQUAT_NAMES="$SQUAT_NAMES AGENTS.MD CLAUDE.MD"

is_our_squat() {  # is_our_squat PATH
  case $1 in
    */opencode.json | */opencode.jsonc) cmp -s "$1" "$DG_SRC/templates/opencode.json" ;;
    *) grep -q 'downloads-guard:squat' "$1" 2>/dev/null ;;
  esac
}

user_unlock() {
  if [ "$OS" = Darwin ]; then run chflags nouchg "$1"; else run chmod 644 "$1"; fi
}

user_lock() {
  if [ "$OS" = Darwin ]; then run chflags uchg "$1"; else run chmod 444 "$1"; fi
}

install_squats() {
  _dirs=$(sh "$DG_SRC/bin/downloads-guard" downloads-dirs) || die "could not find the Downloads folder"
  _any=0
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    if [ ! -d "$_d" ]; then
      say "skip: $_d does not exist, so no decoy files there"
      continue
    fi
    _any=1
    for _n in $SQUAT_NAMES opencode.json opencode.jsonc; do
      _p=$_d/$_n
      case $_n in
        opencode.json*) _tpl=$DG_SRC/templates/opencode.json ;;
        *) _tpl=$DG_SRC/templates/squat.md ;;
      esac
      if [ -e "$_p" ] && ! is_our_squat "$_p"; then
        warn "$_p already exists and was not made by downloads-guard. Look at it (it may be the kind of file this tool guards against), delete it, and run the installer again."
        record squat-foreign "$_n" "$_p"
        continue
      fi
      [ -e "$_p" ] && user_unlock "$_p"
      copy_file "$_tpl" "$_p" 644
      user_lock "$_p"
      record squat "$_n" "$_p" same-user
    done
  done <<EOF
$_dirs
EOF
  [ $_any = 1 ] || warn "no Downloads folder exists yet, so no decoy files were placed"
}

# ------------------------------------------------------------------ uninstall

uninstall_from_manifest() {
  [ -f "$MANIFEST" ] || return 0
  if [ -s "$STATE/locked" ]; then
    say "Removing the system file locks first (needs sudo)."
    if [ $DRY = 1 ]; then
      sed 's/^/would unlock: /' "$STATE/locked"
    else
      DG_SUDO=$SUDO sh "$CLI" unlock || die "could not remove the system locks; run 'downloads-guard unlock' and try again"
    fi
  fi
  # Undo in reverse order of installation.
  awk '{ l[NR] = $0 } END { for (i = NR; i >= 1; i--) print l[i] }' "$MANIFEST" |
    while IFS="$(printf '\t')" read -r _kind _name _path _extra; do
      case $_kind in
        rc) remove_block "$_path" "$_extra" ;;
        json) jsonmerge revert --state "$_extra" --backup-dir "$BACKUPS" ;;
        file) [ -e "$_path" ] && run rm -f "$_path" ;;
        dir) [ -d "$_path" ] && { run rmdir "$_path" 2>/dev/null || true; } ;;
        squat)
          if [ -e "$_path" ] && is_our_squat "$_path"; then
            user_unlock "$_path"
            run rm -f "$_path"
          fi
          ;;
        sysjson)
          if [ $DRY = 1 ]; then
            say "would revert $_path (as admin)"
          else
            # The admin-owned copy, never the user-writable one, runs as root.
            if [ -f "$SYS_GUARD/lib/jsonmerge.py" ]; then
              priv python3 -I "$SYS_GUARD/lib/jsonmerge.py" revert --state "$_extra"
            else
              warn "$SYS_GUARD/lib/jsonmerge.py is missing; remove the downloads-guard entries from $_path by hand (as admin)"
            fi
          fi
          ;;
        sysfile) priv rm -f "$_path" ;;
        sysemptydir) [ -d "$_path" ] && { priv rmdir "$_path" 2>/dev/null || true; } ;;
        sysdir)
          case $_path in
            */downloads-guard) priv rm -rf "$_path" ;;
            *) warn "not removing unexpected system folder $_path" ;;
          esac
          ;;
      esac
    done
}

uninstall_all() {  # uninstall_all KEEP_CONFIG(0|1)
  uninstall_from_manifest
  if [ -d "$DG_HOME" ]; then
    if [ "$1" = 1 ]; then
      for _x in "$DG_HOME"/* "$DG_HOME"/.[!.]*; do
        [ -e "$_x" ] || continue
        case $_x in
          "$DG_HOME/config" | "$DG_HOME/backups") ;;
          *) run rm -rf "$_x" ;;
        esac
      done
    else
      run rm -rf "$DG_HOME"
    fi
  fi
}

# Without an install record (for example after ~/.downloads-guard was deleted by hand), find
# downloads-guard's entries by their marker in every place the installer writes to. Left in
# place, hooks that point at a missing check would block every agent everywhere.
fallback_cleanup() {
  say "No install record found; removing downloads-guard entries from every place the installer writes to."
  for _f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" "${ZDOTDIR:-$HOME}/.zshrc"; do
    remove_block "$_f" no
  done
  for _f in "$CLAUDE_DIR/settings.json" "$CODEX_DIR/hooks.json" "$CURSOR_DIR/hooks.json" "$CURSOR_CLI_CONFIG" "$OPENCODE_DIR/opencode.json"; do
    if [ -f "$_f" ] && grep -q downloads-guard "$_f"; then
      jsonmerge strip --file "$_f" || warn "could not clean $_f; remove the downloads-guard entries by hand"
    fi
  done
  for _f in "$FISH_CONF" "$OPENCODE_DIR/plugins/downloads-guard.js" "$PI_DIR/extensions/downloads-guard.ts"; do
    if [ -e "$_f" ]; then run rm -f "$_f"; fi
  done
  _dirs=$(sh "$DG_SRC/bin/downloads-guard" downloads-dirs 2>/dev/null) || _dirs=
  while IFS= read -r _d; do
    [ -n "$_d" ] && [ -d "$_d" ] || continue
    for _n in $SQUAT_NAMES opencode.json opencode.jsonc; do
      if [ -e "$_d/$_n" ] && is_our_squat "$_d/$_n"; then
        user_unlock "$_d/$_n"
        run rm -f "$_d/$_n"
      fi
    done
  done <<EOF
$_dirs
EOF
  for _f in "$CLAUDE_DROPIN" "$SYS_GUARD"; do
    [ -e "$_f" ] && warn "$_f is still there (from --system); remove it as admin"
  done
  return 0
}

if [ $UNINSTALL = 1 ]; then
  if [ ! -f "$MANIFEST" ]; then
    fallback_cleanup
    [ -d "$DG_HOME" ] && run rm -rf "$DG_HOME"
    if [ $DRY = 1 ]; then say "Dry run: nothing was changed."; else say "downloads-guard removed. Open a new terminal so the shell wrappers are gone."; fi
    exit 0
  fi
  uninstall_all 0
  if [ $DRY = 1 ]; then
    say "Dry run: nothing was changed."
  else
    say "downloads-guard removed. Open a new terminal so the shell wrappers are gone."
  fi
  exit 0
fi

# ------------------------------------------------------------------ install

if [ "$DG_SRC" = "$DG_HOME" ]; then
  die "run install.sh from the downloads-guard source folder, not from $DG_HOME (that copy is only for --uninstall)"
fi

if [ -f "$MANIFEST" ]; then
  if [ -s "$STATE/locked" ] && [ $SYSTEM = 0 ]; then
    die "the system file locks are on. Run 'downloads-guard unlock' (needs sudo) or re-run with --system"
  fi
  say "Updating the existing install."
  uninstall_all 1
fi

say "Installing downloads-guard for $(id -un) into $DG_HOME"

# Payload.
copy_file "$DG_SRC/bin/downloads-guard" "$DG_HOME/bin/downloads-guard" 755
copy_file "$DG_SRC/bin/claude-process-wrapper" "$DG_HOME/bin/claude-process-wrapper" 755
copy_file "$DG_SRC/lib/jsonmerge.py" "$DG_HOME/lib/jsonmerge.py" 644
copy_file "$DG_SRC/install.sh" "$DG_HOME/install.sh" 755
copy_file "$DG_SRC/templates/squat.md" "$DG_HOME/templates/squat.md" 644
copy_file "$DG_SRC/templates/opencode.json" "$DG_HOME/templates/opencode.json" 644
copy_file "$DG_SRC/shell/guard.sh" "$DG_HOME/shell/guard.sh" 644
gen_fish() {
  printf 'set -g __dg_cli %s\n' "$(fishq "$CLI")"
  cat "$DG_SRC/shell/guard.fish"
}
gen_fish | write_file "$DG_HOME/shell/guard.fish" 644
if [ ! -f "$DG_HOME/config" ]; then
  write_file "$DG_HOME/config" 644 <<'EOF'
# downloads-guard: extra folders to protect, one absolute path per line.
# Your Downloads folder is always protected; it does not need to be listed.
# A path that is your home folder (or above it) is ignored.
# Example:
# ~/Desktop/unsorted
EOF
fi

# Layer 1: shell wrappers.
add_block "$HOME/.bashrc" bash
if [ "$OS" = Darwin ]; then
  # Terminal on macOS starts login shells, which read the first of these that exists.
  if [ -f "$HOME/.bash_profile" ]; then
    add_block "$HOME/.bash_profile" bash-login
  elif [ -f "$HOME/.bash_login" ]; then
    add_block "$HOME/.bash_login" bash-login
  else
    add_block "$HOME/.profile" bash-login bash-only
  fi
fi
if has zsh || [ -f "${ZDOTDIR:-$HOME}/.zshrc" ]; then
  add_block "${ZDOTDIR:-$HOME}/.zshrc" zsh
fi
if has fish || [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/fish" ]; then
  note_dirs "$FISH_CONF"
  gen_fish | write_file "$FISH_CONF" 644
  record file fish "$FISH_CONF"
fi

hook_cmd() { printf '/bin/sh %s hook %s' "$(shq "$1")" "$2"; }
DG_TILDE=$(tilde "$DG_HOME")

claude_denies() {
  # Narrow on purpose: memory, projects and everything else under ~/.claude stay writable.
  printf '%s\n' "Edit(~/.claude.json)"
  if [ "$CLAUDE_DIR" = "$HOME/.claude" ]; then
    printf '%s\n' "Edit(~/.claude/settings*.json)"
  else
    printf '%s\n' "Edit(/$CLAUDE_DIR/settings*.json)"
  fi
  printf '%s\n' "Edit(**/.claude/settings*.json)" "Edit(**/.mcp.json)" "Edit($DG_TILDE/**)"
}

# with_denies CMD...: run CMD with "--deny RULE" appended for each Claude deny rule.
with_denies() {
  _old_ifs=$IFS
  IFS=$NL
  set -f
  # shellcheck disable=SC2046 # split on newlines only, globbing off
  set -- "$@" $(claude_denies | while IFS= read -r _l; do printf -- '--deny\n%s\n' "$_l"; done)
  IFS=$_old_ifs
  set +f
  "$@"
}

json_apply() {  # json_apply NAME PROFILE FILE ARGS...
  _name=$1
  _profile=$2
  _file=$3
  shift 3
  _state=$STATE/json-$_name.json
  note_dirs "$_file"
  if jsonmerge apply --profile "$_profile" --file "$_file" --state "$_state" --backup-dir "$BACKUPS" "$@"; then
    record json "$_name" "$_file" "$_state"
  else
    warn "skipped $_file (see the message above); downloads-guard did not change it"
  fi
}

# Layers 1 and 2: native hooks and deny rules.
if want_claude; then
  say "Claude Code: hooks and deny rules in $CLAUDE_DIR/settings.json"
  with_denies json_apply claude claude "$CLAUDE_DIR/settings.json" --hook-command "$(hook_cmd "$CLI" claude)"
fi
if want_codex; then
  say "Codex: UserPromptSubmit hook in $CODEX_DIR/hooks.json"
  json_apply codex codex "$CODEX_DIR/hooks.json" --hook-command "$(hook_cmd "$CLI" codex)"
  say "  Codex runs a new hook only after you trust it: start codex, open /hooks and trust the downloads-guard hook."
fi
if want_cursor; then
  say "Cursor: beforeSubmitPrompt hook in $CURSOR_DIR/hooks.json, Write denies in $CURSOR_CLI_CONFIG"
  json_apply cursor-hooks cursor-hooks "$CURSOR_DIR/hooks.json" --hook-command "$(hook_cmd "$CLI" cursor)"
  json_apply cursor-cli cursor-cli "$CURSOR_CLI_CONFIG" \
    --deny "Write($CURSOR_CLI_CONFIG)" --deny "Write($CURSOR_DIR/hooks.json)" \
    --deny "Write($CURSOR_DIR/mcp.json)" --deny "Write($DG_HOME/**)"
fi
if want_opencode; then
  say "OpenCode: plugin in $OPENCODE_DIR/plugins, edit denies in $OPENCODE_DIR/opencode.json"
  note_dirs "$OPENCODE_DIR/plugins/downloads-guard.js"
  render_js "$DG_SRC/integrations/opencode/downloads-guard.js" "$DG_HOME" |
    write_file "$OPENCODE_DIR/plugins/downloads-guard.js" 644
  record file opencode-plugin "$OPENCODE_DIR/plugins/downloads-guard.js"
  if [ -f "$OPENCODE_DIR/opencode.jsonc" ] && [ ! -f "$OPENCODE_DIR/opencode.json" ]; then
    warn "$OPENCODE_DIR/opencode.jsonc has comments that downloads-guard cannot keep; add this by hand: \"permission\": {\"edit\": {\"$(tilde "$OPENCODE_DIR")/*\": \"deny\", \"$DG_TILDE/*\": \"deny\"}}"
  else
    json_apply opencode opencode "$OPENCODE_DIR/opencode.json" \
      --pattern "$(tilde "$OPENCODE_DIR")/*" --pattern "$DG_TILDE/*"
  fi
fi
if want_pi; then
  say "Pi: extension in $PI_DIR/extensions"
  note_dirs "$PI_DIR/extensions/downloads-guard.ts"
  render_js "$DG_SRC/integrations/pi/downloads-guard.ts" "$DG_HOME" |
    write_file "$PI_DIR/extensions/downloads-guard.ts" 644
  record file pi-extension "$PI_DIR/extensions/downloads-guard.ts"
fi

# Layer 3: decoy instruction files in Downloads.
install_squats

# ------------------------------------------------------------------ --system (admin tier)

if [ $SYSTEM = 1 ]; then
  say "System tier: admin-owned copy in $SYS_GUARD (asks for sudo)"
  note_sysdirs "$(dirname -- "$SYS_GUARD")"
  if [ $DRY = 0 ] && [ -n "$SUDO" ] && [ "$SUDO" = sudo ]; then
    sudo -v || die "sudo is needed for --system"
  fi
  priv mkdir -p "$SYS_GUARD/bin" "$SYS_GUARD/lib" "$SYS_GUARD/state"
  priv cp "$DG_SRC/bin/downloads-guard" "$DG_SRC/bin/claude-process-wrapper" "$SYS_GUARD/bin/"
  priv cp "$DG_SRC/lib/jsonmerge.py" "$SYS_GUARD/lib/"
  priv chmod 755 "$SYS_GUARD" "$SYS_GUARD/bin" "$SYS_GUARD/lib" "$SYS_GUARD/bin/downloads-guard" "$SYS_GUARD/bin/claude-process-wrapper"
  priv chmod 700 "$SYS_GUARD/state"
  priv chown -R "0:$ROOT_GROUP" "$SYS_GUARD"
  record sysdir system-guard "$SYS_GUARD"

  if want_claude; then
    say "Claude Code managed settings: $CLAUDE_DROPIN"
    _tmp=$(mktemp)
    with_denies python3 -I "$DG_SRC/lib/jsonmerge.py" render --profile claude-managed \
      --hook-command "$(hook_cmd "$SYS_GUARD/bin/downloads-guard" claude)" >"$_tmp"
    note_sysdirs "$(dirname -- "$CLAUDE_DROPIN")"
    if [ $DRY = 1 ]; then
      say "would write $CLAUDE_DROPIN (as admin):"
      sed 's/^/    | /' "$_tmp"
    else
      priv mkdir -p "$(dirname -- "$CLAUDE_DROPIN")"
      priv cp "$_tmp" "$CLAUDE_DROPIN"
      priv chmod 644 "$CLAUDE_DROPIN"
      priv chown "0:$ROOT_GROUP" "$CLAUDE_DROPIN"
    fi
    rm -f "$_tmp"
    record sysfile claude-managed "$CLAUDE_DROPIN"
  fi
  if want_opencode; then
    say "OpenCode managed config: $OPENCODE_MANAGED_DIR/opencode.json"
    _state=$SYS_GUARD/state/opencode-managed.json
    note_sysdirs "$OPENCODE_MANAGED_DIR"
    if [ $DRY = 1 ]; then
      say "would merge edit denies into $OPENCODE_MANAGED_DIR/opencode.json (as admin)"
    else
      priv mkdir -p "$OPENCODE_MANAGED_DIR"
      priv python3 -I "$SYS_GUARD/lib/jsonmerge.py" apply --profile opencode-managed \
        --file "$OPENCODE_MANAGED_DIR/opencode.json" --state "$_state" \
        --pattern "$(tilde "$OPENCODE_DIR")/*" --pattern "$DG_TILDE/*" ||
        warn "could not update the OpenCode managed config"
    fi
    record sysjson opencode-managed "$OPENCODE_MANAGED_DIR/opencode.json" "$_state"
  fi

  # Admin-only immutability: chattr +i (Linux) or chflags schg (macOS).
  if [ $DRY = 0 ]; then
    mkdir -p "$STATE" "$BACKUPS"
    : >"$STATE/lock-targets"
  fi
  add_target() {
    [ -e "$1" ] || return 0
    if [ $DRY = 1 ]; then say "would lock (as admin): $1"; else printf '%s\n' "$1" >>"$STATE/lock-targets"; fi
  }
  for _t in "$CLAUDE_DIR/settings.json" "$CODEX_DIR/hooks.json" "$CODEX_DIR/config.toml" \
    "$CURSOR_DIR/hooks.json" "$CURSOR_CLI_CONFIG" "$CURSOR_DIR/mcp.json" \
    "$OPENCODE_DIR/opencode.json" "$OPENCODE_DIR/plugins/downloads-guard.js" \
    "$PI_DIR/extensions/downloads-guard.ts" "$PI_DIR/models.json" "$PI_DIR/mcp.json" \
    "$DG_HOME/config"; do
    add_target "$_t"
  done
  for _t in bin lib shell templates; do
    for _f in "$DG_HOME/$_t"/*; do add_target "$_f"; done
    add_target "$DG_HOME/$_t"
  done
  add_target "$DG_HOME/install.sh"
  add_target "$DG_HOME"
  if [ -f "$MANIFEST" ]; then
    awk -F '\t' '$1 == "squat" { print $3 }' "$MANIFEST" | while IFS= read -r _t; do add_target "$_t"; done
  fi
  if [ $DRY = 1 ]; then
    say "would run: downloads-guard lock"
  else
    # Record before locking: the manifest lives in the state folder, which stays writable.
    DG_SUDO=$SUDO sh "$CLI" lock || warn "some files could not be locked (see above); the filesystem may not support it"
  fi
fi

if [ $DRY = 1 ]; then
  say "Dry run: nothing was changed."
else
  say ""
  say "Done. Open a new terminal (or run: . ~/.bashrc) so the wrappers load."
  say "Check it with: downloads-guard status"
fi
