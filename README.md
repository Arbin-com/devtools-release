# devtools-release

Registry and installers for Arbin internal developer tools. The binaries live in private GitHub
releases of `Arbin-com/Others-develop`; this public repo holds only the index (which versions
exist, where each build is, its SHA-256) and the two installer scripts.

## Install

You need a GitHub token with read access to `Arbin-com/Others-develop`. The installer looks for
`GH_TOKEN`, then `GITHUB_TOKEN`, then `gh auth token`. It never prompts and never prints the token.
The token is sent only to `api.github.com` for the download, never to this index.

Linux and macOS (x64 and arm64):

```sh
curl -fsSL https://raw.githubusercontent.com/Arbin-com/devtools-release/main/install.sh | sh -s -- unit-sim
curl -fsSL https://raw.githubusercontent.com/Arbin-com/devtools-release/main/install.sh | sh -s -- unit-sim@0.1.0
```

Windows (x64), PowerShell 5.1 or 7:

```powershell
iwr -useb https://raw.githubusercontent.com/Arbin-com/devtools-release/main/install.ps1 -OutFile $env:TEMP\install.ps1
& $env:TEMP\install.ps1 unit-sim
& $env:TEMP\install.ps1 unit-sim@0.1.0
```

Without a temp file:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Arbin-com/devtools-release/main/install.ps1))) unit-sim
```

`tool` installs the latest version; `tool@version` installs that exact version, which is also how
you roll back. To update, rerun the same command. Flags: `--dir DIR` (`-Dir DIR` on Windows) sets the
install root, `--help` (`-Help`) prints usage.

## What it does

Per user, no sudo or admin rights. Root: `~/.arbin-tools` (Windows: `%USERPROFILE%\.arbin-tools`),
or `$ARBIN_TOOLS_HOME`, or `--dir`.

```text
<root>/<tool>/<version>/<tool>        the executable (<tool>.exe on Windows)
<root>/<tool>/current                 symlink to the active version (Windows: current.txt)
<root>/bin/<tool>                     symlink to current (Windows: <tool>.cmd shim)
```

- Downloads the archive, verifies its SHA-256 (`sha256sum`, `shasum -a 256`, or `Get-FileHash`), and
  stops on a mismatch or when the checksum tool is missing.
- Unpacks into a staging directory under the root and moves it into place, so a failed install
  never leaves a half version.
- Keeps the version you just installed plus the 2 most recently installed others; older ones are
  removed. The active version is never removed.
- Adds `<root>/bin` to PATH once: a line marked `# arbin-tools` in `~/.zshrc`, or in `~/.bashrc`
  (and `~/.profile` if it does not exist) for bash, or in `~/.profile` otherwise. On Windows it adds
  the directory to the User PATH if it is not already an entry. Open a new shell afterwards.
- Runs `<tool> version` and prints the result.

## Registry layout

Served raw from `https://raw.githubusercontent.com/Arbin-com/devtools-release/main`.

```text
install.sh  install.ps1  README.md
<tool>/latest                     one line: the highest published version
<tool>/<version>/manifest.json
```

`manifest.json`:

```json
{
  "tool": "unit-sim",
  "version": "0.1.0",
  "published": "2026-01-01T00:00:00Z",
  "platforms": {
    "linux-x64": {
      "github_owner": "Arbin-com",
      "github_repo": "Others-develop",
      "github_tag": "unit-sim@0.1.0",
      "github_asset": "unit-sim-0.1.0-linux-x64.tar.gz",
      "github_asset_api_url": "https://api.github.com/repos/Arbin-com/Others-develop/releases/assets/1001",
      "sha256": "<64 hex characters>"
    }
  }
}
```

Platforms: `win-x64`, `linux-x64`, `linux-arm64`, `osx-x64`, `osx-arm64`. Archives are `.tar.gz`
(Linux, macOS) or `.zip` (Windows) and contain exactly one top-level file named after the tool
(`unit-sim`, or `unit-sim.exe`). The installers are generic over the tool name. A complete example
registry is in `testdata/registry/`; the real tool directories are written by the release pipeline.

## Tests

The tests run the real scripts against `test/fake-server.mjs`, a dependency-free Node server that
plays both this registry and the GitHub asset API (it answers 401 unless
`Authorization: Bearer test-token`, and redirects the download to another host name to catch token
leaks). Everything runs under a temp HOME and a temp install root. The real PATH and profiles are
never touched.

```sh
# Linux, macOS, WSL (needs node, or FAKE_SERVER=http://host:port for a server started elsewhere)
sh test/run-unix.sh
```

```powershell
# Windows (needs node and the .NET Framework csc.exe); runs under pwsh and powershell.exe
pwsh -NoProfile -File test/run-windows.ps1
```

The scripts accept two test-only overrides, documented in their headers: `ARBIN_TOOLS_INDEX_URL`
and `ARBIN_TOOLS_API_BASE`. `ARBIN_TOOLS_SKIP_PATH=1` skips the PATH edit.
