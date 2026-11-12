<#
Tests for install.ps1 against test/fake-server.mjs (needs node and the .NET Framework csc.exe).

  pwsh -NoProfile -File test/run-windows.ps1                 # runs the installer under every PowerShell found
  pwsh -NoProfile -File test/run-windows.ps1 -Shells pwsh    # only PowerShell 7

Every install runs in a child process with a temp USERPROFILE, a temp ARBIN_TOOLS_HOME and
ARBIN_TOOLS_SKIP_PATH=1: the real User PATH, profile and ~/.arbin-tools are never touched.
The PATH-merge logic is tested on plain strings (no registry access).
#>
param(
  [string[]]$Shells = @('pwsh', 'powershell')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$install = (Resolve-Path (Join-Path $here '..\install.ps1')).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("arbin-wtest." + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

$script:pass = 0
$script:fail = 0
$script:why = @()

# ---- fake exe, one per version (the Windows archives need a real executable) ----
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }
$exeDir = Join-Path $work 'exes'
New-Item -ItemType Directory -Path $exeDir | Out-Null
foreach ($v in '0.1.0', '0.2.0', '0.3.0', '0.4.0', '0.9.0') {
  $src = Join-Path $exeDir "unit-sim-$v.cs"
  Set-Content -Path $src -Encoding ASCII -Value @"
using System;
class P { static int Main(string[] a) {
  if (a.Length > 0 && a[0] == "version") { Console.WriteLine("unit-sim $v"); return 0; }
  Console.Error.WriteLine("unit-sim: usage"); return 2; } }
"@
  $cscOut = & $csc /nologo "/out:$(Join-Path $exeDir "unit-sim-$v.exe")" $src
  if ($LASTEXITCODE -ne 0) { throw "csc failed for ${v}: $cscOut" }
}

# ---- fake server ----
$env:FAKE_WIN_EXE_DIR = $exeDir
$serverOut = Join-Path $work 'server.out'
$serverProc = Start-Process node -ArgumentList ('"' + (Join-Path $here 'fake-server.mjs') + '"') `
  -RedirectStandardOutput $serverOut -RedirectStandardError (Join-Path $work 'server.err') -PassThru -WindowStyle Hidden
for ($i = 0; $i -lt 50 -and -not ((Test-Path $serverOut) -and (Get-Content $serverOut -ErrorAction SilentlyContinue)); $i++) { Start-Sleep -Milliseconds 100 }
$port = (Get-Content $serverOut | ConvertFrom-Json).port
$server = "http://127.0.0.1:$port"

function Get-Stat([string]$Name) { (Invoke-RestMethod "$server/__stats").$Name }

# ---- helpers ----
function Invoke-Installer {
  param([string]$Shell, [hashtable]$Case, [string[]]$ArgList, [hashtable]$Env = @{})
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command $Shell).Source
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $install + '"'))
  foreach ($x in $ArgList) { $a += ('"' + $x + '"') }
  $psi.Arguments = $a -join ' '
  $e = $psi.EnvironmentVariables
  foreach ($k in 'GH_TOKEN', 'GITHUB_TOKEN') { if ($e.ContainsKey($k)) { $e.Remove($k) } }
  # a child 5.1 must not inherit the PowerShell 7 module path
  if ($e.ContainsKey('PSModulePath')) { $e.Remove('PSModulePath') }
  $e['USERPROFILE'] = $Case.Home
  $e['HOME'] = $Case.Home
  $e['TEMP'] = $Case.Tmp
  $e['TMP'] = $Case.Tmp
  $e['ARBIN_TOOLS_HOME'] = $Case.Root
  $e['ARBIN_TOOLS_INDEX_URL'] = $server
  $e['ARBIN_TOOLS_API_BASE'] = $server
  $e['ARBIN_TOOLS_SKIP_PATH'] = '1'
  $e['PATH'] = $Case.ShimDir + ';' + $e['PATH']
  if (-not $Case.NoToken) { $e['GH_TOKEN'] = $(if ($Case.Token) { $Case.Token } else { 'test-token' }) }
  foreach ($k in $Env.Keys) { $e[$k] = $Env[$k] }
  $p = [Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  $Case.Rc = $p.ExitCode
  $Case.Out = $outTask.Result
  $Case.Err = $errTask.Result
}

$script:n = 0
function New-Case([string]$Name, [string]$Shell) {
  $script:n++
  $t = Join-Path $work "case$($script:n)"
  $shim = Join-Path $t 'shim'
  New-Item -ItemType Directory -Path (Join-Path $t 'home'), (Join-Path $t 'tmp'), $shim | Out-Null
  # a gh that is not logged in, so the real gh on this machine is never consulted
  Set-Content -Path (Join-Path $shim 'gh.cmd') -Encoding ASCII -Value '@exit /b 1'
  Invoke-RestMethod "$server/__reset" | Out-Null
  $script:why = @()
  @{ Name = "$Name [$Shell]"; Shell = $Shell; Home = (Join-Path $t 'home'); Tmp = (Join-Path $t 'tmp'); Root = (Join-Path $t 'root'); ShimDir = $shim; T = $t }
}
function Check([bool]$Cond, [string]$Desc) { if (-not $Cond) { $script:why += $Desc } }
function Complete-Case($Case) {
  if ($script:why.Count -eq 0) {
    $script:pass++
    Write-Output "ok   - $($Case.Name)"
  } else {
    $script:fail++
    Write-Output "FAIL - $($Case.Name): $($script:why -join '; ')"
    if ($Case.Out) { Write-Output ("       out| " + $Case.Out.TrimEnd().Replace("`n", "`n       out| ")) }
    if ($Case.Err) { Write-Output ("       err| " + $Case.Err.TrimEnd().Replace("`n", "`n       err| ")) }
  }
}
function Get-Versions($Case) {
  $d = Join-Path $Case.Root 'unit-sim'
  if (-not (Test-Path $d)) { return '' }
  ((Get-ChildItem $d -Directory | Sort-Object Name | ForEach-Object Name) -join ' ')
}
function Get-Current($Case) { (Get-Content (Join-Path $Case.Root 'unit-sim\current.txt') -ErrorAction SilentlyContinue | Select-Object -First 1) }
function Test-NoLeftovers($Case) {
  -not (Get-ChildItem $Case.Tmp -Force) -and -not (Get-ChildItem $Case.Root -Force -Filter '.stage.*' -ErrorAction SilentlyContinue)
}
function Run-Shim($Case, [string]$Ver) {
  $cmd = Join-Path $Case.Root 'bin\unit-sim.cmd'
  if (-not (Test-Path $cmd)) { return "" }
  $o = & cmd /c "`"$cmd`" version"
  if ($o) { ([string]($o -join "")).Trim() } else { "" }
}

# ---- tests that run per PowerShell edition ----
foreach ($shell in $Shells) {
  if (-not (Get-Command $shell -ErrorAction SilentlyContinue)) {
    Write-Output "skip - $shell not found"
    continue
  }

  $c = New-Case 'fresh install of latest' $shell
  Invoke-Installer $shell $c @('unit-sim')
  Check ($c.Rc -eq 0) "exit $($c.Rc)"
  Check ($c.Out -match 'unit-sim 0\.4\.0') 'prints version line'
  Check ($c.Out -match 'To update, rerun this command\.') 'prints update hint'
  Check (Test-Path (Join-Path $c.Root 'unit-sim\0.4.0\unit-sim.exe')) 'exe in place'
  Check ((Get-Current $c) -eq '0.4.0') 'current.txt'
  $shimFile = Join-Path $c.Root 'bin\unit-sim.cmd'
  Check ((Test-Path $shimFile) -and (Get-Content $shimFile -Raw).TrimEnd() -ceq '@"%~dp0..\unit-sim\0.4.0\unit-sim.exe" %*') 'shim content'
  Check ((Run-Shim $c) -eq 'unit-sim 0.4.0') 'shim runs'
  Check ((Get-Stat indexAuthSeen) -eq 0) 'token never sent to the index'
  Check ((Get-Stat blobAuthSeen) -eq 0) 'token not forwarded to the redirect target'
  Check ((Get-Stat assetCalls) -eq 1) 'one asset call'
  Check (($c.Out + $c.Err) -notmatch 'test-token') 'token not printed'
  Check (Test-NoLeftovers $c) 'no staging or temp leftovers'
  Complete-Case $c

  $c = New-Case 'install a specific version' $shell
  Invoke-Installer $shell $c @('unit-sim@0.2.0')
  Check ($c.Rc -eq 0) "exit $($c.Rc)"
  Check ($c.Out -match 'unit-sim 0\.2\.0') 'prints 0.2.0'
  Check ((Get-Versions $c) -eq '0.2.0') 'only 0.2.0'
  Check ((Get-Current $c) -eq '0.2.0') 'current.txt'
  Complete-Case $c

  $c = New-Case 'upgrade then rollback' $shell
  Invoke-Installer $shell $c @('unit-sim@0.1.0')
  Invoke-Installer $shell $c @('unit-sim')
  Check ($c.Rc -eq 0) 'upgrade exit 0'
  Check ((Get-Current $c) -eq '0.4.0') 'current is 0.4.0'
  Invoke-Installer $shell $c @('unit-sim@0.1.0')
  Check ($c.Rc -eq 0) 'rollback exit 0'
  Check ((Get-Current $c) -eq '0.1.0') 'current is 0.1.0'
  Check ((Run-Shim $c) -eq 'unit-sim 0.1.0') 'shim follows rollback'
  Check ((Get-Versions $c) -eq '0.1.0 0.4.0') 'both versions kept'
  Invoke-Installer $shell $c @('unit-sim@0.1.0')
  Check ($c.Rc -eq 0) 'reinstall of the same version works'
  Check ((Get-Versions $c) -eq '0.1.0 0.4.0') 'still both versions'
  Check (Test-NoLeftovers $c) 'no leftovers'
  Complete-Case $c

  $c = New-Case 'prune keeps current and the 2 newest others' $shell
  foreach ($v in '0.1.0', '0.2.0', '0.3.0', '0.4.0') { Invoke-Installer $shell $c @("unit-sim@$v") }
  Check ($c.Rc -eq 0) 'last install exit 0'
  Check ((Get-Versions $c) -eq '0.2.0 0.3.0 0.4.0') '0.1.0 pruned'
  Invoke-Installer $shell $c @('unit-sim@0.2.0')
  Check ((Get-Current $c) -eq '0.2.0') 'rollback to oldest kept'
  Check ((Get-Versions $c) -eq '0.2.0 0.3.0 0.4.0') 'active version never pruned'
  Invoke-Installer $shell $c @('unit-sim@0.1.0')
  Check ((Get-Versions $c) -eq '0.1.0 0.2.0 0.4.0') 'current + 2 most recently installed'
  Complete-Case $c

  $c = New-Case 'wrong sha256 is rejected and leaves nothing' $shell
  Invoke-Installer $shell $c @('unit-sim@0.9.0')
  Check ($c.Rc -ne 0) 'non-zero exit'
  Check ($c.Err -match 'sha256 mismatch') 'mismatch message'
  Check (-not (Test-Path (Join-Path $c.Root 'unit-sim\0.9.0'))) 'no version dir'
  Check (-not (Test-Path (Join-Path $c.Root 'unit-sim\current.txt'))) 'no current.txt'
  Check (-not (Test-Path (Join-Path $c.Root 'bin\unit-sim.cmd'))) 'no shim'
  Check (Test-NoLeftovers $c) 'no staging or temp leftovers'
  Complete-Case $c

  $c = New-Case 'wrong sha256 keeps the previously installed version' $shell
  Invoke-Installer $shell $c @('unit-sim@0.1.0')
  Invoke-Installer $shell $c @('unit-sim@0.9.0')
  Check ($c.Rc -ne 0) 'non-zero exit'
  Check ((Get-Current $c) -eq '0.1.0') 'current still 0.1.0'
  Check ((Run-Shim $c) -eq 'unit-sim 0.1.0') 'shim still works'
  Complete-Case $c

  $c = New-Case 'missing token gives the exact one-line error' $shell
  $c.NoToken = $true
  Invoke-Installer $shell $c @('unit-sim')
  Check ($c.Rc -eq 1) "exit $($c.Rc)"
  Check ($c.Err.TrimEnd() -ceq 'Need a GitHub token with read access to Arbin-com/Others-develop: set GH_TOKEN, or run `gh auth login`.') "stderr was: $($c.Err)"
  Check ([string]::IsNullOrWhiteSpace($c.Out)) 'stdout empty'
  Check (@((Get-Stat log) | Where-Object { $_ -like 'GET /unit-sim*' }).Count -eq 0) 'no request was made'
  Check (-not (Test-Path (Join-Path $c.Root 'unit-sim'))) 'nothing installed'
  Complete-Case $c

  $c = New-Case 'token from gh auth token' $shell
  $c.NoToken = $true
  Set-Content -Path (Join-Path $c.ShimDir 'gh.cmd') -Encoding ASCII -Value '@echo test-token'
  Invoke-Installer $shell $c @('unit-sim@0.3.0')
  Check ($c.Rc -eq 0) "exit $($c.Rc)"
  Check ($c.Out -match 'unit-sim 0\.3\.0') 'installed 0.3.0'
  Complete-Case $c

  $c = New-Case 'GITHUB_TOKEN is used when GH_TOKEN is unset' $shell
  $c.NoToken = $true
  Invoke-Installer $shell $c @('unit-sim@0.3.0') @{ GITHUB_TOKEN = 'test-token' }
  Check ($c.Rc -eq 0) "exit $($c.Rc)"
  Complete-Case $c

  $c = New-Case 'rejected token fails with a hint and installs nothing' $shell
  $c.Token = 'wrong-token'
  Invoke-Installer $shell $c @('unit-sim')
  Check ($c.Rc -ne 0) 'non-zero exit'
  Check ($c.Err -match 'read access to Arbin-com/Others-develop') 'hint on stderr'
  Check ((Get-Stat unauthorized) -eq 1) 'asset endpoint answered 401'
  Check (-not (Test-Path (Join-Path $c.Root 'unit-sim\0.4.0'))) 'nothing installed'
  Check (Test-NoLeftovers $c) 'no leftovers'
  Complete-Case $c

  $c = New-Case 'argument handling' $shell
  Invoke-Installer $shell $c @('-Help')
  Check ($c.Rc -eq 0 -and $c.Out -match 'Usage: install\.ps1') '-Help prints usage'
  Invoke-Installer $shell $c @('--help')
  Check ($c.Rc -eq 0 -and $c.Out -match 'Usage: install\.ps1') '--help prints usage'
  Invoke-Installer $shell $c @()
  Check ($c.Rc -ne 0) 'no tool: non-zero'
  Invoke-Installer $shell $c @('..\evil')
  Check ($c.Rc -ne 0 -and $c.Err -match 'invalid tool name') 'path traversal in tool name rejected'
  Invoke-Installer $shell $c @('unit-sim@..\..\x')
  Check ($c.Rc -ne 0 -and $c.Err -match 'invalid version') 'bad version rejected'
  Invoke-Installer $shell $c @('unit-sim@9.9.9')
  Check ($c.Rc -ne 0 -and $c.Err -match 'no published unit-sim version 9\.9\.9') 'unpublished version fails'
  Invoke-Installer $shell $c @('--bogus', 'unit-sim')
  Check ($c.Rc -ne 0 -and $c.Err -match 'unknown option') 'unknown option fails'
  Complete-Case $c

  $c = New-Case '--dir and -Dir override the root' $shell
  $d1 = Join-Path $c.T 'custom1'
  $d2 = Join-Path $c.T 'custom2'
  Invoke-Installer $shell $c @('--dir', $d1, 'unit-sim@0.1.0')
  Check ($c.Rc -eq 0) "--dir exit $($c.Rc)"
  Check (Test-Path (Join-Path $d1 'unit-sim\0.1.0\unit-sim.exe')) 'installed under --dir'
  Invoke-Installer $shell $c @('unit-sim@0.1.0', '-Dir', $d2)
  Check ($c.Rc -eq 0) "-Dir exit $($c.Rc)"
  Check (Test-Path (Join-Path $d2 'unit-sim\0.1.0\unit-sim.exe')) 'installed under -Dir'
  Check (-not (Test-Path $c.Root)) 'ARBIN_TOOLS_HOME ignored'
  Complete-Case $c
}

# ---- PATH merge logic on plain strings (no registry access) ----
. $install
$c = @{ Name = 'Merge-PathEntry on plain strings'; Out = ''; Err = '' }
$script:why = @()
$bin = 'C:\Users\x\.arbin-tools\bin'
$r = Merge-PathEntry '' $bin
Check ($r.Changed -and $r.Value -ceq $bin) 'empty PATH gets just the entry'
$r = Merge-PathEntry $null $bin
Check ($r.Changed -and $r.Value -ceq $bin) 'null PATH gets just the entry'
$orig = 'C:\Windows;%USERPROFILE%\bin;C:\Tools\'
$r = Merge-PathEntry $orig $bin
Check ($r.Changed -and $r.Value -ceq "$orig;$bin") 'appends and keeps every original entry byte for byte (including %VAR%)'
$r = Merge-PathEntry "C:\Windows;$bin;C:\Tools" $bin
Check (-not $r.Changed -and $r.Value -ceq "C:\Windows;$bin;C:\Tools") 'exact entry already present: unchanged'
$r = Merge-PathEntry ('C:\Windows;' + $bin.ToUpper()) $bin
Check (-not $r.Changed) 'case-insensitive match'
$r = Merge-PathEntry "C:\Windows;$bin\" $bin
Check (-not $r.Changed) 'trailing backslash match'
$r = Merge-PathEntry "C:\Windows;${bin}2" $bin
Check ($r.Changed -and $r.Value -ceq "C:\Windows;${bin}2;$bin") 'a longer entry with the same prefix is not a match'
$r = Merge-PathEntry "C:\Windows;" $bin
Check ($r.Changed -and $r.Value -ceq "C:\Windows;$bin") 'trailing semicolon is not doubled'
$r1 = Merge-PathEntry 'C:\Windows' $bin
$r2 = Merge-PathEntry $r1.Value $bin
Check (-not $r2.Changed -and $r2.Value -ceq $r1.Value) 'second merge is a no-op (idempotent)'
Complete-Case $c

# ---- done ----
try { Stop-Process -Id $serverProc.Id -Force } catch {}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
