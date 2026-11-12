<#
Arbin developer tool installer (Windows, per user, no admin rights).

  iwr -useb https://raw.githubusercontent.com/Arbin-com/devtools-release/main/install.ps1 -OutFile $env:TEMP\install.ps1
  & $env:TEMP\install.ps1 unit-sim            # latest
  & $env:TEMP\install.ps1 unit-sim@0.1.0      # a specific version (also rollback)

One-liner without a temp file:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Arbin-com/devtools-release/main/install.ps1))) unit-sim

Usage: install.ps1 [-Dir DIR] <tool>[@version]
  -Dir DIR   install root (default: $env:ARBIN_TOOLS_HOME or %USERPROFILE%\.arbin-tools)
  -Help      show this help

Needs a GitHub token with read access to Arbin-com/Others-develop:
GH_TOKEN, then GITHUB_TOKEN, then `gh auth token`. No prompts.

Layout: <root>\<tool>\<version>\<tool>.exe, <root>\<tool>\current.txt (the active version),
        <root>\bin\<tool>.cmd (shim; <root>\bin is added to the User PATH)

Environment overrides for testing ONLY:
  ARBIN_TOOLS_INDEX_URL  registry base URL (default: the raw GitHub URL of this repo)
  ARBIN_TOOLS_API_BASE   replaces the leading https://api.github.com of every
                         github_asset_api_url in a manifest (default: https://api.github.com)
  ARBIN_TOOLS_SKIP_PATH  set to 1 to skip the User PATH edit
#>
param(
  [Parameter(Position = 0)][string]$Spec,
  [string]$Dir,
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'

$script:DefaultIndexUrl = 'https://raw.githubusercontent.com/Arbin-com/devtools-release/main'
$script:KeepOld = 2

function Fail([string]$Message) {
  throw "error: $Message"
}

function Show-Usage {
  Write-Output 'Usage: install.ps1 [-Dir DIR] <tool>[@version]'
  Write-Output '  -Dir DIR   install root (default: $env:ARBIN_TOOLS_HOME or %USERPROFILE%\.arbin-tools)'
  Write-Output '  -Help      show this help'
  Write-Output 'Needs GH_TOKEN, GITHUB_TOKEN or a logged-in gh (read access to Arbin-com/Others-develop).'
}

function Get-ArbinPlatform {
  if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Fail 'unsupported OS. This installer is for Windows (Linux and macOS: use install.sh)'
  }
  $arch = $env:PROCESSOR_ARCHITEW6432
  if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
  if ($arch -eq 'AMD64') { return 'win-x64' }
  Fail "unsupported CPU '$arch'. Supported: x64"
}

# Adds $Entry to a ';' separated PATH string unless an entry already equals it
# (case-insensitive, ignoring a trailing slash). Never drops or rewrites other entries.
function Merge-PathEntry([string]$PathValue, [string]$Entry) {
  $want = $Entry.Trim().TrimEnd('\', '/')
  if ($PathValue) {
    foreach ($e in $PathValue.Split(';')) {
      if ($e.Trim().TrimEnd('\', '/') -ieq $want) {
        return [pscustomobject]@{ Changed = $false; Value = $PathValue }
      }
    }
    return [pscustomobject]@{ Changed = $true; Value = ($PathValue.TrimEnd(';') + ';' + $Entry) }
  }
  return [pscustomobject]@{ Changed = $true; Value = $Entry }
}

# User PATH access. Read the raw registry value WITHOUT expanding %VAR% entries and write it
# back as REG_EXPAND_SZ, so existing entries such as %USERPROFILE%\bin survive byte for byte.
# Read-UserPathRaw and Write-UserPathRaw are the only code that touches the registry
# (the tests replace them).
function Read-UserPathRaw {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  if (-not $key) { return '' }
  try {
    return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  } finally {
    $key.Dispose()
  }
}

function Write-UserPathRaw([string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  try {
    $key.SetValue('Path', $Value, $Kind)
  } finally {
    $key.Dispose()
  }
  Send-EnvironmentChange
}

# Tell running programs (Explorer, new shells) that the environment changed.
function Send-EnvironmentChange {
  try {
    if (-not ('ArbinTools.NativeMethods' -as [type])) {
      Add-Type -Namespace ArbinTools -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    [void][ArbinTools.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
  } catch {
    # Fallback: setting and removing a throwaway variable makes .NET broadcast the change.
    $name = 'ARBIN_TOOLS_ENV_REFRESH'
    [Environment]::SetEnvironmentVariable($name, '1', 'User')
    [Environment]::SetEnvironmentVariable($name, $null, 'User')
  }
}

# Returns $true when the directory was added to the User PATH.
function Add-UserPathEntry([string]$Entry) {
  $merged = Merge-PathEntry (Read-UserPathRaw) $Entry
  if (-not $merged.Changed) { return $false }
  Write-UserPathRaw $merged.Value ([Microsoft.Win32.RegistryValueKind]::ExpandString)
  return $true
}

function Resolve-GitHubToken {
  $token = $env:GH_TOKEN
  if (-not $token) { $token = $env:GITHUB_TOKEN }
  if (-not $token -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $out = & gh auth token 2>$null
      if ($LASTEXITCODE -eq 0 -and $out) { $token = ([string]($out | Select-Object -First 1)).Trim() }
    } catch {
      $token = $null
    } finally {
      $ErrorActionPreference = $saved
    }
  }
  if (-not $token) {
    throw 'Need a GitHub token with read access to Arbin-com/Others-develop: set GH_TOKEN, or run `gh auth login`.'
  }
  if ($token -notmatch '^[A-Za-z0-9_.~+/=-]+$') {
    Fail 'the GitHub token contains unexpected characters'
  }
  return $token
}

$script:HttpClient = $null
function Get-HttpClient {
  if (-not $script:HttpClient) {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('arbin-tools-installer')
    $script:HttpClient = $client
  }
  return $script:HttpClient
}

# GET with manual redirects: the token is sent to the first URL only, never to the
# redirect target (GitHub redirects asset downloads to a signed storage URL).
function Invoke-HttpGet([string]$Url, [string]$Token) {
  $client = Get-HttpClient
  $current = $Url
  $useToken = [bool]$Token
  for ($i = 0; $i -le 5; $i++) {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $current)
    if ($useToken) {
      [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token")
      [void]$req.Headers.TryAddWithoutValidation('Accept', 'application/octet-stream')
      [void]$req.Headers.TryAddWithoutValidation('X-GitHub-Api-Version', '2022-11-28')
    }
    try {
      $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    } catch {
      $detail = $_.Exception.Message
      if ($_.Exception.InnerException) { $detail = $_.Exception.InnerException.Message }
      Fail "request to $current failed: $detail"
    }
    $code = [int]$resp.StatusCode
    if ($code -ge 300 -and $code -lt 400 -and $resp.Headers.Location) {
      $next = $resp.Headers.Location
      if (-not $next.IsAbsoluteUri) { $next = [Uri]::new([Uri]$current, $next) }
      $resp.Dispose()
      $current = $next.AbsoluteUri
      $useToken = $false
      continue
    }
    return $resp
  }
  Fail "too many redirects for $Url"
}

function Get-HttpText([string]$Url) {
  $resp = Invoke-HttpGet $Url ''
  try {
    if (-not $resp.IsSuccessStatusCode) { Fail "could not fetch $Url (HTTP $([int]$resp.StatusCode))" }
    return $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult().TrimStart([char]0xFEFF)
  } finally {
    $resp.Dispose()
  }
}

function Save-GitHubAsset([string]$Url, [string]$Token, [string]$OutFile) {
  $resp = Invoke-HttpGet $Url $Token
  try {
    if (-not $resp.IsSuccessStatusCode) {
      Fail "download failed (HTTP $([int]$resp.StatusCode)). Check that your token has read access to Arbin-com/Others-develop (SSO-authorized if required)"
    }
    $total = $resp.Content.Headers.ContentLength
    $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $fs = [IO.File]::Create($OutFile)
    try {
      $buf = New-Object byte[] 81920
      $done = [long]0
      $clock = [Diagnostics.Stopwatch]::StartNew()
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $fs.Write($buf, 0, $n)
        $done += $n
        if ($clock.ElapsedMilliseconds -ge 250) {
          $clock.Restart()
          $status = '{0:N1} MB' -f ($done / 1MB)
          if ($total) {
            Write-Progress -Activity 'Downloading' -Status $status -PercentComplete ([int](100 * $done / $total))
          } else {
            Write-Progress -Activity 'Downloading' -Status $status
          }
        }
      }
    } finally {
      $fs.Dispose()
      $in.Dispose()
      Write-Progress -Activity 'Downloading' -Completed
    }
  } finally {
    $resp.Dispose()
  }
}

# Versions to keep: $Current plus the newest $KeepOld others, newest first by install history.
function Get-KeptVersions([string]$ToolDir, [string]$Current) {
  $keep = New-Object System.Collections.Generic.List[string]
  $keep.Add($Current)
  $histFile = Join-Path $ToolDir '.history'
  $hist = @()
  if (Test-Path -LiteralPath $histFile) {
    $hist = @(Get-Content -LiteralPath $histFile | Where-Object { $_ })
  }
  [array]::Reverse($hist)
  $extra = 0
  foreach ($v in $hist) {
    if ($extra -ge $script:KeepOld) { break }
    if ($keep -contains $v) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $ToolDir $v) -PathType Container)) { continue }
    $keep.Add($v)
    $extra++
  }
  return , $keep.ToArray()
}

function Remove-OldVersions([string]$ToolDir, [string]$Current) {
  $keep = Get-KeptVersions $ToolDir $Current
  foreach ($d in Get-ChildItem -LiteralPath $ToolDir -Directory) {
    if ($keep -contains $d.Name) { continue }
    try {
      Remove-Item -LiteralPath $d.FullName -Recurse -Force
    } catch {
      [Console]::Error.WriteLine("warning: could not remove old version $($d.Name): $($_.Exception.Message)")
    }
  }
  $ordered = @($keep)
  [array]::Reverse($ordered)
  [IO.File]::WriteAllText((Join-Path $ToolDir '.history'), (($ordered -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-ArbinInstall([string[]]$CliArgs, [string]$DirParam, [bool]$HelpParam) {
  $rootArg = $DirParam
  $specText = ''
  $wantHelp = $HelpParam
  $i = 0
  while ($i -lt $CliArgs.Count) {
    $a = $CliArgs[$i]
    if ($a -in @('--help', '-h', '-help', '/?')) { $wantHelp = $true }
    elseif ($a -in @('--dir', '-dir')) {
      if ($i + 1 -ge $CliArgs.Count) { Fail '--dir needs a value' }
      $rootArg = $CliArgs[$i + 1]
      $i++
    }
    elseif ($a -like '--dir=*') { $rootArg = $a.Substring(6) }
    elseif ($a -like '-*') { Fail "unknown option: $a (try -Help)" }
    else {
      if ($specText) { Fail "only one tool can be installed at a time (got '$specText' and '$a')" }
      $specText = $a
    }
    $i++
  }
  if ($wantHelp) { Show-Usage; return }
  if (-not $specText) { Fail 'missing tool name. Usage: install.ps1 [-Dir DIR] <tool>[@version]' }

  $tool = $specText
  $reqVersion = ''
  $at = $specText.IndexOf('@')
  if ($at -ge 0) {
    $tool = $specText.Substring(0, $at)
    $reqVersion = $specText.Substring($at + 1)
    if ($reqVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') { Fail "invalid version: '$reqVersion'" }
  }
  if ($tool -notmatch '^[a-z0-9][a-z0-9._-]*$') { Fail "invalid tool name: '$tool'" }

  $platform = Get-ArbinPlatform
  $indexUrl = $env:ARBIN_TOOLS_INDEX_URL
  if (-not $indexUrl) { $indexUrl = $script:DefaultIndexUrl }
  $indexUrl = $indexUrl.TrimEnd('/')
  $apiBase = $env:ARBIN_TOOLS_API_BASE
  if (-not $apiBase) { $apiBase = 'https://api.github.com' }
  $apiBase = $apiBase.TrimEnd('/')

  $token = Resolve-GitHubToken

  if ($reqVersion) {
    $version = $reqVersion
  } else {
    $version = (Get-HttpText "$indexUrl/$tool/latest").Trim()
    if ($version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') { Fail "unexpected content in $indexUrl/$tool/latest" }
  }

  $manifestUrl = "$indexUrl/$tool/$version/manifest.json"
  try {
    $manifest = (Get-HttpText $manifestUrl) | ConvertFrom-Json
  } catch {
    Fail "no published $tool version $version ($manifestUrl)"
  }
  if ($manifest.tool -ne $tool) { Fail "manifest is for '$($manifest.tool)', expected '$tool'" }
  if ($manifest.version -ne $version) { Fail "manifest is for version '$($manifest.version)', expected '$version'" }
  $entry = $manifest.platforms.$platform
  if (-not $entry) { Fail "$tool $version has no build for $platform" }
  $assetUrl = [string]$entry.github_asset_api_url
  $sha256 = ([string]$entry.sha256).ToLowerInvariant()
  if (-not $assetUrl.StartsWith('https://api.github.com/')) { Fail "manifest has an unexpected github_asset_api_url for $platform" }
  $assetUrl = $apiBase + $assetUrl.Substring('https://api.github.com'.Length)
  if ($sha256 -notmatch '^[0-9a-f]{64}$') { Fail "manifest has an invalid sha256 for $platform" }

  if ($rootArg) { $root = $rootArg }
  elseif ($env:ARBIN_TOOLS_HOME) { $root = $env:ARBIN_TOOLS_HOME }
  else { $root = Join-Path $env:USERPROFILE '.arbin-tools' }
  $root = [IO.Path]::GetFullPath($root)
  $toolDir = Join-Path $root $tool
  $binDir = Join-Path $root 'bin'
  New-Item -ItemType Directory -Force -Path $binDir, $toolDir | Out-Null

  $stage = Join-Path $root (".stage." + [Guid]::NewGuid().ToString('N'))
  $tmpDl = Join-Path ([IO.Path]::GetTempPath()) ("arbin-tools." + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage, $tmpDl | Out-Null
  try {
    $archive = Join-Path $tmpDl 'asset.zip'
    Write-Output "Installing $tool $version ($platform)"
    Save-GitHubAsset $assetUrl $token $archive

    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($actual -ne $sha256) {
      Remove-Item -LiteralPath $archive -Force
      Fail "sha256 mismatch for $tool $version $platform (expected $sha256, got $actual); nothing was installed"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $exeName = "$tool.exe"
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
      if ($zip.Entries.Count -ne 1 -or $zip.Entries[0].FullName -cne $exeName) {
        Fail "unexpected archive content (expected only '$exeName')"
      }
    } finally {
      $zip.Dispose()
    }
    $newDir = Join-Path $stage 'new'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $newDir)
    if (-not (Test-Path -LiteralPath (Join-Path $newDir $exeName) -PathType Leaf)) { Fail "archive did not contain '$exeName'" }

    $dest = Join-Path $toolDir $version
    $oldDir = Join-Path $stage 'old'
    $hadOld = Test-Path -LiteralPath $dest
    try {
      if ($hadOld) { [IO.Directory]::Move($dest, $oldDir) }
      [IO.Directory]::Move($newDir, $dest)
    } catch {
      if ($hadOld -and -not (Test-Path -LiteralPath $dest) -and (Test-Path -LiteralPath $oldDir)) {
        [IO.Directory]::Move($oldDir, $dest)
      }
      Fail "cannot move $tool $version into place (is it running?): $($_.Exception.Message)"
    }

    $utf8 = New-Object Text.UTF8Encoding($false)
    $histFile = Join-Path $toolDir '.history'
    [IO.File]::AppendAllText($histFile, "$version`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $toolDir 'current.txt'), "$version`n", $utf8)
    $shim = '@"%~dp0..\{0}\{1}\{0}.exe" %*' -f $tool, $version
    [IO.File]::WriteAllText((Join-Path $binDir "$tool.cmd"), ($shim + "`r`n"), (New-Object Text.ASCIIEncoding))

    Remove-OldVersions $toolDir $version
  } finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpDl -Recurse -Force -ErrorAction SilentlyContinue
  }

  $pathNote = ''
  if ($env:ARBIN_TOOLS_SKIP_PATH -ne '1') {
    if (Add-UserPathEntry $binDir) {
      $pathNote = "Added $binDir to your User PATH; open a new terminal to pick it up."
    }
    $proc = Merge-PathEntry $env:Path $binDir
    if ($proc.Changed) { $env:Path = $proc.Value }
  }

  $exe = Join-Path (Join-Path $toolDir $version) "$tool.exe"
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $exe version 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $saved
  }
  if ($code -ne 0) { Fail "$tool was installed to $exe but '$tool version' failed: $out" }
  Write-Output ([string]($out -join "`n"))
  Write-Output "Installed $tool $version to $(Join-Path $toolDir $version)"
  if ($pathNote) { Write-Output $pathNote }
  Write-Output 'To update, rerun this command.'
}

# Dot-sourcing (the PATH-merge unit test) only loads the functions.
if ($MyInvocation.InvocationName -ne '.') {
  $all = @()
  if ($Spec) { $all += $Spec }
  if ($Rest) { $all += $Rest }
  try {
    Invoke-ArbinInstall $all $Dir ([bool]$Help)
    $global:LASTEXITCODE = 0
  } catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $global:LASTEXITCODE = 1
    if ($PSCommandPath) { exit 1 }
  }
}
