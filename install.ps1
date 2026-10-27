# install.ps1: install, update or remove downloads-guard on Windows.
#
#   .\install.ps1               install for the current user (no admin needed)
#   .\install.ps1 --system      also install the admin tier (run from an elevated PowerShell)
#   .\install.ps1 --dry-run     print every change and write nothing
#   .\install.ps1 --uninstall   remove exactly what was installed
#
# Running it again updates an existing install in place. -DryRun, -Uninstall and -System
# work too. Works in Windows PowerShell 5.1 and PowerShell 7.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$DryRun = $false
$Uninstall = $false
$SystemTier = $false
$ProfilePaths = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $args.Count; $i++) {
  $a = [string]$args[$i]
  switch -regex ($a) {
    '^(--dry-run|-dryrun)$' { $DryRun = $true; continue }
    '^(--uninstall|-uninstall)$' { $Uninstall = $true; continue }
    '^(--system|-system)$' { $SystemTier = $true; continue }
    '^(--profile-path|-profilepath)$' { $i++; [void]$ProfilePaths.Add([string]$args[$i]); continue }
    '^(-h|--help|-help|/\?)$' { Get-Content -LiteralPath $PSCommandPath | Select-Object -Skip 1 -First 9 | ForEach-Object { $_ -replace '^# ?', '' }; exit 0 }
    default { [Console]::Error.WriteLine("install.ps1: unknown option $a"); exit 2 }
  }
}

function Say([string]$Text) { [Console]::Out.WriteLine($Text) }
function Warn([string]$Text) { [Console]::Error.WriteLine("warning: $Text") }
function Die([string]$Text) { [Console]::Error.WriteLine("install.ps1: $Text"); exit 1 }

if ($env:OS -ne 'Windows_NT') { Die 'install.ps1 is for Windows; use install.sh on macOS and Linux' }
if ([string]::IsNullOrEmpty($env:USERPROFILE)) { Die 'USERPROFILE is not set' }

$Src = $PSScriptRoot
$UserHome = $env:USERPROFILE
$DGHome = Join-Path $UserHome '.downloads-guard'
$State = Join-Path $DGHome 'state'
$Manifest = Join-Path $State 'manifest.tsv'
$Backups = Join-Path $DGHome 'backups'
$Cli = Join-Path (Join-Path $DGHome 'bin') 'downloads-guard.ps1'
$MarkBegin = '# >>> downloads-guard >>>'
$MarkEnd = '# <<< downloads-guard <<<'
$Utf8 = New-Object Text.UTF8Encoding($false)

$SysPrefix = $env:DG_SYSTEM_PREFIX
function Join-Sys([string]$Base, [string]$Rel) {
  if ($SysPrefix) { return Join-Path $SysPrefix $Rel }
  return Join-Path $Base ($Rel -replace '^[^\\]+\\', '')
}
$ProgramFilesDir = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
$ProgramDataDir = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
$SysGuard = Join-Sys $ProgramFilesDir 'Program Files\downloads-guard'
$ClaudeDropin = Join-Sys $ProgramFilesDir 'Program Files\ClaudeCode\managed-settings.d\50-downloads-guard.json'
$OpenCodeManaged = Join-Sys $ProgramDataDir 'ProgramData\opencode\opencode.json'

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $UserHome '.claude' }
$CodexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $UserHome '.codex' }
$CursorDir = Join-Path $UserHome '.cursor'
$CursorCli = if ($env:CURSOR_CONFIG_DIR) { Join-Path $env:CURSOR_CONFIG_DIR 'cli-config.json' } else { Join-Path $CursorDir 'cli-config.json' }
$OpenCodeDir = if ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'opencode' } else { Join-Path (Join-Path $UserHome '.config') 'opencode' }
$PiDir = if ($env:PI_CODING_AGENT_DIR) { $env:PI_CODING_AGENT_DIR } else { Join-Path (Join-Path $UserHome '.pi') 'agent' }

if ($ProfilePaths.Count -eq 0) {
  $docs = [Environment]::GetFolderPath('MyDocuments')
  [void]$ProfilePaths.Add((Join-Path (Join-Path $docs 'PowerShell') 'profile.ps1'))
  [void]$ProfilePaths.Add((Join-Path (Join-Path $docs 'WindowsPowerShell') 'profile.ps1'))
}

function Has([string]$Name) { [bool](Get-Command -Name $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue) }
function Want-Claude { (Test-Path -LiteralPath $ClaudeDir) -or (Has 'claude') }
function Want-Codex { (Test-Path -LiteralPath $CodexDir) -or (Has 'codex') }
function Want-Cursor { (Test-Path -LiteralPath $CursorDir) -or (Has 'agent') -or (Has 'cursor-agent') -or (Has 'cursor') }
function Want-OpenCode { (Test-Path -LiteralPath $OpenCodeDir) -or (Has 'opencode') }
function Want-Pi { (Test-Path -LiteralPath $PiDir) -or (Has 'pi') }

function Test-Elevated {
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------------ file helpers

function Write-TextAtomic([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  $tmp = "$Path.dg-tmp.$PID"
  [IO.File]::WriteAllText($tmp, $Text, $Utf8)
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-FileChange([string]$Path, [string]$Text) {
  if ($DryRun) {
    Say "would write ${Path}:"
    foreach ($l in ($Text -split "`r?`n")) { Say "    | $l" }
    return
  }
  Write-TextAtomic $Path $Text
}

function Copy-FileChange([string]$From, [string]$To) {
  if ($DryRun) { Say "would copy $From -> $To"; return }
  Write-TextAtomic $To ([IO.File]::ReadAllText($From, $Utf8))
}

function Remove-FileChange([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if ($DryRun) { Say "would remove $Path"; return }
  Remove-Item -LiteralPath $Path -Force -Recurse
}

function Add-Record([string]$Kind, [string]$Name, [string]$Path, [string]$Extra = '') {
  if ($DryRun) { return }
  if (-not (Test-Path -LiteralPath $State)) { [void](New-Item -ItemType Directory -Path $State -Force) }
  [IO.File]::AppendAllText($Manifest, "$Kind`t$Name`t$Path`t$Extra`n", $Utf8)
}

# Record the folders that writing Path will create, outermost first, so that
# --uninstall can remove them again (only if they are empty by then).
function Add-DirRecords([string]$Path, [string]$Kind = 'dir', [switch]$Self) {
  $d = if ($Self) { $Path } else { Split-Path -Parent $Path }
  $missing = New-Object System.Collections.ArrayList
  while ($d -and -not (Test-Path -LiteralPath $d)) {
    $missing.Insert(0, $d)
    $d = Split-Path -Parent $d
  }
  foreach ($m in $missing) { Add-Record $Kind 'dir' $m }
}

function Render-Template([string]$From, [string]$Root) {
  $text = [IO.File]::ReadAllText($From, $Utf8)
  $escaped = $Root.Replace('\', '\\').Replace('"', '\"')
  return $text.Replace('__DG_ROOT__', $escaped)
}

# ------------------------------------------------------------------ JSON engine
# The same rules as lib/jsonmerge.py: every change is recorded so that --uninstall
# removes exactly what was added and puts back the original bytes when it can.

function ConvertTo-DGData($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    $o = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertTo-DGData $p.Value }
    return , $o
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $o = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($k in @($Value.Keys)) { $o[[string]$k] = ConvertTo-DGData $Value[$k] }
    return , $o
  }
  if (($Value -is [System.Collections.IList]) -and -not ($Value -is [string])) {
    $l = New-Object System.Collections.ArrayList
    foreach ($x in $Value) { [void]$l.Add((ConvertTo-DGData $x)) }
    return , $l
  }
  return $Value
}

function Read-JsonText([string]$Text, [string]$What) {
  if ($Text.Trim() -eq '') { return , (New-Object System.Collections.Specialized.OrderedDictionary) }
  try {
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
      $parsed = $Text | ConvertFrom-Json -DateKind String  # PowerShell 7.5+: keep date-like strings as text
    } else {
      $parsed = $Text | ConvertFrom-Json
    }
  } catch { throw "$What is not valid JSON ($($_.Exception.Message)); not touching it" }
  $data = ConvertTo-DGData $parsed
  if (-not ($data -is [System.Collections.Specialized.OrderedDictionary])) { throw "$What does not hold a JSON object; not touching it" }
  return , $data
}

function ConvertTo-JsonText($Data) {
  return (ConvertTo-Json -InputObject $Data -Depth 100) + "`n"
}

function Test-DGEqual($A, $B) {
  if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
  $ad = $A -is [System.Collections.IDictionary]; $bd = $B -is [System.Collections.IDictionary]
  if ($ad -or $bd) {
    if (-not ($ad -and $bd)) { return $false }
    if ($A.Count -ne $B.Count) { return $false }
    foreach ($k in @($A.Keys)) {
      if (-not $B.Contains($k)) { return $false }
      if (-not (Test-DGEqual $A[$k] $B[$k])) { return $false }
    }
    return $true
  }
  $al = ($A -is [System.Collections.IList]) -and -not ($A -is [string])
  $bl = ($B -is [System.Collections.IList]) -and -not ($B -is [string])
  if ($al -or $bl) {
    if (-not ($al -and $bl)) { return $false }
    if ($A.Count -ne $B.Count) { return $false }
    for ($i = 0; $i -lt $A.Count; $i++) { if (-not (Test-DGEqual $A[$i] $B[$i])) { return $false } }
    return $true
  }
  if (($A -is [bool]) -ne ($B -is [bool])) { return $false }
  if (($A -is [string]) -or ($B -is [string])) { return ($A -is [string]) -and ($B -is [string]) -and ($A -ceq $B) }
  return ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $A) -eq
    [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $B))
}

function Get-JPath($Doc, [string[]]$Path) {
  $cur = $Doc
  foreach ($k in $Path) {
    if (-not ($cur -is [System.Collections.IDictionary]) -or -not $cur.Contains($k)) { return @{ Had = $false; Value = $null } }
    $cur = $cur[$k]
  }
  return @{ Had = $true; Value = $cur }
}

function Set-JPath($Doc, [string[]]$Path, $Value) {
  $cur = $Doc
  for ($i = 0; $i -lt $Path.Count - 1; $i++) { $cur = $cur[$Path[$i]] }
  $cur[$Path[$Path.Count - 1]] = $Value
}

function Remove-JPath($Doc, [string[]]$Path) {
  $cur = $Doc
  for ($i = 0; $i -lt $Path.Count - 1; $i++) {
    if (-not ($cur -is [System.Collections.IDictionary]) -or -not $cur.Contains($Path[$i])) { return }
    $cur = $cur[$Path[$i]]
  }
  if ($cur -is [System.Collections.IDictionary]) { $cur.Remove($Path[$Path.Count - 1]) }
}

function New-DGRecord([string]$File, [string]$ProfileName, [bool]$CreatedFile, $OriginalText) {
  $r = New-Object System.Collections.Specialized.OrderedDictionary
  $r['version'] = 1; $r['file'] = $File; $r['profile'] = $ProfileName
  $r['created_file'] = $CreatedFile; $r['original_text'] = $OriginalText
  foreach ($k in 'created_paths', 'hook_paths', 'array_added', 'scalars', 'defaults', 'map_entries', 'converted') {
    $r[$k] = New-Object System.Collections.ArrayList
  }
  return , $r
}

function Get-Container($Doc, [string[]]$Path, [string]$Kind, $Rec) {
  $cur = $Doc
  for ($i = 0; $i -lt $Path.Count; $i++) {
    $k = $Path[$i]
    $last = ($i -eq $Path.Count - 1)
    $wantList = $last -and $Kind -eq 'list'
    if (-not ($cur -is [System.Collections.IDictionary])) { throw "expected an object at $($Path[0..$i] -join '.')" }
    if (-not $cur.Contains($k)) {
      if ($wantList) { $cur[$k] = New-Object System.Collections.ArrayList } else { $cur[$k] = New-Object System.Collections.Specialized.OrderedDictionary }
      [void]$Rec['created_paths'].Add([string[]]$Path[0..$i])
    } else {
      $v = $cur[$k]
      $isList = ($v -is [System.Collections.IList]) -and -not ($v -is [string])
      $isDict = $v -is [System.Collections.IDictionary]
      if (($wantList -and -not $isList) -or (-not $wantList -and -not $isDict)) {
        throw "$($Path[0..$i] -join '.') has an unexpected type; not touching it"
      }
    }
    $cur = $cur[$k]
  }
  return , $cur
}

function Test-HasMarker($Value) {
  return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress).Contains('downloads-guard')
}

function Remove-MarkedHooks($List) {
  $out = New-Object System.Collections.ArrayList
  foreach ($e in $List) {
    if (($e -is [System.Collections.IDictionary]) -and $e.Contains('hooks') -and ($e['hooks'] -is [System.Collections.IList])) {
      $kept = New-Object System.Collections.ArrayList
      foreach ($h in $e['hooks']) { if (-not (Test-HasMarker $h)) { [void]$kept.Add($h) } }
      if ($kept.Count -ne $e['hooks'].Count) {
        if ($kept.Count -eq 0) { continue }
        $e['hooks'] = $kept
      }
      [void]$out.Add($e)
    } elseif (Test-HasMarker $e) {
      continue
    } else {
      [void]$out.Add($e)
    }
  }
  $List.Clear()
  foreach ($e in $out) { [void]$List.Add($e) }
}

function Invoke-Op($Doc, $Rec, $Op) {
  switch ($Op.Kind) {
    'hook' {
      $l = Get-Container $Doc $Op.Path 'list' $Rec
      Remove-MarkedHooks $l
      [void]$l.Add($Op.Value)
      [void]$Rec['hook_paths'].Add($Op.Path)
    }
    'array_add' {
      $l = Get-Container $Doc $Op.Path 'list' $Rec
      foreach ($v in $Op.Value) {
        $present = $false
        foreach ($x in $l) { if (Test-DGEqual $x $v) { $present = $true } }
        if (-not $present) {
          [void]$l.Add($v)
          $item = New-Object System.Collections.Specialized.OrderedDictionary
          $item['path'] = $Op.Path; $item['value'] = $v
          [void]$Rec['array_added'].Add($item)
        }
      }
    }
    'set' {
      if ($Op.Path.Count -gt 1) { [void](Get-Container $Doc $Op.Path[0..($Op.Path.Count - 2)] 'dict' $Rec) }
      $g = Get-JPath $Doc $Op.Path
      $item = New-Object System.Collections.Specialized.OrderedDictionary
      $item['path'] = $Op.Path; $item['had'] = $g.Had; $item['old'] = $g.Value; $item['new'] = $Op.Value
      [void]$Rec['scalars'].Add($item)
      Set-JPath $Doc $Op.Path $Op.Value
    }
    'set_default' {
      if ($Op.Path.Count -gt 1) { [void](Get-Container $Doc $Op.Path[0..($Op.Path.Count - 2)] 'dict' $Rec) }
      $g = Get-JPath $Doc $Op.Path
      if (-not $g.Had) {
        Set-JPath $Doc $Op.Path (ConvertTo-DGData $Op.Value)
        $item = New-Object System.Collections.Specialized.OrderedDictionary
        $item['path'] = $Op.Path; $item['value'] = $Op.Value
        [void]$Rec['defaults'].Add($item)
      }
    }
    'map_set' {
      for ($d = 1; $d -le $Op.Path.Count; $d++) {
        $sub = [string[]]$Op.Path[0..($d - 1)]
        $g = Get-JPath $Doc $sub
        if ($g.Had -and ($g.Value -is [string])) {
          $o = New-Object System.Collections.Specialized.OrderedDictionary
          $o['*'] = $g.Value
          Set-JPath $Doc $sub $o
          $item = New-Object System.Collections.Specialized.OrderedDictionary
          $item['path'] = $sub; $item['old'] = $g.Value
          [void]$Rec['converted'].Add($item)
        }
      }
      $obj = Get-Container $Doc $Op.Path 'dict' $Rec
      $had = $obj.Contains($Op.Key)
      $old = if ($had) { $obj[$Op.Key] } else { $null }
      if ($had -and (Test-DGEqual $old $Op.Value)) { return }
      if ($had) { $obj.Remove($Op.Key) }  # re-insert so it sorts after "*": OpenCode uses the last match
      $obj[$Op.Key] = $Op.Value
      $item = New-Object System.Collections.Specialized.OrderedDictionary
      $item['path'] = $Op.Path; $item['key'] = $Op.Key; $item['had'] = $had; $item['old'] = $old; $item['new'] = $Op.Value
      [void]$Rec['map_entries'].Add($item)
    }
  }
}

function Undo-Record($Doc, $Rec) {
  foreach ($p in $Rec['hook_paths']) {
    $g = Get-JPath $Doc ([string[]]$p)
    if ($g.Had -and ($g.Value -is [System.Collections.IList])) { Remove-MarkedHooks $g.Value }
  }
  foreach ($it in $Rec['array_added']) {
    $g = Get-JPath $Doc ([string[]]$it['path'])
    if ($g.Had -and ($g.Value -is [System.Collections.IList])) {
      for ($i = $g.Value.Count - 1; $i -ge 0; $i--) { if (Test-DGEqual $g.Value[$i] $it['value']) { $g.Value.RemoveAt($i) } }
    }
  }
  $items = @($Rec['map_entries']); [array]::Reverse($items)
  foreach ($it in $items) {
    $g = Get-JPath $Doc ([string[]]$it['path'])
    if ($g.Had -and ($g.Value -is [System.Collections.IDictionary]) -and $g.Value.Contains($it['key']) -and (Test-DGEqual $g.Value[$it['key']] $it['new'])) {
      if ($it['had']) { $g.Value[$it['key']] = $it['old'] } else { $g.Value.Remove($it['key']) }
    }
  }
  $items = @($Rec['scalars']); [array]::Reverse($items)
  foreach ($it in $items) {
    $g = Get-JPath $Doc ([string[]]$it['path'])
    if ($g.Had -and (Test-DGEqual $g.Value $it['new'])) {
      if ($it['had']) { Set-JPath $Doc ([string[]]$it['path']) $it['old'] } else { Remove-JPath $Doc ([string[]]$it['path']) }
    }
  }
  $items = @($Rec['defaults']); [array]::Reverse($items)
  foreach ($it in $items) {
    $g = Get-JPath $Doc ([string[]]$it['path'])
    if ($g.Had -and (Test-DGEqual $g.Value (ConvertTo-DGData $it['value']))) { Remove-JPath $Doc ([string[]]$it['path']) }
  }
  $paths = @($Rec['created_paths'] | Sort-Object -Property @{ Expression = { @($_).Count } } -Descending)
  foreach ($p in $paths) {
    $g = Get-JPath $Doc ([string[]]$p)
    if ($g.Had -and ($g.Value -is [System.Collections.ICollection]) -and -not ($g.Value -is [string]) -and $g.Value.Count -eq 0) {
      Remove-JPath $Doc ([string[]]$p)
    }
  }
  $items = @($Rec['converted']); [array]::Reverse($items)
  foreach ($it in $items) {
    $g = Get-JPath $Doc ([string[]]$it['path'])
    if ($g.Had -and ($g.Value -is [System.Collections.IDictionary]) -and $g.Value.Count -eq 1 -and $g.Value.Contains('*') -and (Test-DGEqual $g.Value['*'] $it['old'])) {
      Set-JPath $Doc ([string[]]$it['path']) $it['old']
    }
  }
}

function Read-Record([string]$StatePath) {
  $rec = Read-JsonText ([IO.File]::ReadAllText($StatePath, $Utf8)) $StatePath
  # JSON arrays of strings come back as lists; paths are used as string arrays.
  return , $rec
}

function Save-Backup([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (-not (Test-Path -LiteralPath $Backups)) { [void](New-Item -ItemType Directory -Path $Backups -Force) }
  $name = ($Path.TrimStart('\') -replace '[:\\/]', '_') + '.orig'
  $dest = Join-Path $Backups $name
  if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $Path -Destination $dest }
}

function Invoke-JsonApply([string]$File, [string]$StatePath, [string]$ProfileName, $Ops) {
  $exists = Test-Path -LiteralPath $File
  $origText = if ($exists) { [IO.File]::ReadAllText($File, $Utf8) } else { $null }
  $doc = if ($exists) { Read-JsonText $origText $File } else { New-Object System.Collections.Specialized.OrderedDictionary }
  $before = ConvertTo-DGData $doc
  $createdFile = -not $exists
  if (Test-Path -LiteralPath $StatePath) {
    $prev = Read-Record $StatePath
    Undo-Record $doc $prev
    $createdFile = [bool]$prev['created_file'] -or $createdFile
    $origText = $prev['original_text']
  }
  $rec = New-DGRecord $File $ProfileName $createdFile $origText
  foreach ($op in $Ops) { Invoke-Op $doc $rec $op }
  if ($DryRun) {
    Say "would update ${File}:"
    Say (ConvertTo-JsonText $doc).TrimEnd()
    return
  }
  if (-not $exists -or -not (Test-DGEqual $before $doc)) {
    Save-Backup $File
    Write-TextAtomic $File (ConvertTo-JsonText $doc)
  }
  Write-TextAtomic $StatePath (ConvertTo-JsonText $rec)
}

function Invoke-JsonRevert([string]$StatePath) {
  if (-not (Test-Path -LiteralPath $StatePath)) { return }
  $rec = Read-Record $StatePath
  $file = [string]$rec['file']
  if (-not (Test-Path -LiteralPath $file)) {
    if ($DryRun) { Say "would remove state $StatePath ($file is gone)" } else { Remove-Item -LiteralPath $StatePath -Force }
    return
  }
  $doc = Read-JsonText ([IO.File]::ReadAllText($file, $Utf8)) $file
  $before = ConvertTo-DGData $doc
  Undo-Record $doc $rec
  $removeFile = [bool]$rec['created_file'] -and $doc.Count -eq 0
  if ($DryRun) {
    if ($removeFile) { Say "would remove $file (created by downloads-guard, now empty)" }
    elseif (-not (Test-DGEqual $before $doc)) { Say "would update ${file}:"; Say (ConvertTo-JsonText $doc).TrimEnd() }
    return
  }
  if ($removeFile) {
    Remove-Item -LiteralPath $file -Force
  } elseif (-not (Test-DGEqual $before $doc)) {
    $orig = $rec['original_text']
    $same = $false
    if ($orig -is [string]) { try { $same = Test-DGEqual (Read-JsonText $orig 'original') $doc } catch { $same = $false } }
    if ($same) { Write-TextAtomic $file $orig } else { Write-TextAtomic $file (ConvertTo-JsonText $doc) }
  }
  Remove-Item -LiteralPath $StatePath -Force
}

function New-Op([string]$Kind, [string[]]$Path, $Value, [string]$Key = $null) {
  return [pscustomobject]@{ Kind = $Kind; Path = $Path; Value = $Value; Key = $Key }
}

function New-Dict([object[]]$Pairs) {
  $o = New-Object System.Collections.Specialized.OrderedDictionary
  for ($i = 0; $i -lt $Pairs.Count; $i += 2) { $o[[string]$Pairs[$i]] = $Pairs[$i + 1] }
  return , $o
}

function New-List([object[]]$Items) {
  $l = New-Object System.Collections.ArrayList
  foreach ($x in $Items) { [void]$l.Add($x) }
  return , $l
}

# ------------------------------------------------------------------ harness settings

function Get-ClaudeHandler([string]$CliPath) {
  $argsList = New-List @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $CliPath, 'hook', 'claude')
  return , (New-Dict @('type', 'command', 'command', 'powershell.exe', 'args', $argsList, 'timeout', 30, 'onFailure', 'block'))
}

function Get-ClaudeDenies {
  $list = @('Edit(~/.claude.json)')
  if ($ClaudeDir -eq (Join-Path $UserHome '.claude')) { $list += 'Edit(~/.claude/settings*.json)' }
  else { $list += ('Edit(//' + ($ClaudeDir -replace '\\', '/').TrimStart('/') + '/settings*.json)') }
  $list += 'Edit(**/.claude/settings*.json)', 'Edit(**/.mcp.json)', 'Edit(~/.downloads-guard/**)'
  return $list
}

function Get-ClaudeOps([string]$CliPath) {
  $h = Get-ClaudeHandler $CliPath
  $prompt = New-Dict @('hooks', (New-List @($h)))
  $tool = New-Dict @('matcher', '*', 'hooks', (New-List @((Get-ClaudeHandler $CliPath))))
  return @(
    (New-Op 'hook' @('hooks', 'UserPromptSubmit') $prompt),
    (New-Op 'hook' @('hooks', 'PreToolUse') $tool),
    (New-Op 'array_add' @('permissions', 'deny') (Get-ClaudeDenies)),
    (New-Op 'set' @('permissions', 'disableBypassPermissionsMode') 'disable')
  )
}

# A command line that works whether the harness runs it through cmd, PowerShell or Git Bash.
function Get-HookCommandLine([string]$Harness, [switch]$PowerShellQuoting) {
  $p = $Cli -replace '\\', '/'
  if ($PowerShellQuoting) { $q = "'" + $p.Replace("'", "''") + "'" } else { $q = '"' + $p + '"' }
  return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $q hook $Harness"
}

function Get-TildePath([string]$Path) {
  $h = $UserHome.TrimEnd('\')
  if ($Path.StartsWith($h + '\', [StringComparison]::OrdinalIgnoreCase)) { return '~/' + ($Path.Substring($h.Length + 1) -replace '\\', '/') }
  return ($Path -replace '\\', '/')
}

function Install-Json([string]$Name, [string]$File, $Ops) {
  $statePath = Join-Path $State "json-$Name.json"
  Add-DirRecords $File
  try {
    Invoke-JsonApply $File $statePath $Name $Ops
    Add-Record 'json' $Name $File $statePath
  } catch {
    Warn "skipped $File ($($_.Exception.Message)); downloads-guard did not change it"
  }
}

# ------------------------------------------------------------------ profiles

function Read-TextKeepBom([string]$File) {
  $bytes = [IO.File]::ReadAllBytes($File)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $start = if ($bom) { 3 } else { 0 }
  return @{ Bom = $bom; Text = $Utf8.GetString($bytes, $start, $bytes.Length - $start) }
}

function Write-TextKeepBom([string]$File, [string]$Text, [bool]$Bom) {
  $enc = New-Object Text.UTF8Encoding($Bom)
  [IO.File]::WriteAllText($File, $Text, $enc)
}

function Remove-ProfileBlock([string]$File, [bool]$Created) {
  if (-not (Test-Path -LiteralPath $File)) { return }
  $r = Read-TextKeepBom $File
  if (-not $r.Text.Contains($MarkBegin)) { return }
  if ($DryRun) { Say "would remove the downloads-guard block from $File"; return }
  $pattern = '(?ms)^' + [regex]::Escape($MarkBegin) + '\r?\n.*?^' + [regex]::Escape($MarkEnd) + '(\r?\n|\z)'
  $new = [regex]::Replace($r.Text, $pattern, '')
  if ($Created -and $new.Trim() -eq '') { Remove-Item -LiteralPath $File -Force }
  else { Write-TextKeepBom $File $new $r.Bom }
}

function Add-ProfileBlock([string]$File) {
  $created = -not (Test-Path -LiteralPath $File)
  Remove-ProfileBlock $File $false
  $rootLiteral = "'" + $DGHome.Replace("'", "''") + "'"
  $body = @(
    $MarkBegin,
    '# Added by downloads-guard. Remove with: & "$env:USERPROFILE\.downloads-guard\install.ps1" --uninstall',
    "`$global:DGRoot = $rootLiteral",
    'if (Test-Path -LiteralPath (Join-Path $global:DGRoot ''shell\guard.ps1'')) { . (Join-Path $global:DGRoot ''shell\guard.ps1'') }',
    $MarkEnd
  ) -join "`r`n"
  if ($DryRun) {
    Say "would add to ${File}:"
    foreach ($l in ($body -split "`r`n")) { Say "    | $l" }
  } else {
    $dir = Split-Path -Parent $File
    Add-DirRecords $File
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $r = if (Test-Path -LiteralPath $File) { Read-TextKeepBom $File } else { @{ Bom = $false; Text = '' } }
    $sep = if ($r.Text.Length -gt 0 -and -not $r.Text.EndsWith("`n")) { "`r`n" } else { '' }
    Write-TextKeepBom $File ($r.Text + $sep + $body + "`r`n") $r.Bom
  }
  Add-Record 'profile' 'powershell' $File $(if ($created) { 'yes' } else { 'no' })
}

# ------------------------------------------------------------------ layer 3 decoys

$SquatNames = @('AGENTS.md', 'CLAUDE.md', 'CLAUDE.local.md', 'AGENTS.override.md', 'opencode.json')

function Test-OurSquat([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $text = [IO.File]::ReadAllText($Path)
  if ($Path.EndsWith('opencode.json', [StringComparison]::OrdinalIgnoreCase)) {
    return ($text -eq [IO.File]::ReadAllText((Join-Path (Join-Path $Src 'templates') 'opencode.json')))
  }
  return $text.Contains('downloads-guard:squat')
}

function Set-ReadOnly([string]$Path, [bool]$On) {
  if ($DryRun) { Say "would set read-only=$On on $Path"; return }
  $item = Get-Item -LiteralPath $Path -Force
  if ($On) { $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly }
  else { $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) }
}

function Install-Squats {
  Import-Module (Join-Path (Join-Path $Src 'lib') 'DownloadsGuard.psm1') -Force -DisableNameChecking
  $dirs = @(Get-DGDownloadsFolders | ForEach-Object { ConvertTo-DGFullPath $_.Path })
  $any = $false
  foreach ($d in $dirs) {
    if (-not $d) { continue }
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { Say "skip: $d does not exist, so no decoy files there"; continue }
    $any = $true
    foreach ($n in $SquatNames) {
      $p = Join-Path $d $n
      $tpl = if ($n -eq 'opencode.json') { Join-Path (Join-Path $Src 'templates') 'opencode.json' } else { Join-Path (Join-Path $Src 'templates') 'squat.md' }
      if ((Test-Path -LiteralPath $p) -and -not (Test-OurSquat $p)) {
        Warn "$p already exists and was not made by downloads-guard. Look at it (it may be the kind of file this tool guards against), delete it, and run the installer again."
        Add-Record 'squat-foreign' $n $p
        continue
      }
      if (Test-Path -LiteralPath $p) { Set-ReadOnly $p $false }
      Copy-FileChange $tpl $p
      Set-ReadOnly $p $true
      Add-Record 'squat' $n $p 'same-user'
    }
  }
  if (-not $any) { Warn 'no Downloads folder exists yet, so no decoy files were placed' }
}

# ------------------------------------------------------------------ uninstall

function Invoke-UninstallFromManifest {
  if (-not (Test-Path -LiteralPath $Manifest)) { return }
  $lockedFile = Join-Path $State 'locked.txt'
  if ((Test-Path -LiteralPath $lockedFile) -and ((Get-Content -LiteralPath $lockedFile | Where-Object { $_ }) )) {
    Say 'Removing the system file locks first (needs an elevated PowerShell).'
    if ($DryRun) { Get-Content -LiteralPath $lockedFile | ForEach-Object { Say "would unlock: $_" } }
    else {
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Cli unlock
      if ($LASTEXITCODE -ne 0) { Die "could not remove the system locks; run 'downloads-guard unlock' as administrator and try again" }
    }
  }
  $lines = @(Get-Content -LiteralPath $Manifest -Encoding UTF8)
  [array]::Reverse($lines)
  foreach ($line in $lines) {
    $parts = $line.Split("`t")
    if ($parts.Count -lt 3) { continue }
    $kind = $parts[0]; $path = $parts[2]
    $extra = if ($parts.Count -gt 3) { $parts[3] } else { '' }
    switch ($kind) {
      'profile' { Remove-ProfileBlock $path ($extra -eq 'yes') }
      'json' { Invoke-JsonRevert $extra }
      'file' { Remove-FileChange $path }
      'dir' {
        if ((Test-Path -LiteralPath $path -PathType Container) -and -not (Get-ChildItem -LiteralPath $path -Force)) {
          if ($DryRun) { Say "would remove empty folder $path" } else { Remove-Item -LiteralPath $path -Force }
        }
      }
      'squat' {
        if (Test-OurSquat $path) { Set-ReadOnly $path $false; Remove-FileChange $path }
      }
      'sysjson' { Invoke-JsonRevert $extra }
      'sysfile' { Remove-FileChange $path }
      'sysdir' {
        if ($path.EndsWith('\downloads-guard')) { Remove-FileChange $path } else { Warn "not removing unexpected system folder $path" }
      }
      'sysemptydir' {
        if ((Test-Path -LiteralPath $path -PathType Container) -and -not (Get-ChildItem -LiteralPath $path -Force)) {
          if ($DryRun) { Say "would remove empty folder $path" } else { Remove-Item -LiteralPath $path -Force }
        }
      }
    }
  }
}

function Invoke-UninstallAll([bool]$KeepConfig) {
  Invoke-UninstallFromManifest
  if (Test-Path -LiteralPath $DGHome) {
    if ($KeepConfig) {
      foreach ($x in (Get-ChildItem -LiteralPath $DGHome -Force)) {
        if (@('config', 'backups') -contains $x.Name) { continue }
        Remove-FileChange $x.FullName
      }
    } else {
      Remove-FileChange $DGHome
    }
  }
}

if ($Uninstall) {
  if (-not (Test-Path -LiteralPath $DGHome)) { Say "downloads-guard is not installed (no $DGHome)."; exit 0 }
  # Run from a copy outside the install folder, which is about to be deleted.
  Invoke-UninstallAll $false
  if ($DryRun) { Say 'Dry run: nothing was changed.' } else { Say 'downloads-guard removed. Open a new PowerShell window so the wrappers are gone.' }
  exit 0
}

# ------------------------------------------------------------------ install

if ((Resolve-Path -LiteralPath $Src).ProviderPath.TrimEnd('\') -ieq $DGHome.TrimEnd('\')) {
  Die "run install.ps1 from the downloads-guard source folder, not from $DGHome (that copy is only for --uninstall)"
}
if ($SystemTier -and -not (Test-Elevated)) { Die '--system needs an elevated PowerShell (Run as administrator)' }

if (Test-Path -LiteralPath $Manifest) {
  $lockedFile = Join-Path $State 'locked.txt'
  if ((Test-Path -LiteralPath $lockedFile) -and (Get-Content -LiteralPath $lockedFile | Where-Object { $_ }) -and -not $SystemTier) {
    Die "the system file locks are on. Run 'downloads-guard unlock' as administrator, or re-run with --system"
  }
  Say 'Updating the existing install.'
  Invoke-UninstallAll $true
}

Say "Installing downloads-guard for $env:USERNAME into $DGHome"

foreach ($f in @('bin\downloads-guard.ps1', 'bin\claude-process-wrapper.cmd', 'lib\DownloadsGuard.psm1', 'shell\guard.ps1',
    'templates\squat.md', 'templates\opencode.json', 'install.ps1')) {
  Copy-FileChange (Join-Path $Src $f) (Join-Path $DGHome $f)
}
if (-not (Test-Path -LiteralPath (Join-Path $DGHome 'config'))) {
  Write-FileChange (Join-Path $DGHome 'config') (@(
      '# downloads-guard: extra folders to protect, one absolute path per line.',
      '# Your Downloads folder is always protected; it does not need to be listed.',
      '# A path that is your home folder (or a whole drive) is ignored.',
      '# Example:',
      '# ~\Desktop\unsorted'
    ) -join "`r`n")
}
if (-not $DryRun -and (Get-Command Unblock-File -ErrorAction SilentlyContinue)) {
  # Files from a downloaded zip carry the internet zone mark, which RemoteSigned refuses.
  Get-ChildItem -LiteralPath $DGHome -Recurse -File | Unblock-File
}

# Layer 1: PowerShell wrappers.
foreach ($p in $ProfilePaths) { Add-ProfileBlock $p }
$policy = [string](Get-ExecutionPolicy)
if (@('Restricted', 'AllSigned') -contains $policy) {
  Warn "the PowerShell execution policy is $policy, so profiles do not run and the wrappers stay inactive. To fix: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}

# Layers 1 and 2: native hooks and deny rules.
if (Want-Claude) {
  Say "Claude Code: hooks and deny rules in $ClaudeDir\settings.json"
  Install-Json 'claude' (Join-Path $ClaudeDir 'settings.json') (Get-ClaudeOps $Cli)
}
if (Want-Codex) {
  Say "Codex: UserPromptSubmit hook in $CodexDir\hooks.json"
  $h = New-Dict @('type', 'command', 'command', (Get-HookCommandLine 'codex'), 'timeout', 30)
  Install-Json 'codex' (Join-Path $CodexDir 'hooks.json') @((New-Op 'hook' @('hooks', 'UserPromptSubmit') (New-Dict @('hooks', (New-List @($h))))))
  Say '  Codex runs a new hook only after you trust it: start codex, open /hooks and trust the downloads-guard hook.'
}
if (Want-Cursor) {
  Say "Cursor: beforeSubmitPrompt hook in $CursorDir\hooks.json, Write denies in $CursorCli"
  # Cursor runs hook commands through PowerShell on Windows, so quote for PowerShell.
  $h = New-Dict @('command', (Get-HookCommandLine 'cursor' -PowerShellQuoting), 'failClosed', $true, 'timeout', 30)
  Install-Json 'cursor-hooks' (Join-Path $CursorDir 'hooks.json') @(
    (New-Op 'set_default' @('version') 1),
    (New-Op 'hook' @('hooks', 'beforeSubmitPrompt') $h))
  $fwd = { param($p) $p -replace '\\', '/' }
  Install-Json 'cursor-cli' $CursorCli @(
    (New-Op 'set_default' @('version') 1),
    (New-Op 'set_default' @('editor') (New-Dict @('vimMode', $false))),
    (New-Op 'set_default' @('permissions', 'allow') (New-List @())),
    (New-Op 'array_add' @('permissions', 'deny') @(
        "Write($(& $fwd $CursorCli))", "Write($(& $fwd (Join-Path $CursorDir 'hooks.json')))",
        "Write($(& $fwd (Join-Path $CursorDir 'mcp.json')))", "Write($(& $fwd $DGHome)/**)")))
}
if (Want-OpenCode) {
  $plugin = Join-Path (Join-Path $OpenCodeDir 'plugins') 'downloads-guard.js'
  Say "OpenCode: plugin in $OpenCodeDir\plugins, edit denies in $OpenCodeDir\opencode.json"
  Add-DirRecords $plugin
  Write-FileChange $plugin (Render-Template (Join-Path $Src 'integrations\opencode\downloads-guard.js') $DGHome)
  Add-Record 'file' 'opencode-plugin' $plugin
  $ocJson = Join-Path $OpenCodeDir 'opencode.json'
  $patterns = @("$(Get-TildePath $OpenCodeDir)/*", '~/.downloads-guard/*')
  if ((Test-Path -LiteralPath (Join-Path $OpenCodeDir 'opencode.jsonc')) -and -not (Test-Path -LiteralPath $ocJson)) {
    Warn "$OpenCodeDir\opencode.jsonc has comments that downloads-guard cannot keep; add by hand: `"permission`": {`"edit`": {`"$($patterns[0])`": `"deny`", `"$($patterns[1])`": `"deny`"}}"
  } else {
    Install-Json 'opencode' $ocJson @($patterns | ForEach-Object { New-Op 'map_set' @('permission', 'edit') 'deny' $_ })
  }
}
if (Want-Pi) {
  $ext = Join-Path (Join-Path $PiDir 'extensions') 'downloads-guard.ts'
  Say "Pi: extension in $PiDir\extensions"
  Add-DirRecords $ext
  Write-FileChange $ext (Render-Template (Join-Path $Src 'integrations\pi\downloads-guard.ts') $DGHome)
  Add-Record 'file' 'pi-extension' $ext
}

# Layer 3: decoy instruction files in Downloads.
Install-Squats

# ------------------------------------------------------------------ --system (admin tier)

if ($SystemTier) {
  Say "System tier: admin-owned copy in $SysGuard"
  Add-DirRecords $SysGuard 'sysemptydir'
  foreach ($f in @('bin\downloads-guard.ps1', 'bin\claude-process-wrapper.cmd', 'lib\DownloadsGuard.psm1')) {
    Copy-FileChange (Join-Path $Src $f) (Join-Path $SysGuard $f)
  }
  Add-Record 'sysdir' 'system-guard' $SysGuard
  $sysCli = Join-Path (Join-Path $SysGuard 'bin') 'downloads-guard.ps1'
  if (Want-Claude) {
    Say "Claude Code managed settings: $ClaudeDropin"
    $doc = New-Dict @(
      'hooks', (New-Dict @(
          'UserPromptSubmit', (New-List @((New-Dict @('hooks', (New-List @((Get-ClaudeHandler $sysCli))))))),
          'PreToolUse', (New-List @((New-Dict @('matcher', '*', 'hooks', (New-List @((Get-ClaudeHandler $sysCli))))))))),
      'permissions', (New-Dict @('deny', (New-List (Get-ClaudeDenies)), 'disableBypassPermissionsMode', 'disable')))
    Add-DirRecords $ClaudeDropin 'sysemptydir'
    Write-FileChange $ClaudeDropin (ConvertTo-JsonText $doc)
    Add-Record 'sysfile' 'claude-managed' $ClaudeDropin
  }
  if (Want-OpenCode) {
    Say "OpenCode managed config: $OpenCodeManaged"
    $statePath = Join-Path $State 'opencode-managed.json'
    Add-DirRecords $OpenCodeManaged 'sysemptydir'
    try {
      Invoke-JsonApply $OpenCodeManaged $statePath 'opencode-managed' @(
        @("$(Get-TildePath $OpenCodeDir)/*", '~/.downloads-guard/*') | ForEach-Object { New-Op 'map_set' @('permission', 'edit') 'deny' $_ })
      Add-Record 'sysjson' 'opencode-managed' $OpenCodeManaged $statePath
    } catch { Warn "could not update the OpenCode managed config ($($_.Exception.Message))" }
  }

  # Admin-owned ACLs on the user's agent configs, the guard's own files and the decoys.
  $targets = New-Object System.Collections.ArrayList
  foreach ($t in @((Join-Path $ClaudeDir 'settings.json'), (Join-Path $CodexDir 'hooks.json'), (Join-Path $CodexDir 'config.toml'),
      (Join-Path $CursorDir 'hooks.json'), $CursorCli, (Join-Path $CursorDir 'mcp.json'),
      (Join-Path $OpenCodeDir 'opencode.json'), (Join-Path (Join-Path $OpenCodeDir 'plugins') 'downloads-guard.js'),
      (Join-Path (Join-Path $PiDir 'extensions') 'downloads-guard.ts'), (Join-Path $PiDir 'models.json'), (Join-Path $PiDir 'mcp.json'),
      (Join-Path $DGHome 'config'), (Join-Path $DGHome 'install.ps1'))) {
    if (Test-Path -LiteralPath $t -PathType Leaf) { [void]$targets.Add($t) }
  }
  foreach ($sub in @('bin', 'lib', 'shell', 'templates')) {
    $dir = Join-Path $DGHome $sub
    if (Test-Path -LiteralPath $dir) { foreach ($f in (Get-ChildItem -LiteralPath $dir -File)) { [void]$targets.Add($f.FullName) } }
  }
  if (Test-Path -LiteralPath $Manifest) {
    foreach ($line in (Get-Content -LiteralPath $Manifest -Encoding UTF8)) {
      $parts = $line.Split("`t")
      if ($parts[0] -eq 'squat') { [void]$targets.Add($parts[2]) }
    }
  }
  if ($DryRun) {
    foreach ($t in $targets) { Say "would lock (admin-owned ACL): $t" }
    Say 'would run: downloads-guard lock'
  } else {
    [IO.File]::WriteAllText((Join-Path $State 'lock-targets.txt'), (($targets.ToArray() -join "`r`n") + "`r`n"), $Utf8)
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Cli lock
    if ($LASTEXITCODE -ne 0) { Warn 'some files could not be locked (see above)' }
  }
}

if ($DryRun) {
  Say 'Dry run: nothing was changed.'
} else {
  Say ''
  Say 'Done. Open a new PowerShell window so the wrappers load.'
  Say 'Check it with: downloads-guard status'
}
