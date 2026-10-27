# downloads-guard wrappers for bash and zsh. Sourced from your shell rc file by a
# block that install.sh adds; _dg_cli is set by that block.
# Each wrapper asks the shared check first and starts the real tool only outside
# the Downloads folder. Arguments are passed through unchanged.

# shellcheck disable=SC2154 # _dg_cli is set by the rc block
_dg_run() {
  local _dg_tool=$1
  shift
  /bin/sh "$_dg_cli" check-cwd "$_dg_tool" || return $?
  command "$_dg_tool" "$@"
}

# The "function NAME" form keeps an existing alias from being expanded here.
function claude { _dg_run claude "$@"; }
function codex { _dg_run codex "$@"; }
function opencode { _dg_run opencode "$@"; }
function agent { _dg_run agent "$@"; }
function cursor-agent { _dg_run cursor-agent "$@"; }
function pi { _dg_run pi "$@"; }
function downloads-guard { /bin/sh "$_dg_cli" "$@"; }
