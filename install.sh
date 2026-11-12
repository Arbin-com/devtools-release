#!/bin/sh
# Arbin developer tool installer (Linux and macOS).
#
#   curl -fsSL https://raw.githubusercontent.com/Arbin-com/devtools-release/main/install.sh | sh -s -- unit-sim
#   curl -fsSL https://raw.githubusercontent.com/Arbin-com/devtools-release/main/install.sh | sh -s -- unit-sim@0.1.0
#
# Usage: install.sh [--dir DIR] <tool>[@version]
#   --dir DIR   install root (default: $ARBIN_TOOLS_HOME or ~/.arbin-tools)
#   --help      show this help
#
# Needs a GitHub token with read access to Arbin-com/Others-develop:
# GH_TOKEN, then GITHUB_TOKEN, then `gh auth token`. No prompts.
#
# Layout: <root>/<tool>/<version>/<tool>, <root>/<tool>/current -> <version>,
#         <root>/bin/<tool> -> ../<tool>/current/<tool>
#
# Environment overrides for testing ONLY:
#   ARBIN_TOOLS_INDEX_URL  registry base URL (default: the raw GitHub URL of this repo)
#   ARBIN_TOOLS_API_BASE   replaces the leading https://api.github.com of every
#                          github_asset_api_url in a manifest (default: https://api.github.com)
#   ARBIN_TOOLS_SKIP_PATH  set to 1 to skip the shell profile edit
set -eu

DEFAULT_INDEX_URL="https://raw.githubusercontent.com/Arbin-com/devtools-release/main"
INDEX_URL="${ARBIN_TOOLS_INDEX_URL:-$DEFAULT_INDEX_URL}"
INDEX_URL="${INDEX_URL%/}"
API_BASE="${ARBIN_TOOLS_API_BASE:-https://api.github.com}"
API_BASE="${API_BASE%/}"
KEEP_OLD=2

TMP_DL=""
STAGE=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$TMP_DL" ] && [ -d "$TMP_DL" ]; then rm -rf "$TMP_DL"; fi
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# ---- arguments ---------------------------------------------------------

ROOT_ARG=""
SPEC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      printf '%s\n' "Usage: install.sh [--dir DIR] <tool>[@version]"
      printf '%s\n' "  --dir DIR   install root (default: \$ARBIN_TOOLS_HOME or ~/.arbin-tools)"
      printf '%s\n' "  --help      show this help"
      printf '%s\n' "Needs GH_TOKEN, GITHUB_TOKEN or a logged-in gh (read access to Arbin-com/Others-develop)."
      exit 0
      ;;
    --dir)
      [ $# -ge 2 ] || die "--dir needs a value"
      ROOT_ARG="$2"
      shift 2
      ;;
    --dir=*)
      ROOT_ARG="${1#--dir=}"
      shift
      ;;
    --)
      shift
      ;;
    -*)
      die "unknown option: $1 (try --help)"
      ;;
    *)
      [ -z "$SPEC" ] || die "only one tool can be installed at a time (got '$SPEC' and '$1')"
      SPEC="$1"
      shift
      ;;
  esac
done

[ -n "$SPEC" ] || die "missing tool name. Usage: install.sh [--dir DIR] <tool>[@version]"

TOOL="${SPEC%%@*}"
REQ_VERSION=""
case "$SPEC" in
  *@*) REQ_VERSION="${SPEC#*@}" ;;
esac

case "$TOOL" in
  ""|*[!a-z0-9._-]*|[!a-z0-9]*) die "invalid tool name: '$TOOL'" ;;
esac
if [ "${SPEC#*@}" != "$SPEC" ]; then
  case "$REQ_VERSION" in
    ""|*[!0-9A-Za-z._+-]*|[!0-9A-Za-z]*) die "invalid version: '$REQ_VERSION'" ;;
  esac
fi

# ---- platform ----------------------------------------------------------

case "$(uname -s)" in
  Linux) OS="linux" ;;
  Darwin) OS="osx" ;;
  *) die "unsupported OS '$(uname -s)'. Supported: Linux, macOS (Windows: use install.ps1)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "unsupported CPU '$(uname -m)'. Supported: x86_64, arm64" ;;
esac
PLATFORM="$OS-$ARCH"

# ---- prerequisites -----------------------------------------------------

command -v curl >/dev/null 2>&1 || die "curl is required but not installed"
command -v tar >/dev/null 2>&1 || die "tar is required but not installed"
command -v mktemp >/dev/null 2>&1 || die "mktemp is required but not installed"
if [ "$OS" = "osx" ]; then
  command -v shasum >/dev/null 2>&1 || die "shasum is required but not installed (it ships with perl; install Xcode command line tools)"
else
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required but not installed (install coreutils)"
fi

sha256_of() {
  if [ "$OS" = "osx" ]; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

# ---- token (never printed, never sent to the public index) --------------

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -z "$TOKEN" ]; then
  printf '%s\n' 'Need a GitHub token with read access to Arbin-com/Others-develop: set GH_TOKEN, or run `gh auth login`.' >&2
  exit 1
fi
case "$TOKEN" in
  *[!A-Za-z0-9_.~+/=-]*) die "the GitHub token contains unexpected characters" ;;
esac

# ---- helpers: registry and asset download ------------------------------

fetch_text() {
  curl -fsSL "$1" || die "could not fetch $1"
}

# json_field <flattened json> <field>: first string value of "field".
json_field() {
  printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

download_asset() {
  # The token goes through a curl config on stdin so it never shows in the process list.
  if [ -t 2 ]; then progress="--progress-bar"; else progress="-sS"; fi
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/octet-stream"\nheader = "X-GitHub-Api-Version: 2022-11-28"\n' "$TOKEN" |
    curl -fL "$progress" -K - -o "$2" "$1"
}

# ---- resolve version and manifest --------------------------------------

if [ -n "$REQ_VERSION" ]; then
  VERSION="$REQ_VERSION"
else
  VERSION="$(fetch_text "$INDEX_URL/$TOOL/latest" | tr -d '[:space:]')"
  case "$VERSION" in
    ""|*[!0-9A-Za-z._+-]*|[!0-9A-Za-z]*) die "unexpected content in $INDEX_URL/$TOOL/latest" ;;
  esac
fi

MANIFEST_URL="$INDEX_URL/$TOOL/$VERSION/manifest.json"
MANIFEST="$(curl -fsSL "$MANIFEST_URL")" || die "no published $TOOL version $VERSION ($MANIFEST_URL)"
MANIFEST="$(printf '%s' "$MANIFEST" | tr -d '\r\n')"

M_TOOL="$(json_field "$MANIFEST" tool | head -n 1)"
M_VERSION="$(json_field "$MANIFEST" version | head -n 1)"
[ "$M_TOOL" = "$TOOL" ] || die "manifest is for '$M_TOOL', expected '$TOOL'"
[ "$M_VERSION" = "$VERSION" ] || die "manifest is for version '$M_VERSION', expected '$VERSION'"

ENTRY="$(printf '%s' "$MANIFEST" | sed -n 's/.*"'"$PLATFORM"'"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p')"
[ -n "$ENTRY" ] || die "$TOOL $VERSION has no build for $PLATFORM"

ASSET_URL="$(json_field "$ENTRY" github_asset_api_url)"
SHA256="$(json_field "$ENTRY" sha256 | tr 'A-F' 'a-f')"
case "$ASSET_URL" in
  https://api.github.com/*) ASSET_URL="$API_BASE${ASSET_URL#https://api.github.com}" ;;
  *) die "manifest has an unexpected github_asset_api_url for $PLATFORM" ;;
esac
case "$SHA256" in
  *[!0-9a-f]*|"") die "manifest has an invalid sha256 for $PLATFORM" ;;
esac
[ "${#SHA256}" -eq 64 ] || die "manifest has an invalid sha256 for $PLATFORM"

# ---- install root ------------------------------------------------------

if [ -n "$ROOT_ARG" ]; then
  ROOT="$ROOT_ARG"
elif [ -n "${ARBIN_TOOLS_HOME:-}" ]; then
  ROOT="$ARBIN_TOOLS_HOME"
else
  [ -n "${HOME:-}" ] || die "HOME is not set; use --dir"
  ROOT="$HOME/.arbin-tools"
fi
case "$ROOT" in
  /*) ;;
  *) ROOT="$(pwd)/$ROOT" ;;
esac
TOOL_DIR="$ROOT/$TOOL"
mkdir -p "$ROOT/bin" "$TOOL_DIR" || die "cannot create $ROOT"

# ---- download, verify, extract -----------------------------------------

TMP_DL="$(mktemp -d "${TMPDIR:-/tmp}/arbin-tools.XXXXXX")" || die "mktemp failed"
STAGE="$(mktemp -d "$ROOT/.stage.XXXXXX")" || die "cannot create a staging directory under $ROOT"

ARCHIVE="$TMP_DL/asset.tar.gz"
printf 'Installing %s %s (%s)\n' "$TOOL" "$VERSION" "$PLATFORM"
if ! download_asset "$ASSET_URL" "$ARCHIVE"; then
  die "download failed. Check that your token has read access to Arbin-com/Others-develop (SSO-authorized if required)"
fi

ACTUAL="$(sha256_of "$ARCHIVE")"
if [ "$ACTUAL" != "$SHA256" ]; then
  rm -f "$ARCHIVE"
  die "sha256 mismatch for $TOOL $VERSION $PLATFORM (expected $SHA256, got $ACTUAL); nothing was installed"
fi

# The archive must hold exactly one regular file named after the tool.
LISTING="$(tar -tzf "$ARCHIVE")" || die "cannot read the archive"
case "$LISTING" in
  "$TOOL"|"./$TOOL") ;;
  *) die "unexpected archive content (expected only '$TOOL')" ;;
esac
case "$(tar -tvzf "$ARCHIVE" | cut -c1)" in
  -) ;;
  *) die "unexpected archive entry type for '$TOOL'" ;;
esac
mkdir "$STAGE/new"
tar -xzf "$ARCHIVE" -C "$STAGE/new" || die "cannot extract the archive"
[ -f "$STAGE/new/$TOOL" ] || die "archive did not contain '$TOOL'"
chmod 755 "$STAGE/new/$TOOL"

# ---- atomic move into place --------------------------------------------

DEST="$TOOL_DIR/$VERSION"
if [ -e "$DEST" ]; then
  mv "$DEST" "$STAGE/old" || die "cannot replace the existing $TOOL $VERSION"
fi
if ! mv "$STAGE/new" "$DEST"; then
  if [ -e "$STAGE/old" ]; then mv "$STAGE/old" "$DEST" || true; fi
  die "cannot move $TOOL $VERSION into place"
fi
rm -rf "$STAGE/old"

printf '%s\n' "$VERSION" >> "$TOOL_DIR/.history"
ln -sfn "$VERSION" "$TOOL_DIR/current"
ln -sfn "../$TOOL/current/$TOOL" "$ROOT/bin/$TOOL"

# ---- prune: keep the current version plus the newest $KEEP_OLD others ----

prune_old() {
  # newest first, one line per version
  order="$(sed '1!G;h;$!d' "$TOOL_DIR/.history" | awk '!seen[$0]++')"
  keep="$VERSION"
  count=0
  for v in $order; do
    [ "$v" = "$VERSION" ] && continue
    [ -d "$TOOL_DIR/$v" ] || continue
    if [ "$count" -lt "$KEEP_OLD" ]; then
      keep="$keep $v"
      count=$((count + 1))
    fi
  done
  for d in "$TOOL_DIR"/*; do
    [ -d "$d" ] || continue
    name="${d##*/}"
    [ "$name" = "current" ] && continue
    case " $keep " in
      *" $name "*) ;;
      *) rm -rf "$d" || printf 'warning: could not remove old version %s\n' "$name" >&2 ;;
    esac
  done
  : > "$TOOL_DIR/.history.new"
  for v in $keep; do printf '%s\n' "$v" >> "$TOOL_DIR/.history.new"; done
  # keep is newest first; history is oldest first
  sed '1!G;h;$!d' "$TOOL_DIR/.history.new" > "$TOOL_DIR/.history"
  rm -f "$TOOL_DIR/.history.new"
}
prune_old

# ---- PATH --------------------------------------------------------------

PATH_NOTE=""
add_profile_line() {
  pf="$1"
  if [ -f "$pf" ] && grep -F '# arbin-tools' "$pf" >/dev/null 2>&1; then
    return 0
  fi
  case "$ROOT" in
    "$HOME"/*) bindir="\$HOME/${ROOT#"$HOME"/}/bin" ;;
    *) bindir="$ROOT/bin" ;;
  esac
  printf '\nexport PATH="%s:$PATH" # arbin-tools\n' "$bindir" >> "$pf" ||
    { printf 'warning: could not update %s\n' "$pf" >&2; return 0; }
  PATH_NOTE="yes"
}

if [ "${ARBIN_TOOLS_SKIP_PATH:-}" != "1" ] && [ -n "${HOME:-}" ]; then
  case "${SHELL:-}" in
    */zsh)
      add_profile_line "$HOME/.zshrc"
      ;;
    */bash)
      add_profile_line "$HOME/.bashrc"
      [ -e "$HOME/.profile" ] || add_profile_line "$HOME/.profile"
      ;;
    *)
      add_profile_line "$HOME/.profile"
      ;;
  esac
fi

# ---- done --------------------------------------------------------------

EXE="$TOOL_DIR/$VERSION/$TOOL"
if ! OUT="$("$EXE" version 2>&1)"; then
  die "$TOOL was installed to $EXE but '$TOOL version' failed: $OUT"
fi
printf '%s\n' "$OUT"
printf 'Installed %s %s to %s\n' "$TOOL" "$VERSION" "$DEST"
if [ -n "$PATH_NOTE" ]; then
  printf 'Added %s/bin to PATH in your shell profile; open a new shell or run: export PATH="%s/bin:$PATH"\n' "$ROOT" "$ROOT"
else
  case ":$PATH:" in
    *":$ROOT/bin:"*) ;;
    *) printf 'Make sure %s/bin is on your PATH.\n' "$ROOT" ;;
  esac
fi
printf 'To update, rerun this command.\n'
