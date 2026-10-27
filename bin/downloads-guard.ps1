# downloads-guard command line for Windows (Windows PowerShell 5.1 and PowerShell 7).
#
#   downloads-guard.ps1 status              protected folders, installed parts, current folder
#   downloads-guard.ps1 folders             list the protected folders
#   downloads-guard.ps1 check [PATH...]     exit 3 (and print the folder) if a path is protected
#   downloads-guard.ps1 hook HARNESS        Claude Code, Codex and Cursor hooks (JSON on stdin)
#   downloads-guard.ps1 wrap-exec CMD ...   run CMD unless the current folder is protected
#   downloads-guard.ps1 lock | unlock       --system file locks on or off (run as administrator)
#
# Exit codes: 0 allowed, 3 blocked, 4 could not decide (callers treat 4 as blocked).

$ErrorActionPreference = 'Stop'
$DGExitBlocked = 3
$DGExitError = 4
$DGRoot = Split-Path -Parent $PSScriptRoot

try {
  Import-Module (Join-Path (Join-Path $DGRoot 'lib') 'DownloadsGuard.psm1') -Force -DisableNameChecking
} catch {
  [Console]::Error.WriteLine("downloads-guard: could not load its module: $($_.Exception.Message)")
  exit $DGExitError
}

function Write-Err([string]$Text) { [Console]::Error.WriteLine($Text) }

function Read-StdinText {
  try {
    $stdin = [Console]::OpenStandardInput()
    $ms = New-Object IO.MemoryStream
    $stdin.CopyTo($ms)
    $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
  } catch {
    return ''
  }
}

function Invoke-Check([string[]]$Paths) {
  if (-not $Paths -or $Paths.Count -eq 0) { $Paths = Get-DGCurrentFolders }
  try { $hit = Find-DGProtectedHit -Paths $Paths } catch { Write-Err "downloads-guard: $($_.Exception.Message)"; return $DGExitError }
  if ($hit) { [Console]::Out.WriteLine($hit.Root); return $DGExitBlocked }
  return 0
}

function Invoke-CheckCwd([string]$Tool) {
  if (-not $Tool) { $Tool = 'the agent' }
  try { $hit = Find-DGProtectedHit -Paths (Get-DGCurrentFolders) } catch {
    Write-Err "downloads-guard: could not work out where Downloads is ($($_.Exception.Message)), so $Tool was not started"
    return $DGExitError
  }
  if ($hit) { Write-Err (Get-DGRefuseMessage $Tool $hit.Dir $hit.Root); return $DGExitBlocked }
  return 0
}

function Invoke-Hook([string]$Harness) {
  if (@('claude', 'codex', 'cursor') -notcontains $Harness) {
    Write-Err 'usage: downloads-guard.ps1 hook claude|codex|cursor'
    return 2
  }
  $raw = Read-StdinText
  $cands = New-Object System.Collections.ArrayList
  try {
    $j = $raw | ConvertFrom-Json
    if ($j -and $j.PSObject.Properties['cwd'] -and $j.cwd -is [string]) { [void]$cands.Add($j.cwd) }
    if ($j -and $j.PSObject.Properties['workspace_roots']) {
      foreach ($w in @($j.workspace_roots)) { if ($w -is [string]) { [void]$cands.Add($w) } }
    }
  } catch { }
  foreach ($e in @($env:CLAUDE_PROJECT_DIR, $env:CURSOR_PROJECT_DIR)) { if ($e) { [void]$cands.Add($e) } }
  foreach ($c in (Get-DGCurrentFolders)) { [void]$cands.Add($c) }

  $msg = $null
  try {
    $hit = Find-DGProtectedHit -Paths $cands.ToArray()
    if ($hit) { $msg = Get-DGHookMessage $hit.Dir $hit.Root }
  } catch {
    $msg = "downloads-guard could not work out where your Downloads folder is ($($_.Exception.Message)), so it blocked this to be safe. Run 'downloads-guard status' in a terminal."
  }
  if (-not $msg) {
    if ($Harness -eq 'cursor') { [Console]::Out.WriteLine('{"continue":true}') }
    return 0
  }
  if ($Harness -eq 'cursor') {
    $answer = New-Object System.Collections.Specialized.OrderedDictionary
    $answer['continue'] = $false
    $answer['user_message'] = $msg
    [Console]::Out.WriteLine(($answer | ConvertTo-Json -Compress))
  }
  Write-Err $msg
  return 2
}

function Invoke-Folders {
  [Console]::Out.WriteLine('Protected folders:')
  foreach ($f in (Get-DGProtectedFolders)) {
    if ($f.Path -eq $f.Canonical) { [Console]::Out.WriteLine("  $($f.Path)  ($($f.Source))") }
    else { [Console]::Out.WriteLine("  $($f.Path) -> $($f.Canonical)  ($($f.Source))") }
  }
  $ign = @(Get-DGIgnoredEntries)
  if ($ign.Count -gt 0) {
    [Console]::Out.WriteLine('Ignored entries:')
    foreach ($i in $ign) { [Console]::Out.WriteLine("  $i") }
  }
}

function Get-StateDir { Join-Path (Join-Path (Get-DGHome) '.downloads-guard') 'state' }

function Invoke-Status {
  [Console]::Out.WriteLine("downloads-guard $(Get-DGVersion)")
  [Console]::Out.WriteLine("Running from: $DGRoot")
  Invoke-Folders
  $hit = Find-DGProtectedHit -Paths (Get-DGCurrentFolders)
  if ($hit) { [Console]::Out.WriteLine("Current folder: $($hit.Dir) -> BLOCKED (inside $($hit.Root))") }
  else { [Console]::Out.WriteLine("Current folder: $((Get-DGCurrentFolders)[0]) -> allowed") }
  $policy = Get-ExecutionPolicy
  if (@('Restricted', 'AllSigned') -contains [string]$policy) {
    [Console]::Out.WriteLine("Execution policy: $policy. PowerShell profiles do not run, so the wrappers are NOT active. Run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned")
  } else {
    [Console]::Out.WriteLine("Execution policy: $policy")
  }
  $manifest = Join-Path (Get-StateDir) 'manifest.tsv'
  if (-not (Test-Path -LiteralPath $manifest)) {
    [Console]::Out.WriteLine("Installed components: none recorded (no $manifest)")
    return 0
  }
  [Console]::Out.WriteLine('Installed components:')
  foreach ($line in (Get-Content -LiteralPath $manifest -Encoding UTF8)) {
    $parts = $line.Split("`t")
    if ($parts.Count -lt 3) { continue }
    $kind = $parts[0]; $name = $parts[1]; $path = $parts[2]
    $extra = if ($parts.Count -gt 3) { $parts[3] } else { '' }
    $st = 'recorded'
    switch ($kind) {
      { @('profile', 'json', 'sysjson') -contains $_ } {
        $st = if ((Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -SimpleMatch 'downloads-guard' -Quiet)) { 'ok' } else { 'MISSING' }
      }
      { @('file', 'sysfile') -contains $_ } { $st = if (Test-Path -LiteralPath $path) { 'ok' } else { 'MISSING' } }
      'squat' {
        $st = if ((Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -Pattern 'downloads-guard:squat|"permission": "deny"' -Quiet)) { "ok, $extra lock" } else { 'MISSING' }
      }
    }
    if (@('dir', 'sysemptydir', 'sysdir') -contains $kind) { continue }
    [Console]::Out.WriteLine(('  {0,-14} {1,-40} {2}' -f $name, $path, $st))
  }
  $locked = Join-Path (Get-StateDir) 'locked.txt'
  if ((Test-Path -LiteralPath $locked) -and (@(Get-Content -LiteralPath $locked) | Where-Object { $_ }).Count -gt 0) {
    [Console]::Out.WriteLine("System locks: on for $(@(Get-Content -LiteralPath $locked | Where-Object { $_ }).Count) files (downloads-guard unlock to change them)")
  } else {
    [Console]::Out.WriteLine('System locks: off')
  }
  return 0
}

# ------------------------------------------------------------------ --system locks

function Test-Elevated {
  if ($env:OS -ne 'Windows_NT') { return $false }
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Tests point DG_ICACLS at a stand-in that only logs.
function Invoke-Icacls {
  $exe = if ($env:DG_ICACLS) { $env:DG_ICACLS } else { 'icacls.exe' }
  & $exe @args | Out-Null
  return ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
}

function Get-UserSid { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function Invoke-Lock {
  if (-not (Test-Elevated)) { Write-Err 'downloads-guard: lock needs an elevated PowerShell (Run as administrator).'; return 1 }
  $state = Get-StateDir
  $targets = Join-Path $state 'lock-targets.txt'
  if (-not (Test-Path -LiteralPath $targets)) { Write-Err 'downloads-guard: no lock targets recorded; install with --system first'; return 1 }
  $lockedFile = Join-Path $state 'locked.txt'
  $locked = New-Object System.Collections.ArrayList
  if (Test-Path -LiteralPath $lockedFile) { foreach ($l in (Get-Content -LiteralPath $lockedFile -Encoding UTF8)) { if ($l) { [void]$locked.Add($l) } } }
  $sid = Get-UserSid
  $rc = 0
  foreach ($t in (Get-Content -LiteralPath $targets -Encoding UTF8)) {
    if (-not $t -or -not (Test-Path -LiteralPath $t -PathType Leaf)) { continue }
    if ($locked -contains $t) { continue }
    # Administrators own the file; the user keeps read access only.
    $ok = (Invoke-Icacls $t '/setowner' '*S-1-5-32-544' '/Q') -and
      (Invoke-Icacls $t '/inheritance:r' '/grant:r' '*S-1-5-32-544:(F)' '*S-1-5-18:(F)' "*${sid}:(RX)" '/Q')
    if ($ok) { [void]$locked.Add($t); [Console]::Out.WriteLine("locked   $t") }
    else { Write-Err "downloads-guard: could not lock $t"; $rc = 1 }
  }
  Set-Content -LiteralPath $lockedFile -Value $locked.ToArray() -Encoding UTF8
  return $rc
}

function Invoke-Unlock {
  $state = Get-StateDir
  $lockedFile = Join-Path $state 'locked.txt'
  if (-not (Test-Path -LiteralPath $lockedFile)) { return 0 }
  if (-not (Test-Elevated)) { Write-Err 'downloads-guard: unlock needs an elevated PowerShell (Run as administrator).'; return 1 }
  $sid = Get-UserSid
  $left = New-Object System.Collections.ArrayList
  foreach ($t in (Get-Content -LiteralPath $lockedFile -Encoding UTF8)) {
    if (-not $t) { continue }
    if (-not (Test-Path -LiteralPath $t)) { continue }
    $ok = (Invoke-Icacls $t '/setowner' "*$sid" '/Q') -and (Invoke-Icacls $t '/reset' '/Q')
    if ($ok) { [Console]::Out.WriteLine("unlocked $t") } else { Write-Err "downloads-guard: could not unlock $t"; [void]$left.Add($t) }
  }
  if ($left.Count -gt 0) { Set-Content -LiteralPath $lockedFile -Value $left.ToArray() -Encoding UTF8; return 1 }
  Remove-Item -LiteralPath $lockedFile -Force
  return 0
}

# ------------------------------------------------------------------ main

$cmd = if ($args.Count -gt 0) { [string]$args[0] } else { 'status' }
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }

switch ($cmd) {
  'check' { exit (Invoke-Check ([string[]]$rest)) }
  'check-cwd' { exit (Invoke-CheckCwd $(if ($rest.Count) { [string]$rest[0] } else { '' })) }
  'hook' { exit (Invoke-Hook $(if ($rest.Count) { [string]$rest[0] } else { '' })) }
  'wrap-exec' {
    if ($rest.Count -eq 0) { Write-Err 'usage: downloads-guard.ps1 wrap-exec COMMAND [ARGS...]'; exit 2 }
    $rc = Invoke-CheckCwd ([IO.Path]::GetFileName([string]$rest[0]))
    if ($rc -ne 0) { exit $rc }
    $target = [string]$rest[0]
    $targs = @()
    if ($rest.Count -gt 1) { $targs = @($rest[1..($rest.Count - 1)]) }
    & $target @targs
    exit $LASTEXITCODE
  }
  'folders' { Invoke-Folders; exit 0 }
  'downloads-dirs' { foreach ($d in (Get-DGDownloadsFolders)) { [Console]::Out.WriteLine((ConvertTo-DGFullPath $d.Path)) }; exit 0 }
  'status' { exit (Invoke-Status) }
  'lock' { exit (Invoke-Lock) }
  'unlock' { exit (Invoke-Unlock) }
  { @('version', '--version') -contains $_ } { [Console]::Out.WriteLine((Get-DGVersion)); exit 0 }
  default {
    Write-Err 'usage: downloads-guard.ps1 status|folders|check|check-cwd|hook|wrap-exec|lock|unlock|version'
    exit 2
  }
}
