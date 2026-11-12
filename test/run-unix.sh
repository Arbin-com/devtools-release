#!/bin/sh
# Tests for install.sh against test/fake-server.mjs. Runs on Linux, macOS or WSL.
#
#   sh test/run-unix.sh
#
# The fake server is started with node when node is on PATH. Otherwise start it elsewhere
# (for example on the Windows host with FAKE_HOST=0.0.0.0) and pass its URL:
#   FAKE_SERVER=http://HOST:PORT FAKE_ALT_HOST=OTHERNAME sh test/run-unix.sh
# Everything runs under a temp HOME; the real ~/.arbin-tools, profiles and PATH are never touched.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="${INSTALL:-$HERE/../install.sh}"
W="$(mktemp -d "${TMPDIR:-/tmp}/arbin-test.XXXXXX")"
SERVER_PID=""
PASS=0
FAIL=0
N=0

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT

if [ -n "${FAKE_SERVER:-}" ]; then
  SERVER="$FAKE_SERVER"
else
  command -v node >/dev/null 2>&1 || { echo "node not found; set FAKE_SERVER" >&2; exit 2; }
  node "$HERE/fake-server.mjs" > "$W/server.out" 2> "$W/server.err" &
  SERVER_PID=$!
  i=0
  while [ ! -s "$W/server.out" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  PORT="$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$W/server.out")"
  [ -n "$PORT" ] || { echo "fake server did not start" >&2; cat "$W/server.err" >&2; exit 2; }
  SERVER="http://127.0.0.1:$PORT"
fi

# gh shim that is "not logged in"
mkdir -p "$W/shims-nogh" "$W/shims-gh"
printf '#!/bin/sh\nexit 1\n' > "$W/shims-nogh/gh"
printf '#!/bin/sh\n[ "$1 $2" = "auth token" ] && echo test-token\n' > "$W/shims-gh/gh"
chmod +x "$W/shims-nogh/gh" "$W/shims-gh/gh"

stats() { curl -fsS "$SERVER/__stats"; }
reset_stats() { curl -fsS "$SERVER/__reset" >/dev/null; }
stat_num() { stats | sed -n 's/.*"'"$1"'":\([0-9]*\).*/\1/p'; }

# new_case <name>: fresh HOME and root
new_case() {
  N=$((N + 1))
  NAME="$1"
  T="$W/case$N"
  mkdir -p "$T/home" "$T/tmp"
  ROOT="$T/root"
  EXTRA_PATH="$W/shims-nogh"
  NOTOKEN=""
  BADTOKEN=""
  SKIP_PATH="1"
  SHELLV="/bin/bash"
  reset_stats
}

# inst <args...>: runs install.sh with dash; sets RC, OUT_FILE, ERR_FILE
inst() {
  OUT_FILE="$T/out"
  ERR_FILE="$T/err"
  (
    HOME="$T/home"
    TMPDIR="$T/tmp"
    SHELL="$SHELLV"
    PATH="$EXTRA_PATH:$PATH"
    ARBIN_TOOLS_HOME="$ROOT"
    ARBIN_TOOLS_INDEX_URL="$SERVER"
    ARBIN_TOOLS_API_BASE="$SERVER"
    export HOME TMPDIR SHELL PATH ARBIN_TOOLS_HOME ARBIN_TOOLS_INDEX_URL ARBIN_TOOLS_API_BASE
    if [ -n "$SKIP_PATH" ]; then ARBIN_TOOLS_SKIP_PATH=1; export ARBIN_TOOLS_SKIP_PATH; fi
    unset GH_TOKEN GITHUB_TOKEN
    if [ -z "$NOTOKEN" ]; then GH_TOKEN="${BADTOKEN:-test-token}"; export GH_TOKEN; fi
    exec "$SHBIN" "$INSTALL" "$@"
  ) > "$OUT_FILE" 2> "$ERR_FILE"
  RC=$?
}

ok() {
  PASS=$((PASS + 1))
  printf 'ok   - %s\n' "$NAME"
}
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL - %s: %s\n' "$NAME" "$1"
  [ -f "$OUT_FILE" ] && sed 's/^/       out| /' "$OUT_FILE"
  [ -f "$ERR_FILE" ] && sed 's/^/       err| /' "$ERR_FILE"
}
# check <description> <command...>: collects the first failure
check() {
  _d="$1"
  shift
  if ! "$@"; then
    [ -n "${WHY:-}" ] || WHY="$_d"
  fi
}
done_case() {
  if [ -z "${WHY:-}" ]; then ok; else bad "$WHY"; fi
  WHY=""
}

rc_is() { [ "$RC" -eq "$1" ]; }
rc_fails() { [ "$RC" -ne 0 ]; }
out_has() { grep -F -- "$1" "$OUT_FILE" >/dev/null; }
err_has() { grep -F -- "$1" "$ERR_FILE" >/dev/null; }
is_dir() { [ -d "$1" ]; }
no_path() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
link_is() { [ "$(readlink "$1")" = "$2" ]; }
equals() { [ "$1" = "$2" ]; }
versions_in_root() { ls -1 "$ROOT/unit-sim" 2>/dev/null | grep -v '^current$' | tr '\n' ' '; }
no_leftovers() { [ -z "$(ls -A "$T/tmp")" ] && ! ls -d "$ROOT"/.stage.* >/dev/null 2>&1; }

WHY=""
SHBIN="$(command -v dash || command -v sh)"

# ---- 1 ---------------------------------------------------------------
new_case "fresh install of latest"
inst unit-sim
check "exit 0" rc_is 0
check "prints version line" out_has "unit-sim 0.4.0"
check "prints update hint" out_has "To update, rerun this command."
check "version dir" is_dir "$ROOT/unit-sim/0.4.0"
check "current symlink" link_is "$ROOT/unit-sim/current" "0.4.0"
check "bin shim symlink" link_is "$ROOT/bin/unit-sim" "../unit-sim/current/unit-sim"
check "shim runs" equals "$("$ROOT/bin/unit-sim" version)" "unit-sim 0.4.0"
check "token never sent to the index" equals "$(stat_num indexAuthSeen)" 0
check "token not forwarded to the redirect target" equals "$(stat_num blobAuthSeen)" 0
check "asset endpoint was hit once" equals "$(stat_num assetCalls)" 1
check "token not printed" sh -c "! grep -F test-token '$OUT_FILE' '$ERR_FILE'"
check "no staging or temp leftovers" no_leftovers
done_case

# ---- 2 ---------------------------------------------------------------
new_case "install a specific version"
inst unit-sim@0.2.0
check "exit 0" rc_is 0
check "prints 0.2.0" out_has "unit-sim 0.2.0"
check "only 0.2.0" equals "$(versions_in_root)" "0.2.0 "
check "current symlink" link_is "$ROOT/unit-sim/current" "0.2.0"
done_case

# ---- 3 ---------------------------------------------------------------
new_case "upgrade then rollback"
inst unit-sim@0.1.0
inst unit-sim
check "upgrade exit 0" rc_is 0
check "current is latest 0.4.0" link_is "$ROOT/unit-sim/current" "0.4.0"
inst unit-sim@0.1.0
check "rollback exit 0" rc_is 0
check "rollback prints 0.1.0" out_has "unit-sim 0.1.0"
check "current is 0.1.0 again" link_is "$ROOT/unit-sim/current" "0.1.0"
check "shim follows rollback" equals "$("$ROOT/bin/unit-sim" version)" "unit-sim 0.1.0"
check "both versions kept" equals "$(versions_in_root)" "0.1.0 0.4.0 "
inst unit-sim@0.1.0
check "reinstall of the same version works" rc_is 0
check "still both versions" equals "$(versions_in_root)" "0.1.0 0.4.0 "
check "no leftovers" no_leftovers
done_case

# ---- 4 ---------------------------------------------------------------
new_case "prune keeps current and the 2 newest others"
for v in 0.1.0 0.2.0 0.3.0 0.4.0; do inst "unit-sim@$v"; done
check "last install exit 0" rc_is 0
check "0.1.0 pruned, 0.2.0 0.3.0 0.4.0 kept" equals "$(versions_in_root)" "0.2.0 0.3.0 0.4.0 "
inst unit-sim@0.2.0
check "rollback to oldest kept exit 0" rc_is 0
check "active version never pruned" is_dir "$ROOT/unit-sim/0.2.0"
check "current is 0.2.0" link_is "$ROOT/unit-sim/current" "0.2.0"
check "kept 0.2.0 + 2 newest others" equals "$(versions_in_root)" "0.2.0 0.3.0 0.4.0 "
inst unit-sim@0.1.0
check "install of an old version exit 0" rc_is 0
check "current 0.1.0 + 2 most recently installed" equals "$(versions_in_root)" "0.1.0 0.2.0 0.4.0 "
done_case

# ---- 5 ---------------------------------------------------------------
new_case "wrong sha256 is rejected and leaves nothing"
inst unit-sim@0.9.0
check "non-zero exit" rc_fails
check "mismatch message" err_has "sha256 mismatch"
check "no version dir" no_path "$ROOT/unit-sim/0.9.0"
check "no current" no_path "$ROOT/unit-sim/current"
check "no shim" no_path "$ROOT/bin/unit-sim"
check "no staging or temp leftovers" no_leftovers
done_case

# ---- 5b --------------------------------------------------------------
new_case "wrong sha256 keeps the previously installed version"
inst unit-sim@0.1.0
inst unit-sim@0.9.0
check "non-zero exit" rc_fails
check "current still 0.1.0" link_is "$ROOT/unit-sim/current" "0.1.0"
check "shim still works" equals "$("$ROOT/bin/unit-sim" version)" "unit-sim 0.1.0"
done_case

# ---- 6 ---------------------------------------------------------------
new_case "missing token gives the exact one-line error"
NOTOKEN=1
inst unit-sim
check "exit 1" rc_is 1
check "exact stderr" equals "$(cat "$ERR_FILE")" 'Need a GitHub token with read access to Arbin-com/Others-develop: set GH_TOKEN, or run `gh auth login`.'
check "stdout empty" equals "$(cat "$OUT_FILE")" ""
check "no request was made" equals "$(stats | grep -o "GET /unit-sim" | wc -l | tr -d ' ')" 0
check "nothing installed" no_path "$ROOT/unit-sim"
done_case

# ---- 7 ---------------------------------------------------------------
new_case "token from gh auth token"
NOTOKEN=1
EXTRA_PATH="$W/shims-gh"
inst unit-sim@0.3.0
check "exit 0" rc_is 0
check "installed 0.3.0" out_has "unit-sim 0.3.0"
done_case

# ---- 7b --------------------------------------------------------------
new_case "GITHUB_TOKEN is used when GH_TOKEN is unset"
NOTOKEN=1
(
  HOME="$T/home" TMPDIR="$T/tmp" ARBIN_TOOLS_HOME="$ROOT" ARBIN_TOOLS_INDEX_URL="$SERVER" \
    ARBIN_TOOLS_API_BASE="$SERVER" ARBIN_TOOLS_SKIP_PATH=1 PATH="$W/shims-nogh:$PATH" GITHUB_TOKEN=test-token \
    exec "$SHBIN" "$INSTALL" unit-sim@0.3.0
) > "$T/out" 2> "$T/err"
RC=$?
OUT_FILE="$T/out"
ERR_FILE="$T/err"
check "exit 0" rc_is 0
check "installed 0.3.0" out_has "unit-sim 0.3.0"
done_case

# ---- 8 ---------------------------------------------------------------
new_case "rejected token fails with a hint and installs nothing"
BADTOKEN="wrong-token"
inst unit-sim
check "non-zero exit" rc_fails
check "hint on stderr" err_has "read access to Arbin-com/Others-develop"
check "asset endpoint answered 401" equals "$(stat_num unauthorized)" 1
check "nothing installed" no_path "$ROOT/unit-sim/0.4.0"
check "no leftovers" no_leftovers
done_case

# ---- 9 ---------------------------------------------------------------
new_case "PATH marker is added once (bash)"
SKIP_PATH=""
SHELLV="/bin/bash"
inst unit-sim@0.1.0
inst unit-sim@0.2.0
check "exit 0" rc_is 0
check ".bashrc has exactly one marker" equals "$(grep -c '# arbin-tools' "$T/home/.bashrc")" 1
check ".profile (was missing) has exactly one marker" equals "$(grep -c '# arbin-tools' "$T/home/.profile")" 1
check "line points at the root bin" grep -F "$T/root/bin" "$T/home/.bashrc" >/dev/null
check "no hint about the profile on the second run" sh -c "! grep -F 'Added' '$OUT_FILE'"
done_case

new_case "PATH marker for zsh and for unknown shells"
SKIP_PATH=""
SHELLV="/usr/bin/zsh"
inst unit-sim@0.1.0
inst unit-sim@0.1.0
check ".zshrc has one marker" equals "$(grep -c '# arbin-tools' "$T/home/.zshrc")" 1
check "no .bashrc" no_path "$T/home/.bashrc"
SHELLV="/bin/dash"
inst unit-sim@0.1.0
inst unit-sim@0.1.0
check ".profile has one marker" equals "$(grep -c '# arbin-tools' "$T/home/.profile")" 1
done_case

new_case "existing profile content is preserved"
SKIP_PATH=""
SHELLV="/bin/bash"
printf 'alias ll="ls -l"\n' > "$T/home/.bashrc"
inst unit-sim@0.1.0
check "original line kept" grep -F 'alias ll="ls -l"' "$T/home/.bashrc" >/dev/null
check "marker added" equals "$(grep -c '# arbin-tools' "$T/home/.bashrc")" 1
done_case

new_case "PATH marker also goes to ~/.bash_profile for bash on macOS"
mkdir -p "$T/osxbin"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; *) echo Darwin;; esac\n' > "$T/osxbin/uname"
printf '#!/bin/sh\n[ "$1 $2" = "-a 256" ] || exit 1\nshift 2\nexec sha256sum "$@"\n' > "$T/osxbin/shasum"
chmod +x "$T/osxbin/uname" "$T/osxbin/shasum"
EXTRA_PATH="$T/osxbin:$W/shims-nogh"
SKIP_PATH=""
SHELLV="/bin/bash"
inst unit-sim@0.1.0
inst unit-sim@0.1.0
check "exit 0" rc_is 0
check ".bash_profile created with one marker" equals "$(grep -c '# arbin-tools' "$T/home/.bash_profile")" 1
check ".bashrc has one marker" equals "$(grep -c '# arbin-tools' "$T/home/.bashrc")" 1
done_case

new_case "bash on Linux does not create ~/.bash_profile"
SKIP_PATH=""
SHELLV="/bin/bash"
inst unit-sim@0.1.0
check "no .bash_profile" no_path "$T/home/.bash_profile"
done_case

# ---- 10 --------------------------------------------------------------
new_case "curl | sh -s -- style invocation (script on stdin)"
(
  HOME="$T/home" TMPDIR="$T/tmp" ARBIN_TOOLS_HOME="$ROOT" ARBIN_TOOLS_INDEX_URL="$SERVER" \
    ARBIN_TOOLS_API_BASE="$SERVER" ARBIN_TOOLS_SKIP_PATH=1 PATH="$W/shims-nogh:$PATH" GH_TOKEN=test-token \
    exec sh -s -- unit-sim@0.2.0 < "$INSTALL"
) > "$T/out" 2> "$T/err"
RC=$?
OUT_FILE="$T/out"
ERR_FILE="$T/err"
check "exit 0" rc_is 0
check "installed 0.2.0" out_has "unit-sim 0.2.0"
done_case

# ---- 11 --------------------------------------------------------------
new_case "macOS path: Darwin/arm64 with shasum"
mkdir -p "$T/osxbin"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; *) echo Darwin;; esac\n' > "$T/osxbin/uname"
printf '#!/bin/sh\n[ "$1 $2" = "-a 256" ] || exit 1\nshift 2\nexec sha256sum "$@"\n' > "$T/osxbin/shasum"
chmod +x "$T/osxbin/uname" "$T/osxbin/shasum"
EXTRA_PATH="$T/osxbin:$W/shims-nogh"
inst unit-sim@0.3.0
check "exit 0" rc_is 0
check "platform is osx-arm64" out_has "(osx-arm64)"
check "installed" out_has "unit-sim 0.3.0"
done_case

new_case "unsupported OS and CPU give clear errors"
mkdir -p "$T/badbin"
printf '#!/bin/sh\ncase "$1" in -s) echo MINGW64_NT-10.0;; -m) echo x86_64;; esac\n' > "$T/badbin/uname"
chmod +x "$T/badbin/uname"
EXTRA_PATH="$T/badbin:$W/shims-nogh"
inst unit-sim
check "non-zero exit" rc_fails
check "mentions unsupported OS" err_has "unsupported OS 'MINGW64_NT-10.0'"
printf '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo riscv64;; esac\n' > "$T/badbin/uname"
inst unit-sim
check "non-zero exit for CPU" rc_fails
check "mentions unsupported CPU" err_has "unsupported CPU 'riscv64'"
done_case

# ---- 12 --------------------------------------------------------------
new_case "missing sha256sum is a hard error with a hint"
mkdir -p "$T/minbin"
for c in curl tar mktemp sed awk tr cut head grep ln mv rm mkdir chmod cat uname dirname ls; do
  p="$(command -v "$c" 2>/dev/null)" && ln -s "$p" "$T/minbin/$c"
done
(
  HOME="$T/home" TMPDIR="$T/tmp" ARBIN_TOOLS_HOME="$ROOT" ARBIN_TOOLS_INDEX_URL="$SERVER" \
    ARBIN_TOOLS_API_BASE="$SERVER" ARBIN_TOOLS_SKIP_PATH=1 PATH="$T/minbin" GH_TOKEN=test-token \
    exec "$SHBIN" "$INSTALL" unit-sim
) > "$T/out" 2> "$T/err"
RC=$?
OUT_FILE="$T/out"
ERR_FILE="$T/err"
check "non-zero exit" rc_fails
check "hint" err_has "sha256sum is required"
check "nothing installed" no_path "$ROOT/unit-sim"
done_case

# ---- 13 --------------------------------------------------------------
new_case "argument handling"
inst --help
check "--help exit 0" rc_is 0
check "--help prints usage" out_has "Usage: install.sh"
inst
check "no tool: non-zero" rc_fails
inst '../evil'
check "path traversal in tool name rejected" rc_fails
check "message" err_has "invalid tool name"
inst 'unit-sim@../../x'
check "bad version rejected" rc_fails
check "message" err_has "invalid version"
inst unit-sim@9.9.9
check "unpublished version fails" rc_fails
check "message" err_has "no published unit-sim version 9.9.9"
inst nosuchtool
check "unknown tool fails" rc_fails
inst --bogus unit-sim
check "unknown option fails" rc_fails
done_case

new_case "--dir overrides the root"
(
  HOME="$T/home" TMPDIR="$T/tmp" ARBIN_TOOLS_HOME="$T/ignored" ARBIN_TOOLS_INDEX_URL="$SERVER" \
    ARBIN_TOOLS_API_BASE="$SERVER" ARBIN_TOOLS_SKIP_PATH=1 PATH="$W/shims-nogh:$PATH" GH_TOKEN=test-token \
    exec "$SHBIN" "$INSTALL" --dir "$T/custom" unit-sim@0.1.0
) > "$T/out" 2> "$T/err"
RC=$?
OUT_FILE="$T/out"
ERR_FILE="$T/err"
check "exit 0" rc_is 0
check "installed under --dir" is_dir "$T/custom/unit-sim/0.1.0"
check "ARBIN_TOOLS_HOME ignored" no_path "$T/ignored"
done_case

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
