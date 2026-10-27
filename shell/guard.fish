# downloads-guard wrappers for fish. install.sh writes this file to
# conf.d/downloads-guard.fish with __dg_cli set on the first line.
# Each wrapper asks the shared check first and starts the real tool only outside
# the Downloads folder. Arguments are passed through unchanged.

function __dg_run
    /bin/sh $__dg_cli check-cwd $argv[1]; or return $status
    command $argv
end

function claude --wraps claude
    __dg_run claude $argv
end
function codex --wraps codex
    __dg_run codex $argv
end
function opencode --wraps opencode
    __dg_run opencode $argv
end
function agent --wraps agent
    __dg_run agent $argv
end
function cursor-agent --wraps cursor-agent
    __dg_run cursor-agent $argv
end
function pi --wraps pi
    __dg_run pi $argv
end
function downloads-guard
    /bin/sh $__dg_cli $argv
end
