# downloads-guard wrappers for PowerShell (Windows PowerShell 5.1 and PowerShell 7).
# Dot-sourced from your PowerShell profile by a block that install.ps1 adds; that block
# sets $global:DGRoot. Each wrapper asks the shared check first and starts the real tool
# only outside the Downloads folder. Arguments are passed through unchanged.

function global:Invoke-DGGuardedTool {
  param([string]$Tool, [object[]]$ToolArgs)
  try {
    if (-not (Get-Module -Name DownloadsGuard)) {
      Import-Module (Join-Path (Join-Path $global:DGRoot 'lib') 'DownloadsGuard.psm1') -ErrorAction Stop -DisableNameChecking
    }
    $hit = Find-DGProtectedHit -Paths (Get-DGCurrentFolders)
  } catch {
    [Console]::Error.WriteLine("downloads-guard: could not check this folder ($($_.Exception.Message)), so $Tool was not started.")
    $global:LASTEXITCODE = 4
    return
  }
  if ($hit) {
    [Console]::Error.WriteLine((Get-DGRefuseMessage $Tool $hit.Dir $hit.Root))
    $global:LASTEXITCODE = 3
    return
  }
  $cmd = Get-Command -Name $Tool -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    [Console]::Error.WriteLine("${Tool}: command not found")
    $global:LASTEXITCODE = 127
    return
  }
  if ($null -eq $ToolArgs) { $ToolArgs = @() }
  & $cmd.Source @ToolArgs
}

function global:claude { Invoke-DGGuardedTool -Tool 'claude' -ToolArgs $args }
function global:codex { Invoke-DGGuardedTool -Tool 'codex' -ToolArgs $args }
function global:opencode { Invoke-DGGuardedTool -Tool 'opencode' -ToolArgs $args }
function global:agent { Invoke-DGGuardedTool -Tool 'agent' -ToolArgs $args }
function global:cursor-agent { Invoke-DGGuardedTool -Tool 'cursor-agent' -ToolArgs $args }
function global:pi { Invoke-DGGuardedTool -Tool 'pi' -ToolArgs $args }
function global:downloads-guard {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $global:DGRoot 'bin') 'downloads-guard.ps1') @args
}
