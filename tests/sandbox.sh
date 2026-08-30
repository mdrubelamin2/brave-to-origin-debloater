#!/usr/bin/env bash
# Builds a sandboxed copy of origin.sh plus a fake machine to run it against.
#
# origin.sh writes to /Library/Managed Preferences and to the real Brave
# profile, and refuses to run as anything but root. None of that is available
# to a test, and none of it should be: a suite that needs sudo to run is a
# suite nobody runs. So the copy is rewritten at four seams and nowhere else —
# the path roots, the privilege drop, the running-Brave check, and the cfprefsd
# flush. Every line of logic under test is the shipped line.
#
# No `set -e` here: this file is sourced by the runner, which must keep going
# after a failing test rather than exiting on the first one.

# sandbox_build <sandbox-dir>
# Populates the directory and echoes the path of the runnable script.
sandbox_build() {
  local sbx="$1" src="${2:-}"
  [[ -n "$src" ]] || src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/origin.sh"

  local home="${sbx}/home/tester"
  local data="${home}/Library/Application Support/BraveSoftware/Brave-Browser"
  mkdir -p "${sbx}/Library/Managed Preferences/tester"
  mkdir -p "${sbx}/Library/Application Support"
  mkdir -p "${data}/Default" "${data}/Profile 1"
  # A fake app bundle, so channel detection and the capability probe have
  # something to find. The probe reads it with `strings`; writing the policy
  # names into it makes every policy report as supported.
  local fw="${sbx}/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/152.1.94.117"
  mkdir -p "$fw"
  grep -o '"Brave[A-Za-z]*|[a-z]*|[a-z]*"' "$src" | cut -d'"' -f2 | cut -d'|' -f1 \
    > "${fw}/Brave Browser Framework"
  echo "TorDisabled" >> "${fw}/Brave Browser Framework"

  local out="${sbx}/origin.sh"
  SBX="$sbx" python3 - "$src" "$out" <<'PY'
import os, re, sys
sbx = os.environ["SBX"]
src, out = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()

def sub(pattern, repl, why):
    global s
    s, n = re.subn(pattern, repl, s, count=1, flags=re.M)
    assert n == 1, f"sandbox seam not found ({why}): {pattern}"

# 1. Path roots.
sub(r'^MP_ROOT="/Library/Managed Preferences"$',
    f'MP_ROOT="{sbx}/Library/Managed Preferences"', "managed prefs root")
sub(r'^RECEIPT_DIR="/Library/Application Support/brave-origin-clone"$',
    f'RECEIPT_DIR="{sbx}/Library/Application Support/brave-origin-clone"', "receipt dir")
sub(r'^TARGET_HOME=\$\(TU="\$TARGET_USER" python3 -c \\\n.*$',
    f'TARGET_HOME="{sbx}/home/tester"', "home dir")
sub(r'^  "/Applications/Brave Browser\.app"$',
    f'  "{sbx}/Applications/Brave Browser.app"', "app path")

# 2. Root-only preconditions and side effects.
sub(r'^\[\[ "\$EUID" -ne 0 \]\] && err .*$', ': # sandbox: EUID check disabled', "euid guard")
sub(r'^TARGET_USER=.*$', 'TARGET_USER="tester"', "target user")
sub(r'^as_user\(\) \{ sudo -u "\$TARGET_USER" "\$@"; \}$',
    'as_user() { "$@"; }   # sandbox: no privilege to drop', "as_user")
sub(r'^brave_running\(\) \{.*$',
    'brave_running() { [[ -n "${SBX_BRAVE_RUNNING:-}" ]]; }', "brave_running")
s = s.replace("killall cfprefsd 2>/dev/null || true", ": # sandbox: no cfprefsd")
# chown to root:wheel cannot work unprivileged and is not what these tests check.
s = re.sub(r'^(\s*)chown root:wheel', r'\1chown "$(id -un)" 2>/dev/null || true; : ', s, flags=re.M)

open(out, "w", encoding="utf-8").write(s)
PY
  chmod +x "$out"
  bash -n "$out" || { echo "sandbox copy has a syntax error" >&2; return 1; }
  echo "$out"
}

# Writes a Preferences/Local State file. sandbox_json <path> <json>
sandbox_json() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }

# Builds a sandboxed install.sh. Rewrites only the two root preconditions and
# the /Applications lookup; the fetch, checksum and dispatch logic is the
# shipped code. sandbox_installer <sandbox-dir>
sandbox_installer() {
  local sbx="$1" src
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
  local out="${sbx}/install.sh"
  SBX="$sbx" python3 - "$src" "$out" <<'PY'
import os, re, sys
sbx = os.environ["SBX"]
src, out = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()

def sub(pattern, repl, why):
    global s
    s, n = re.subn(pattern, repl, s, count=1, flags=re.M)
    assert n == 1, f"installer seam not found ({why})"

sub(r'^\[\[ "\$EUID" -eq 0 \]\] \|\| err "Needs root.*\n.*$',
    ': # sandbox: root check disabled', "euid guard")
sub(r'^\[\[ -n "\$\{SUDO_USER:-\}".*\n.*\n.*$',
    'SUDO_USER="${SUDO_USER:-tester}"  # sandbox', "sudo_user guard")
s = s.replace('"/Applications/', f'"{sbx}/Applications/')
open(out, "w", encoding="utf-8").write(s)
PY
  bash -n "$out" || { echo "sandboxed installer has a syntax error" >&2; return 1; }
  echo "$out"
}

# Builds a LINUX sandbox: the same script, forced onto its Linux code paths,
# with every system root redirected into the sandbox. Runs on macOS, which is
# the point — the Linux backend is testable without a Linux box.
# sandbox_build_linux <sandbox-dir> -> path of the runnable script
sandbox_build_linux() {
  local sbx="$1" src
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/origin.sh"

  local home="${sbx}/home/tester"
  mkdir -p "${sbx}/etc/brave/policies/managed" "${sbx}/var/lib/brave-to-origin"
  mkdir -p "${home}/.config/BraveSoftware/Brave-Browser/Default"
  mkdir -p "${home}/.config/BraveSoftware/Brave-Browser-Beta/Default"
  # Stand-in ELFs. The capability probe greps them for policy names, so writing
  # the names in makes every policy report as supported.
  local b
  for b in brave brave-beta brave-nightly; do
    mkdir -p "${sbx}/opt/brave.com/${b}"
    grep -o '"Brave[A-Za-z]*|[a-z]*|[a-z]*"' "$src" | cut -d'"' -f2 | cut -d'|' -f1 \
      > "${sbx}/opt/brave.com/${b}/brave"
    echo "TorDisabled" >> "${sbx}/opt/brave.com/${b}/brave"
    chmod +x "${sbx}/opt/brave.com/${b}/brave"
  done

  local out="${sbx}/origin-linux.sh"
  SBX="$sbx" python3 - "$src" "$out" <<'PY'
import os, re, sys
sbx = os.environ["SBX"]
src, out = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()

def sub(pattern, repl, why):
    global s
    s, n = re.subn(pattern, repl, s, count=1, flags=re.M)
    assert n == 1, f"linux sandbox seam not found ({why}): {pattern}"

sub(r'^PLATFORM="\$\(uname -s\)"$', 'PLATFORM="linux"', "platform")
sub(r'^LINUX_POLICY_ROOT="/etc/brave/policies"$',
    f'LINUX_POLICY_ROOT="{sbx}/etc/brave/policies"', "policy root")
sub(r'^LINUX_RECEIPT_DIR="/var/lib/brave-to-origin"$',
    f'LINUX_RECEIPT_DIR="{sbx}/var/lib/brave-to-origin"', "receipt dir")
sub(r'^\[\[ "\$EUID" -ne 0 \]\] && err .*$', ': # sandbox', "euid guard")
sub(r'^TARGET_USER=.*$', 'TARGET_USER="tester"', "target user")
sub(r'^TARGET_HOME=\$\(TU="\$TARGET_USER" python3 -c \\\n.*$',
    f'TARGET_HOME="{sbx}/home/tester"', "home dir")
sub(r'^as_user\(\) \{ sudo -u "\$TARGET_USER" "\$@"; \}$', 'as_user() { "$@"; }', "as_user")
sub(r'^brave_running\(\) \{.*$',
    'brave_running() { [[ -n "${SBX_BRAVE_RUNNING:-}" ]]; }', "brave_running")
s = s.replace('"/opt/brave.com/', f'"{sbx}/opt/brave.com/')
s = s.replace('SNAP_BRAVE="', f'SNAP_BRAVE="{sbx}')
s = re.sub(r'^(\s*)chown root:wheel', r'\1chown "$(id -un)" 2>/dev/null || true; : ', s, flags=re.M)
s = re.sub(r'^(\s*)chown root:root', r'\1chown "$(id -un)" 2>/dev/null || true; : ', s, flags=re.M)
open(out, "w", encoding="utf-8").write(s)
PY
  chmod +x "$out"
  bash -n "$out" || { echo "linux sandbox copy has a syntax error" >&2; return 1; }
  echo "$out"
}
