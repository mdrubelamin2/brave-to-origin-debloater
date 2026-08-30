#!/usr/bin/env bash
# =============================================================================
# Brave Origin — policy clone for standard Brave on macOS
# =============================================================================
#
# Applies the 16 preferences that Brave Origin "upgrade mode" enforces, using
# Brave's own documented enterprise-policy mechanism, plus the handful of
# standalone-build defaults that are reachable without a custom binary.
#
# Every policy key, pref name and default was verified against brave-core.
# See README.md for the file-by-file citations.
#
# PROVENANCE
#   `activate` records what it changed, and each key's prior value, in a
#   receipt under /Library/Application Support/brave-origin-clone/.
#   `deactivate` acts only on that receipt: it removes keys it added and
#   restores keys it overwrote. Without a receipt it will not guess, because
#   these policy keys are also what an MDM profile or another debloat script
#   would write, and deleting those is not this script's business.
#
# WHAT THIS DOES NOT DO
#   - It does not unlock brave://settings/origin. Those toggles are gated on
#     IsBraveOriginPurchased(), which requires real SKU credentials.
#   - It does not shrink the binary. Origin compiles features out; the arm64
#     framework is ~13.6 MB smaller. Policy cannot reproduce that.
#   - It does not make the 7 "user_settable" policies user-toggleable. All 16
#     declare can_be_recommended:false, so mandatory is the only level. Brave
#     Origin also applies them as POLICY_LEVEL_MANDATORY; the difference is
#     the settings UI, not the level.
#
# Usage:
#   sudo ./origin.sh activate|deactivate|status [--machine] [--channel <id>]
#                                               [--dry-run] [--no-color]
#
# Requires: python3 (Command Line Tools). Verify results at brave://policy.
# Restart Brave afterwards — every policy is dynamic_refresh:false.
# =============================================================================

set -euo pipefail

if [[ -z "${BASH_VERSINFO:-}" ]]; then
  echo "This script requires bash." >&2; exit 1
fi

# The policy set was last checked against this Brave version. `status` compares
# it to what is installed so a stale set becomes visible rather than silent.
VALIDATED_AGAINST="152.1.94.117"

# How to tell the user to run this again. When install.sh fetched the script to
# a temp file, $0 is that temp path and repeating it back would be useless, so
# the installer sets this to the command the user actually typed.
SELF_CMD="${ORIGIN_INVOCATION:-sudo ./origin.sh}"

# ── Argument parsing ─────────────────────────────────────────────────────────
CMD=""; SCOPE="user"; FORCE_CHANNEL=""; DRY_RUN=0; USE_COLOR=1
[[ -t 1 ]] || USE_COLOR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    activate|deactivate|status) CMD="$1"; shift ;;
    --machine)   SCOPE="machine"; shift ;;
    --channel)   if [[ $# -lt 2 ]]; then
                   echo "--channel requires a bundle ID, e.g. --channel com.brave.Browser.beta" >&2
                   exit 1
                 fi
                 FORCE_CHANNEL="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --no-color)  USE_COLOR=0; shift ;;
    -h|--help)   CMD="help"; shift ;;
    *)           echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ "$USE_COLOR" -eq 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; BOLD=""; RESET=""
fi

info()    { echo "${CYAN}[*]${RESET} $*"; }
ok()      { echo "${GREEN}[+]${RESET} $*"; }
warn()    { echo "${YELLOW}[!]${RESET} $*"; }
fail()    { echo "${RED}[x]${RESET} $*"; }
skip()    { echo "${DIM}[-] $*${RESET}"; }
err()     { echo "${RED}[x]${RESET} $*" >&2; exit 1; }
section() { echo; echo "${BOLD}$*${RESET}"; }

usage() {
  cat <<EOF

${BOLD}Usage:${RESET} ${SELF_CMD} <activate|deactivate|status> [options]

  activate     Apply the Brave Origin policy set and standalone-default prefs
  deactivate   Undo exactly what activate recorded in its receipt
  status       Report what is applied, and what Brave will actually honour

${BOLD}Options:${RESET}
  --machine        Machine-wide policy path (lower fidelity, not file-watched)
  --channel <id>   Target bundle ID, e.g. com.brave.Browser.beta
  --dry-run        Show planned changes without writing
  --no-color       Suppress ANSI colour (also automatic when piped)

EOF
}

[[ "$CMD" == "help" ]] && { usage; exit 0; }
[[ -z "$CMD" ]] && { usage >&2; exit 1; }
[[ "$EUID" -ne 0 ]] && err "Run with sudo: ${SELF_CMD} $CMD"

# ── Preflight ────────────────────────────────────────────────────────────────
# python3 does every JSON edit. Discovering it is missing halfway through
# leaves policies applied and prefs untouched, so check before writing anything.
command -v python3 >/dev/null 2>&1 || \
  err "python3 not found. Install the Command Line Tools: xcode-select --install"
[[ -x /usr/libexec/PlistBuddy ]] || err "/usr/libexec/PlistBuddy not found."
# plutil carries the typed reads and writes, so a missing one is not a fallback
# case: without it a prior value cannot be recorded faithfully at all.
command -v plutil >/dev/null 2>&1 || err "plutil not found."

# ── Resolve the human user ───────────────────────────────────────────────────
# Under sudo $HOME may be root's. The per-user managed-preferences directory and
# the profile paths both key off the login user, which is also what Chromium's
# PolicyLoaderMac::GetManagedPolicyPath() uses via getlogin().
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
[[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]] && \
  err "Cannot determine the login user. Run via sudo from your own account."
# Ask the password database directly. `eval echo ~$user` runs the username as
# shell input — command substitution embedded in SUDO_USER would execute, and a
# home directory containing a glob character would be expanded away.
TARGET_HOME=$(TU="$TARGET_USER" python3 -c \
  'import os, pwd; print(pwd.getpwnam(os.environ["TU"]).pw_dir)' 2>/dev/null || true)
[[ -d "$TARGET_HOME" ]] || err "Home directory for '${TARGET_USER}' not found."

# Every file under the user's home is edited AS THAT USER, never as root.
# Root writing by path into a user-writable directory is a privilege-escalation
# primitive: the user can pre-plant a symlink at the temp path and have root
# write, chmod and chown an arbitrary file. Dropping privileges removes it.
as_user() { sudo -u "$TARGET_USER" "$@"; }

# ── Channel detection ────────────────────────────────────────────────────────
# Bundle IDs from brave-core app/theme/*/BRANDING. Brave is not built with
# GOOGLE_CHROME_BRANDING, so unlike Chrome each channel reads its OWN bundle ID.
declare -a CH_APP=(
  "/Applications/Brave Browser.app"
  "/Applications/Brave Browser Beta.app"
  "/Applications/Brave Browser Nightly.app"
  "/Applications/Brave Browser Dev.app"
  "/Applications/Brave Origin.app"
)
declare -a CH_ID=(
  "com.brave.Browser" "com.brave.Browser.beta" "com.brave.Browser.nightly"
  "com.brave.Browser.dev" "com.brave.Browser.origin"
)
declare -a CH_DATA=(
  "Brave-Browser" "Brave-Browser-Beta" "Brave-Browser-Nightly"
  "Brave-Browser-Dev" "Brave-Origin"
)

APP_PATH=""; BUNDLE_ID=""; DATA_DIR=""; CHANNEL_NAME=""
declare -a FOUND_IDX=()
for i in "${!CH_APP[@]}"; do
  [[ -d "${CH_APP[$i]}" ]] && FOUND_IDX+=("$i")
done
[[ ${#FOUND_IDX[@]} -eq 0 ]] && err "No Brave install found in /Applications."

pick_channel() {
  local idx="$1"
  APP_PATH="${CH_APP[$idx]}"; BUNDLE_ID="${CH_ID[$idx]}"
  DATA_DIR="${CH_DATA[$idx]}"; CHANNEL_NAME="$(basename "${CH_APP[$idx]}" .app)"
}

if [[ -n "$FORCE_CHANNEL" ]]; then
  matched=0
  for i in "${!CH_ID[@]}"; do
    [[ "${CH_ID[$i]}" == "$FORCE_CHANNEL" ]] && { pick_channel "$i"; matched=1; break; }
  done
  [[ $matched -eq 1 ]] || err "Unknown channel '$FORCE_CHANNEL'."
  [[ -d "$APP_PATH" ]] || err "'$CHANNEL_NAME' is not installed."
else
  chosen=""
  for i in "${FOUND_IDX[@]}"; do
    [[ "${CH_ID[$i]}" == "com.brave.Browser.origin" ]] && continue
    chosen="$i"; break
  done
  [[ -z "$chosen" ]] && err "Only Brave Origin standalone is installed — its features are already compiled out."
  pick_channel "$chosen"
fi

[[ "$BUNDLE_ID" == "com.brave.Browser.origin" ]] && \
  warn "Target is the Brave Origin standalone build; its features are compiled out."

# ── Paths ────────────────────────────────────────────────────────────────────
# The per-user path is what PolicyLoaderMac::GetManagedPolicyPath() builds and
# file-watches, and it yields POLICY_SCOPE_USER, matching Brave Origin itself.
# The machine-wide path is also read, but only on the 15-minute poll, and
# reports MACHINE scope.
MP_ROOT="/Library/Managed Preferences"
if [[ "$SCOPE" == "user" ]]; then PLIST_DIR="${MP_ROOT}/${TARGET_USER}"
else                              PLIST_DIR="${MP_ROOT}"; fi
PLIST="${PLIST_DIR}/${BUNDLE_ID}.plist"
# Repeated back to the user in rollback instructions, so the command printed
# targets the scope this run actually wrote.
SCOPE_FLAG=""; [[ "$SCOPE" == "machine" ]] && SCOPE_FLAG=" --machine"
USER_PLIST="${MP_ROOT}/${TARGET_USER}/${BUNDLE_ID}.plist"
MACHINE_PLIST="${MP_ROOT}/${BUNDLE_ID}.plist"

RECEIPT_DIR="/Library/Application Support/brave-origin-clone"
# One receipt per scope. `activate` followed by `activate --machine` populates
# two plists, and a single receipt can only ever describe one of them — the
# other would be left enforcing policy with nothing able to roll it back.
RECEIPT="${RECEIPT_DIR}/${BUNDLE_ID}.${SCOPE}.json"
# Written by versions before the scope split. Still honoured by `deactivate`,
# and absorbed by `activate` when its "plist" names the path this run targets.
LEGACY_RECEIPT="${RECEIPT_DIR}/${BUNDLE_ID}.json"

USER_DATA="${TARGET_HOME}/Library/Application Support/BraveSoftware/${DATA_DIR}"
LOCAL_STATE="${USER_DATA}/Local State"

# ── The 16 Brave Origin policies ─────────────────────────────────────────────
# brave_origin_service_factory.cc: kBraveOriginBrowserMetadata (4) and
# kBraveOriginProfileMetadata (12). Keys via brave_simple_policy_map.h.
# Format: key|value|settable
declare -a POLICIES=(
  "TorDisabled|true|locked"
  "BraveStatsPingEnabled|false|settable"
  "BraveP3AEnabled|false|settable"
  "BraveLocalAIEnabled|false|settable"
  "BraveWaybackMachineEnabled|false|settable"
  "BraveRewardsDisabled|true|locked"
  "BraveWalletDisabled|true|locked"
  "BraveAIChatEnabled|false|locked"
  "BraveSpeedreaderEnabled|false|settable"
  "BravePlaylistEnabled|false|settable"
  "BraveNewsDisabled|true|locked"
  "BraveVPNDisabled|true|locked"
  "BraveTalkDisabled|true|locked"
  "BraveWebDiscoveryEnabled|false|settable"
  "EmailAliasesEnabled|false|locked"
  "PsstEnabled|false|locked"
)

# Standalone-build defaults with no policy equivalent. Format: pref|value
declare -a PROFILE_PREFS=(
  "brave.show_side_panel_button|false"
  "brave.brave_search_conversion.dismissed|true"
  "brave.branded_wallpaper_notification_dismissed|true"
)
# Crash/metrics reporting is a pref, not the MetricsReportingEnabled policy:
# that policy is sensitive:true, so PolicyLoaderMac blocks it on any Mac that
# is not MDM-enrolled or domain-joined.
declare -a LOCAL_STATE_PREFS=(
  "user_experience_metrics.reporting_enabled|false"
)

# ── Capability probe ─────────────────────────────────────────────────────────
# PolicyLoaderMac::Load() walks the compiled-in schema and only queries keys it
# finds there. An unknown key is never read: no value, no error, no row at
# brave://policy. Probe the shipped binary so that is visible rather than silent.
SUPPORTED_KEYS=""
probe_supported_keys() {
  local fw keyfile
  # `|| true`: under pipefail a `find` miss (or head's SIGPIPE) would otherwise
  # abort the run before the graceful branch below is ever reached.
  fw=$(find "${APP_PATH}/Contents/Frameworks" -maxdepth 4 -name "Brave*Framework" -type f -print -quit 2>/dev/null || true)
  if [[ -z "$fw" || ! -f "$fw" ]]; then
    warn "Framework binary not found; cannot verify which policies this build knows."
    SUPPORTED_KEYS="__PROBE_UNAVAILABLE__"; return
  fi
  keyfile=$(mktemp) || { SUPPORTED_KEYS="__PROBE_UNAVAILABLE__"; return; }
  for entry in "${POLICIES[@]}"; do echo "${entry%%|*}"; done > "$keyfile"
  if command -v strings >/dev/null 2>&1; then
    SUPPORTED_KEYS=$(strings -a "$fw" | grep -Fxf "$keyfile" | sort -u || true)
  else
    SUPPORTED_KEYS=$(LC_ALL=C tr -c '[:print:]' '\n' < "$fw" | grep -Fxf "$keyfile" | sort -u || true)
  fi
  rm -f "$keyfile"
  # Any real Brave framework contains at least TorDisabled. Zero matches means
  # the probe failed, not that Brave supports nothing — do not act on it.
  if [[ -z "$SUPPORTED_KEYS" ]]; then
    warn "Capability probe returned nothing; treating build support as unknown."
    SUPPORTED_KEYS="__PROBE_UNAVAILABLE__"
  fi
}

is_supported() {
  [[ "$SUPPORTED_KEYS" == "__PROBE_UNAVAILABLE__" ]] && return 0
  grep -qx "$1" <<< "$SUPPORTED_KEYS"
}

# ── Brave must not be running ────────────────────────────────────────────────
# Match on the bundle name, not the detected path, so a copy launched from
# ~/Applications or a mounted DMG is still caught.
brave_running() { pgrep -f "${CHANNEL_NAME}\.app/Contents/MacOS/" >/dev/null 2>&1; }

require_brave_closed() {
  brave_running && err "${CHANNEL_NAME} is running. Quit it completely, then re-run.
    Brave rewrites Preferences and Local State on exit and would discard these changes."
  return 0
}

# ── plist helpers ────────────────────────────────────────────────────────────
pb() { /usr/libexec/PlistBuddy "$@"; }

# Existence is a plutil question, not an emptiness one: PlistBuddy prints
# nothing both for a missing key and for a key holding "", so an empty string
# would read as absent — deleted on rollback, and reported as removed by a
# delete that never happened.
plist_key_exists() { plutil -type "$2" "$1" >/dev/null 2>&1; }

# bool | integer | float | string | date | data | array | dictionary, or "" when
# the key is absent.
plist_key_type() { plutil -type "$2" "$1" 2>/dev/null || true; }

# plutil terminates `raw` output with exactly one newline, which command
# substitution then strips. A value whose own last byte is a newline is the one
# case this cannot round-trip.
plist_raw() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

# Types whose value can be put back exactly as it was found. A dict or an array
# has no faithful single-value representation here, and writing a substitute
# would destroy the original — those keys are refused, never guessed at.
plist_type_is_restorable() {
  case "$1" in bool|integer|float|string) return 0 ;; *) return 1 ;; esac
}

# PlistBuddy exits 0 even when it cannot save (permission denied, immutable
# flag, full disk), and so does plutil in some of the same cases. Read the value
# back rather than trusting the exit status, and check the TYPE first: a
# pre-existing string "true" satisfies a value-only check while Brave's boolean
# schema rejects it. `plutil -replace` sets the type outright, so the old
# delete-then-Add dance is no longer needed to get rid of it.
plist_set_bool_verified() {
  local file="$1" key="$2" val="$3"
  plutil -replace "$key" -bool "$val" "$file" >/dev/null 2>&1 || true
  [[ "$(plist_key_type "$file" "$key")" == "bool" ]] &&
    [[ "$(plist_raw "$file" "$key")" == "$val" ]]
}

# Restore a prior with the type it was recorded under. Verified identically, so
# an integer 1 that came back as a boolean true counts as a failed restore
# rather than a silent type change.
plist_restore_verified() {
  local file="$1" key="$2" ktype="$3" val="$4" flag
  case "$ktype" in
    bool)    flag="-bool"    ;;
    integer) flag="-integer" ;;
    float)   flag="-float"   ;;
    string)  flag="-string"  ;;
    *)       return 1        ;;
  esac
  plutil -replace "$key" "$flag" "$val" "$file" >/dev/null 2>&1 || true
  [[ "$(plist_key_type "$file" "$key")" == "$ktype" ]] &&
    [[ "$(plist_raw "$file" "$key")" == "$val" ]]
}

plist_delete_verified() {
  local file="$1" key="$2"
  plutil -remove "$key" "$file" >/dev/null 2>&1 || true
  ! plist_key_exists "$file" "$key"
}

plist_parses() { plutil -lint "$1" >/dev/null 2>&1; }

# Read-only half of ensure_plist, so activate can validate before it captures
# priors and long before it writes anything.
check_plist_readable() {
  if [[ -f "${PLIST}" ]] && ! plist_parses "${PLIST}"; then
    err "${PLIST} exists but is not a valid plist. Refusing to touch it."
  fi
}

ensure_plist() {
  # Only set ownership on a directory we created. An existing one may have been
  # tightened deliberately by an admin, or be managed by mdmclient.
  if [[ ! -d "${PLIST_DIR}" ]]; then
    mkdir -p "${PLIST_DIR}" || err "Could not create ${PLIST_DIR}."
    chown root:wheel "${PLIST_DIR}" 2>/dev/null || true
    chmod 755 "${PLIST_DIR}" 2>/dev/null || true
  fi
  check_plist_readable
  # Same reasoning for the file: an admin may have tightened an existing plist
  # to 0600, and widening it back to 644 is not this script's call. Ownership
  # and mode are set only on a plist this run brought into existence.
  if [[ ! -f "${PLIST}" ]]; then
    pb -c "Clear dict" "${PLIST}" >/dev/null 2>&1 || true
    [[ -f "${PLIST}" ]] || err "Could not create ${PLIST}."
    chown root:wheel "${PLIST}" 2>/dev/null || true
    chmod 644 "${PLIST}" 2>/dev/null || true
  fi
}

finalize_plist() {
  # cfprefsd caches preference domains and can write its stale copy back over
  # the file. Brave's own docs prescribe this after a PlistBuddy edit.
  killall cfprefsd 2>/dev/null || true
}

# Count only top-level keys. Callers must confirm the file parses first: a
# corrupt plist yields no output and would otherwise look empty.
plist_key_count() {
  local f="$1" n
  [[ -f "$f" ]] || { echo 0; return; }
  n=$(pb -c "Print" "$f" 2>/dev/null | grep -c "^    [^ ].* = " || true)
  echo "${n:-0}"
}

# ── Capturing plist priors ───────────────────────────────────────────────────
# Every prior value is read, with its type, BEFORE the first write. The typed
# record is what makes rollback exact: the old receipt kept PlistBuddy's
# rendering and put everything back as a boolean, so an integer 1 returned as
# true and a string "hello" as false.
#
# Writes the priors as a JSON object to $2 and prints one "<key>\t<reason>" line
# per key that must not be touched at all. Values reach python through the
# environment and plutil through argv; nothing is interpolated into program text.
capture_policy_priors() {
  local file="$1" out="$2"
  FILE="$file" OUT="$out" KEYS="$(printf '%s\n' "${POLICIES[@]%%|*}")" python3 - <<'PY'
import json, os, subprocess

path = os.environ["FILE"]
keys = [k for k in os.environ["KEYS"].split("\n") if k]
exists = os.path.isfile(path)
RESTORABLE = {"bool", "integer", "float", "string"}

def plutil(*args):
    return subprocess.run(["plutil", *args, path], capture_output=True)

priors, refused = {}, []
for key in keys:
    if not exists:
        priors[key] = {"type": "absent"}
        continue
    probe = plutil("-type", key)
    if probe.returncode != 0:
        priors[key] = {"type": "absent"}
        continue
    ktype = probe.stdout.decode("utf-8", "replace").strip()
    if ktype not in RESTORABLE:
        refused.append(f"{key}\tprior is a {ktype}")
        continue
    read = plutil("-extract", key, "raw", "-o", "-")
    if read.returncode != 0:
        refused.append(f"{key}\tprior could not be read")
        continue
    raw = read.stdout
    if raw.endswith(b"\n"):          # plutil terminates raw output with one \n
        raw = raw[:-1]
    try:
        priors[key] = {"type": ktype, "value": raw.decode("utf-8")}
    except UnicodeDecodeError:
        refused.append(f"{key}\tprior is not text")

with open(os.environ["OUT"], "w", encoding="utf-8") as fh:
    json.dump(priors, fh)
for line in refused:
    print(line)
PY
}

# ── JSON pref editing ────────────────────────────────────────────────────────
# In "read" mode, emits one JSON array ["<file>","<pref>",{type,value}] per line
# to stdout for the receipt and writes nothing. In "set"/"unset" mode it writes
# and reports progress on stderr. A JSON line cannot be corrupted by a value
# containing a separator or a newline, which the old "key|value" record could.
JSON_FAILURES=0

profile_pref_files() {
  local d
  for d in "${USER_DATA}/Default" "${USER_DATA}"/Profile\ *; do
    [[ -f "${d}/Preferences" ]] && echo "${d}/Preferences"
  done
  # An unmatched "Profile *" glob leaves the last test failing, and a caller
  # doing `files=$(profile_pref_files)` would then die under `set -e`. Finding
  # no extra profiles is a normal result, not an error.
  return 0
}

edit_json_file() {
  local mode="$1" file="$2" pairs="$3" rc=0
  as_user /usr/bin/env MODE="$mode" PAIRS="$pairs" python3 - "$file" <<'PY' || rc=$?
import json, os, sys, tempfile

path  = sys.argv[1]
mode  = os.environ["MODE"]
pairs = [p for p in os.environ["PAIRS"].split("\n") if p.strip()]

def die(msg):
    print(f"    ! {os.path.basename(path)}: {msg}", file=sys.stderr)
    sys.exit(1)

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as exc:
    die(f"unreadable, left untouched ({exc})")

MISSING = object()          # a pref set to JSON null is not a pref that is absent

def get_path(root, dotted):
    node = root
    for k in dotted.split("."):
        if not isinstance(node, dict) or k not in node:
            return MISSING
        node = node[k]
    return node

def describe(prior):
    if prior is MISSING:
        return {"type": "absent"}
    if isinstance(prior, bool):   kind = "boolean"
    elif prior is None:           kind = "null"
    elif isinstance(prior, (int, float)): kind = "number"
    elif isinstance(prior, str):  kind = "string"
    elif isinstance(prior, list): kind = "array"
    else:                         kind = "object"
    return {"type": kind, "value": prior}

def set_path(root, dotted, value):
    node, parts = root, dotted.split(".")
    for k in parts[:-1]:
        if not isinstance(node.get(k), dict):
            node[k] = {}
        node = node[k]
    node[parts[-1]] = value

def unset_path(root, dotted):
    parts, stack, node = dotted.split("."), [], root
    for k in parts[:-1]:
        if not isinstance(node, dict) or k not in node:
            return
        stack.append((node, k)); node = node[k]
    if isinstance(node, dict):
        node.pop(parts[-1], None)
    for parent, key in reversed(stack):          # drop containers left empty
        if isinstance(parent.get(key), dict) and not parent[key]:
            del parent[key]

label = os.path.join(os.path.basename(os.path.dirname(path)), os.path.basename(path))

priors, changed, refused = [], 0, 0
for pair in pairs:
    name, _, raw = pair.partition("|")
    prior = get_path(data, name)
    record = describe(prior)
    priors.append(json.dumps([path, name, record]))
    if mode == "read":
        continue
    if record["type"] in ("object", "array"):
        # Overwriting it would destroy a value no rollback could rebuild, and
        # the boolean this pref wants is not a substitute for a container.
        print(f"    ! {label}: {name} holds a JSON {record['type']};"
              " left untouched", file=sys.stderr)
        refused += 1
        continue
    if mode == "set":
        want = raw == "true"
        # `prior == want` alone would treat a stored 1 as already-true, since
        # Python compares 1 == True. The type has to match as well.
        if not (isinstance(prior, bool) and prior == want):
            set_path(data, name, want); changed += 1
    else:
        if prior is not MISSING:
            unset_path(data, name); changed += 1

if mode == "read":
    for p in priors:
        print(p)
    sys.exit(0)

if changed:
    tmp = None
    try:
        st = os.stat(path)
        # mkstemp: random name, O_CREAT|O_EXCL|O_NOFOLLOW-equivalent, mode 0600.
        # A predictable temp name in a user-writable directory is plantable.
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path),
                                   prefix=".origin-", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, separators=(",", ":"))
            fh.flush(); os.fsync(fh.fileno())
        os.chmod(tmp, st.st_mode & 0o7777)   # these files are 0600
        os.replace(tmp, path)
        dfd = os.open(os.path.dirname(path), os.O_RDONLY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    except OSError as exc:
        if tmp:
            try: os.unlink(tmp)
            except OSError: pass
        die(f"write failed, left untouched ({exc})")

verb = "written" if mode == "set" else "cleared"
print(f"    {label}: {changed} pref(s) {verb}", file=sys.stderr)
sys.exit(1 if refused else 0)
PY
  return $rc
}

# ── Receipt ──────────────────────────────────────────────────────────────────
# The schema every reader and writer agrees on. A receipt that parses but has no
# policies_prior is worse than no receipt at all: deactivate would find nothing
# to restore, count no failures, and then delete the file — so validate on the
# way in and on the way out.
RECEIPT_SCHEMA_CHECK='
def validate(rec):
    if not isinstance(rec, dict):
        raise ValueError("receipt is not a JSON object")
    for field, kind in (("plist", str), ("policies_prior", dict),
                        ("prefs_prior", dict)):
        if field not in rec:
            raise ValueError(f"receipt is missing \"{field}\"")
        if not isinstance(rec[field], kind):
            raise ValueError(f"receipt field \"{field}\" has the wrong type")
    return rec
'

receipt_write() {
  local payload="$1"
  PAYLOAD="$payload" python3 -c "
import json, os, sys
${RECEIPT_SCHEMA_CHECK}
try:
    validate(json.loads(os.environ['PAYLOAD']))
except ValueError as exc:
    sys.exit(str(exc))
" || err "Refusing to write a malformed receipt to ${RECEIPT}."

  mkdir -p "$RECEIPT_DIR"; chown root:wheel "$RECEIPT_DIR" 2>/dev/null || true
  chmod 755 "$RECEIPT_DIR" 2>/dev/null || true
  # Atomic: a truncating `>` that fails partway would destroy the only record
  # of the priors, which is exactly the loss the receipt exists to prevent.
  local tmp
  tmp=$(mktemp "${RECEIPT_DIR}/.receipt.XXXXXX") || err "Could not write ${RECEIPT}."
  printf '%s\n' "$payload" > "$tmp" || { rm -f "$tmp"; err "Could not write ${RECEIPT}."; }
  chown root:wheel "$tmp" 2>/dev/null || true
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$RECEIPT" || { rm -f "$tmp"; err "Could not write ${RECEIPT}."; }
}

# Validate a receipt in full and print its plist path and state, one per line.
# Every other reader in deactivate runs after this one has passed.
receipt_load() {
  RC="$1" python3 -c "
import json, os, sys
${RECEIPT_SCHEMA_CHECK}
path = os.environ['RC']
try:
    with open(path, encoding='utf-8') as fh:
        rec = validate(json.load(fh))
except (OSError, ValueError) as exc:
    sys.exit(str(exc))
print(rec['plist'])
print(rec.get('state', 'complete'))
"
}

receipt_summary() {
  RC="$1" python3 -c "
import json, os
rec = json.load(open(os.environ['RC'], encoding='utf-8'))
print(f\"{rec.get('scope', '?')} scope · {rec.get('state', 'complete')} · {rec.get('plist', '?')}\")
" 2>/dev/null || echo "unreadable"
}

device_is_managed() {
  local enr ad
  enr=$(profiles status -type enrollment 2>/dev/null || true)
  grep -q "MDM enrollment: Yes" <<< "$enr" && return 0
  # `dscl -list "/Active Directory"` exits 0 with empty output when the node is
  # absent, so test the output rather than the status.
  ad=$(dscl localhost -list "/Active Directory" 2>/dev/null || true)
  [[ -n "$ad" ]]
}

installed_version() {
  defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown"
}

# ── ACTIVATE ─────────────────────────────────────────────────────────────────
# The order here is the design: read every prior value, write the receipt, and
# only then touch anything. Mutating first meant that any abort before the
# receipt was written left the machine changed with no record of what it had
# been, and deactivate then refused to run at all.
activate_interrupted() {
  trap - INT TERM HUP        # a second signal must not re-enter this handler
  echo
  warn "Interrupted. The receipt is intact at:"
  echo "      ${RECEIPT}"
  warn "Roll back what did land with:"
  echo "      ${SELF_CMD} deactivate --channel ${BUNDLE_ID}${SCOPE_FLAG}"
  exit 130
}

# Keys whose prior value cannot be put back exactly, as "<key>\t<reason>" lines.
REFUSED_PRIORS=""
refusal_reason() {
  local rkey reason
  while IFS=$'\t' read -r rkey reason; do
    [[ "$rkey" == "$1" ]] && { echo "$reason"; return 0; }
  done <<< "$REFUSED_PRIORS"
  return 0
}

# Set when the payload absorbed a pre-scope-split receipt for this same plist,
# so finalize can drop it. Two receipts describing one plist is the bug this
# whole split exists to avoid.
RECEIPT_MIGRATED_LEGACY=0

# The earlier receipt whose priors this run must keep, or "" for none. Decided
# in the caller rather than in receipt_build, which runs in a command
# substitution where a variable it set would be discarded with the subshell.
prior_receipt() {
  if [[ -f "$RECEIPT" ]]; then
    echo "$RECEIPT"
  elif [[ -f "$LEGACY_RECEIPT" ]] && legacy_receipt_matches; then
    echo "$LEGACY_RECEIPT"
  fi
}

receipt_build() {
  local priors_file="$1" pref_priors="$2" state="$3" existing="$4"
  POLJSON="$priors_file" PREFS="$pref_priors" EXISTING="$existing" \
  STATE="$state" PLIST_P="$PLIST" SCOPE_P="$SCOPE" BID="$BUNDLE_ID" \
  VER="$(installed_version)" python3 - <<'PY'
import json, os, sys, time

with open(os.environ["POLJSON"], encoding="utf-8") as fh:
    pol = json.load(fh)

prefs = {}
# A pref whose prior is a container is one the writer refuses to touch, so the
# receipt must not claim it either: deactivate would then refuse to restore a
# value that was never overwritten.
RESTORABLE = {"absent", "boolean", "string", "number", "null"}
for line in os.environ["PREFS"].splitlines():
    if not line.strip():
        continue
    path, name, record = json.loads(line)
    if record.get("type") in RESTORABLE:
        prefs.setdefault(path, {})[name] = record

# Re-running activate must not overwrite the ORIGINAL prior values with the
# values the previous run installed, or deactivate would only roll back to the
# last run instead of to the untouched machine. Earliest record wins.
old_receipt = os.environ.get("EXISTING", "")
if old_receipt and os.path.isfile(old_receipt):
    try:
        with open(old_receipt, encoding="utf-8") as fh:
            prev = json.load(fh)
        for k, v in prev.get("policies_prior", {}).items():
            pol[k] = v
        for f, kv in prev.get("prefs_prior", {}).items():
            merged = dict(kv)
            merged.update({k: v for k, v in prefs.get(f, {}).items() if k not in kv})
            prefs[f] = merged
    except (OSError, ValueError, AttributeError) as exc:
        # Skipping the merge here would record the values the PREVIOUS run
        # installed as if they were the untouched machine's, and the write that
        # follows would destroy the last copy of the real priors. Refuse.
        sys.exit(f"existing receipt {old_receipt} is unreadable: {exc}")

print(json.dumps({
    "bundle_id": os.environ["BID"], "scope": os.environ["SCOPE_P"],
    "plist": os.environ["PLIST_P"], "brave_version": os.environ["VER"],
    "written_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "state": os.environ["STATE"],
    "policies_prior": pol, "prefs_prior": prefs,
}, indent=2))
PY
}

legacy_receipt_matches() {
  local p
  p=$(receipt_load "$LEGACY_RECEIPT" 2>/dev/null | head -n 1) || return 1
  [[ "$p" == "$PLIST" ]]
}

# The receipt is written provisionally before the first mutation and marked
# complete after the last one, so a receipt that says "provisional" is itself
# the signal that a run was cut short.
receipt_finalize() {
  local payload
  payload=$(RC="$RECEIPT" python3 -c "
import json, os
rec = json.load(open(os.environ['RC'], encoding='utf-8'))
rec['state'] = 'complete'
print(json.dumps(rec, indent=2))
") || err "Could not finalize the receipt at ${RECEIPT}."
  receipt_write "$payload"
  [[ $RECEIPT_MIGRATED_LEGACY -eq 1 ]] && rm -f "$LEGACY_RECEIPT"
  return 0
}

activate_dry_run() {
  local entry key val settable note f
  section "Brave Origin policies"
  for entry in "${POLICIES[@]}"; do
    IFS="|" read -r key val settable <<< "$entry"
    note=""
    is_supported "$key" || note=" ${DIM}(inert: not in this build)${RESET}"
    skip "would set ${key} = ${val}${note}"
  done

  section "Standalone-build defaults (profile prefs)"
  while read -r f; do skip "would update ${f}"; done < <(profile_pref_files)

  section "Crash / metrics reporting (Local State)"
  skip "would update ${LOCAL_STATE}"

  section "Result"
  echo "  Dry run — no changes made."
}

cmd_activate() {
  section "Brave Origin — activating"
  info "Target : ${CHANNEL_NAME} (${BUNDLE_ID}) $(installed_version)"
  info "Policy : ${PLIST}  [${SCOPE} scope]"
  info "User   : ${TARGET_USER}"

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "Dry run — nothing will be written."
    probe_supported_keys
    activate_dry_run
    return 0
  fi

  require_brave_closed
  probe_supported_keys
  check_plist_readable

  # ── Capture ────────────────────────────────────────────────────────────────
  # Nothing below this heading writes; nothing above the receipt does either.
  section "Reading current values"
  local priors_file; priors_file=$(mktemp) || err "mktemp failed"
  REFUSED_PRIORS=$(capture_policy_priors "$PLIST" "$priors_file") || {
    rm -f "$priors_file"
    err "Could not read the existing policy values from ${PLIST}."
  }

  local pairs; pairs=$(printf '%s\n' "${PROFILE_PREFS[@]}")
  local ls_pairs; ls_pairs=$(printf '%s\n' "${LOCAL_STATE_PREFS[@]}")
  local pref_priors="" out f any=0 ls_captured=0
  local -a captured_files=()
  while read -r f; do
    any=1
    # A file whose prior could not be read is a file this run must not write:
    # capturing after the write is what made the old code unrollbackable.
    if out=$(edit_json_file read "$f" "$pairs"); then
      pref_priors+="${out}"$'\n'; captured_files+=("$f")
    else
      (( JSON_FAILURES++ )) || true
    fi
  done < <(profile_pref_files)
  [[ $any -eq 0 ]] && warn "No profile found under ${DATA_DIR}."

  if [[ -f "$LOCAL_STATE" ]]; then
    if out=$(edit_json_file read "$LOCAL_STATE" "$ls_pairs"); then
      pref_priors+="${out}"$'\n'; ls_captured=1
    else
      (( JSON_FAILURES++ )) || true
    fi
  else
    warn "Local State not found; metrics pref skipped."
  fi
  ok "${#POLICIES[@]} policy key(s) and ${#captured_files[@]} pref file(s) read"

  # ── Receipt, before the first write ────────────────────────────────────────
  local existing; existing=$(prior_receipt)
  [[ "$existing" == "$LEGACY_RECEIPT" ]] && RECEIPT_MIGRATED_LEGACY=1
  local payload
  payload=$(receipt_build "$priors_file" "$pref_priors" provisional "$existing") \
    || { rm -f "$priors_file"; err "Could not build the receipt; nothing was changed."; }
  rm -f "$priors_file"
  receipt_write "$payload"
  # Its priors are in the new receipt now. Dropping it here rather than at
  # finalize means an interrupt cannot leave two receipts for one plist.
  [[ $RECEIPT_MIGRATED_LEGACY -eq 1 ]] && rm -f "$LEGACY_RECEIPT"
  info "Receipt written before any change: ${RECEIPT}"
  trap activate_interrupted INT TERM HUP

  # ── Mutate ─────────────────────────────────────────────────────────────────
  local applied=0 inert=0 failed=0 entry key val settable note reason
  section "Brave Origin policies"
  ensure_plist
  for entry in "${POLICIES[@]}"; do
    IFS="|" read -r key val settable <<< "$entry"
    note=""
    is_supported "$key" || note=" ${DIM}(inert: not in this build)${RESET}"
    [[ -n "$note" ]] && (( inert++ )) || true

    reason=$(refusal_reason "$key")
    if [[ -n "$reason" ]]; then
      fail "${key} — left untouched: ${reason}, which cannot be restored exactly"
      (( failed++ )) || true
      continue
    fi

    if plist_set_bool_verified "$PLIST" "$key" "$val"; then
      ok "${key} = ${val} ${DIM}(${settable})${RESET}${note}"
      (( applied++ )) || true
    else
      fail "${key} — write did NOT take effect"
      (( failed++ )) || true
    fi
  done
  finalize_plist

  section "Standalone-build defaults (profile prefs)"
  for f in ${captured_files[@]+"${captured_files[@]}"}; do
    edit_json_file set "$f" "$pairs" || (( JSON_FAILURES++ )) || true
  done

  section "Crash / metrics reporting (Local State)"
  if [[ $ls_captured -eq 1 ]]; then
    edit_json_file set "$LOCAL_STATE" "$ls_pairs" || (( JSON_FAILURES++ )) || true
  else
    skip "not written (prior value was not captured)"
  fi

  receipt_finalize
  trap - INT TERM

  # Brave may have been launched while we were writing; its in-memory copy
  # would overwrite the JSON edits on exit.
  brave_running && \
    warn "${CHANNEL_NAME} started during this run — re-run activate after quitting it."

  section "Result"
  echo "  Policies written : ${applied} / ${#POLICIES[@]}"
  [[ $inert   -gt 0 ]] && echo "  Inert this build : ${inert} ${DIM}(written, ignored until Brave ships them)${RESET}"
  [[ $failed  -gt 0 ]] && echo "  ${RED}Failed writes    : ${failed}${RESET}"
  [[ $JSON_FAILURES -gt 0 ]] && echo "  ${RED}Pref files failed: ${JSON_FAILURES}${RESET}"
  echo "  Receipt          : ${RECEIPT}"
  echo
  if [[ $failed -gt 0 || $JSON_FAILURES -gt 0 ]]; then
    echo "  ${RED}${BOLD}Incomplete.${RESET} Fix the errors above and re-run."
    echo "  ${DIM}The receipt covers what did change; deactivate rolls it back.${RESET}"
    return 1
  fi
  echo "  ${BOLD}Restart ${CHANNEL_NAME}${RESET} — all policies are dynamic_refresh:false."
  echo "  Verify at brave://policy"
  return 0
}

# ── DEACTIVATE ───────────────────────────────────────────────────────────────
# Which receipt this run acts on. The scoped name first; a pre-split
# "<bundle>.json" second, honoured as whichever scope its own "plist" field
# names rather than as the scope on this command line.
select_receipt() {
  [[ -f "$RECEIPT" ]] && { echo "$RECEIPT"; return 0; }
  [[ -f "$LEGACY_RECEIPT" ]] && { echo "$LEGACY_RECEIPT"; return 0; }
  return 1
}

# One "<key>\0<type>\0<value>\0" record per policy key. NUL separation because a
# prior value is arbitrary text: the old "key|value" lines were truncated by a
# value containing "|" and lost entirely by one containing a newline.
receipt_policy_records() {
  RC="$1" python3 - <<'PY'
import json, os, sys

with open(os.environ["RC"], encoding="utf-8") as fh:
    rec = json.load(fh)
out = sys.stdout.buffer

def normalise(value):
    if isinstance(value, dict):                 # typed record
        return value.get("type", "untyped"), value.get("value", "")
    # Pre-typed receipt: PlistBuddy's rendering with no type beside it. Only
    # "ABSENT" and a plain boolean can be honoured — anything else would be a
    # guess at the original type, and guessing is the defect this replaced.
    if isinstance(value, str):
        if value == "ABSENT":
            return "absent", ""
        if value in ("true", "false"):
            return "bool", value
    return "untyped", value

for key, value in rec["policies_prior"].items():
    ktype, val = normalise(value)
    for field in (key, str(ktype), str(val)):
        out.write(field.encode("utf-8"))
        out.write(b"\0")
PY
}

# "a dictionary" / "an untyped value ..." — the untyped case only arises from a
# receipt written before priors carried their type.
prior_noun() {
  if [[ "$1" == "untyped" ]]; then echo "an untyped value from an older receipt"
  else echo "a $1"; fi
}

cmd_deactivate() {
  section "Brave Origin — deactivating"
  info "Target : ${CHANNEL_NAME} (${BUNDLE_ID})"

  RECEIPT=$(select_receipt) || err "No receipt at ${RECEIPT}.
    Without it this script cannot tell its own policy keys from those written by
    an MDM profile or another tool, and it will not guess. If you applied these
    by hand, remove them by hand."

  # Validate the whole schema once, here. The old reader swallowed every error,
  # so a receipt missing policies_prior produced an empty loop, a zero failure
  # count, and then deletion of the only record of what to roll back to.
  local meta rec_plist rec_state
  meta=$(receipt_load "$RECEIPT") \
    || err "Receipt at ${RECEIPT} is unusable (see above). Refusing to guess."
  { read -r rec_plist; read -r rec_state; } <<< "$meta"

  [[ $DRY_RUN -eq 0 ]] && require_brave_closed
  [[ $DRY_RUN -eq 1 ]] && warn "Dry run — nothing will be written."

  info "Receipt: ${RECEIPT}"
  info "Plist  : ${rec_plist}"
  [[ "$rec_state" == "complete" ]] || \
    warn "That receipt is ${rec_state}: an activate run was cut short. Rolling back what it recorded."

  # Restore prefs FIRST. If anything below fails, the user-visible browser
  # settings are already back rather than stranded.
  local pref_failed=0
  section "Restoring prefs"
  if [[ $DRY_RUN -eq 1 ]]; then
    skip "would restore prefs recorded in the receipt"
  else
    as_user /usr/bin/env RC="$RECEIPT" python3 - <<'PY' || pref_failed=$?
import json, os, sys, tempfile

# Types a JSON pref can be put back as exactly. A dict or a list has no
# faithful scalar substitute, so those are refused rather than approximated.
RESTORABLE = {"boolean", "string", "number", "null"}

with open(os.environ["RC"], encoding="utf-8") as fh:
    rec = json.load(fh)

def normalise(record):
    if isinstance(record, dict):                # typed record
        return record.get("type", "untyped"), record.get("value")
    if isinstance(record, str):                 # pre-typed receipt
        if record == "ABSENT":
            return "absent", None
        if record in ("true", "false"):
            return "boolean", record == "true"
    return "untyped", None

def unset(root, dotted):
    parts, stack, node = dotted.split("."), [], root
    for k in parts[:-1]:
        if not isinstance(node, dict) or k not in node: return
        stack.append((node, k)); node = node[k]
    if isinstance(node, dict): node.pop(parts[-1], None)
    for parent, key in reversed(stack):          # drop containers left empty
        if isinstance(parent.get(key), dict) and not parent[key]: del parent[key]

def setp(root, dotted, value):
    node, parts = root, dotted.split(".")
    for k in parts[:-1]:
        if not isinstance(node.get(k), dict): node[k] = {}
        node = node[k]
    node[parts[-1]] = value

failures = 0
for path, prefs in rec["prefs_prior"].items():
    if not os.path.isfile(path):
        # The profile is gone, so there is nothing left to restore. Counting it
        # as a failure would keep the receipt forever and make every later
        # deactivate exit non-zero.
        print(f"    - gone, nothing to restore: {path}"); continue
    try:
        with open(path, encoding="utf-8") as fh: data = json.load(fh)
    except Exception as exc:
        print(f"    ! unreadable, skipped: {path} ({exc})"); failures += 1; continue

    restored = 0
    for name, record in prefs.items():
        kind, value = normalise(record)
        if kind == "absent":
            unset(data, name)
        elif kind in RESTORABLE:
            setp(data, name, value)
        else:
            noun = "an untyped value" if kind == "untyped" else f"a {kind}"
            print(f"    ! {name}: recorded prior is {noun}; left as it is")
            failures += 1
            continue
        restored += 1

    tmp = None
    try:
        st = os.stat(path)
        # mkstemp: random name, O_CREAT|O_EXCL|O_NOFOLLOW-equivalent, mode 0600.
        # A predictable temp name in a user-writable directory is plantable.
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path),
                                   prefix=".origin-", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, separators=(",", ":"))
            fh.flush(); os.fsync(fh.fileno())
        os.chmod(tmp, st.st_mode & 0o7777)   # these files are 0600
        os.replace(tmp, path)
        dfd = os.open(os.path.dirname(path), os.O_RDONLY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    except OSError as exc:
        # Uncaught, this aborted the whole script under `set -e` before a single
        # policy key had been touched.
        if tmp:
            try: os.unlink(tmp)
            except OSError: pass
        print(f"    ! write failed, left untouched: {path} ({exc})")
        failures += 1
        continue

    label = os.path.join(os.path.basename(os.path.dirname(path)), os.path.basename(path))
    print(f"    {label}: {restored} pref(s) restored")

sys.exit(min(failures, 100))
PY
    [[ $pref_failed -gt 0 ]] && fail "${pref_failed} pref restore(s) failed"
  fi

  section "Removing policies"
  local removed=0 restored=0 pol_failed=0
  local key ktype val
  if [[ ! -f "$rec_plist" ]]; then
    warn "Policy file already gone: ${rec_plist}"
  elif ! plist_parses "$rec_plist"; then
    err "${rec_plist} is not a valid plist. Refusing to modify or delete it."
  else
    while IFS= read -r -d '' key && IFS= read -r -d '' ktype && IFS= read -r -d '' val; do
      [[ -z "$key" ]] && continue
      if [[ $DRY_RUN -eq 1 ]]; then
        if [[ "$ktype" == "absent" ]]; then
          skip "would remove ${key}"
        elif plist_type_is_restorable "$ktype"; then
          skip "would restore ${key} = ${val} (${ktype})"
        else
          skip "would refuse ${key}: recorded prior is $(prior_noun "$ktype")"
        fi
        continue
      fi
      if [[ "$ktype" == "absent" ]]; then
        if plist_delete_verified "$rec_plist" "$key"; then
          ok "removed ${key}"; (( removed++ )) || true
        else
          fail "could not remove ${key}"; (( pol_failed++ )) || true
        fi
      elif plist_type_is_restorable "$ktype"; then
        if plist_restore_verified "$rec_plist" "$key" "$ktype" "$val"; then
          ok "restored ${key} = ${val} ${DIM}(pre-existing ${ktype})${RESET}"
          (( restored++ )) || true
        else
          fail "could not restore ${key} = ${val} (${ktype})"; (( pol_failed++ )) || true
        fi
      else
        # No substitute value gets written here: putting a dict back as a
        # boolean destroys it, and reporting success would hide that.
        fail "${key} — recorded prior is $(prior_noun "$ktype"); refusing to substitute a value. Left as it is."
        (( pol_failed++ )) || true
      fi
    done < <(receipt_policy_records "$RECEIPT")

    if [[ $DRY_RUN -eq 0 ]]; then
      local left; left=$(plist_key_count "$rec_plist")
      if [[ "$left" -eq 0 ]]; then
        rm -f "$rec_plist"; ok "policy file removed (no keys left)"
      else
        # Distinguish keys we put back at their pre-existing values from keys
        # that were never ours; calling both "not ours" reads like a failure.
        local foreign=$(( left - restored ))
        if [[ $restored -gt 0 && $foreign -gt 0 ]]; then
          warn "${left} key(s) remain: ${restored} restored to pre-existing values, ${foreign} unrelated:"
        elif [[ $restored -gt 0 ]]; then
          warn "${left} key(s) remain, all restored to the values they had before this script ran:"
        else
          warn "${left} unrelated key(s) left untouched:"
        fi
        pb -c "Print" "$rec_plist" 2>/dev/null | grep " = " | sed 's/^/      /' || true
      fi
      killall cfprefsd 2>/dev/null || true
    fi
  fi

  # Outside the block above on purpose: an already-deleted plist is not a reason
  # to keep a receipt forever, and a skipped pref restore IS a reason to keep it.
  if [[ $DRY_RUN -eq 0 ]]; then
    if [[ $pol_failed -eq 0 && $pref_failed -eq 0 ]]; then
      rm -f "$RECEIPT"; ok "receipt cleared"
    else
      warn "Receipt kept at ${RECEIPT}: ${pol_failed} policy and ${pref_failed} pref restore(s) failed."
    fi
  fi

  # Other receipts this run did not touch: the other scope for this channel,
  # and any other channel.
  local other_note="" r
  for r in "${RECEIPT_DIR}/${BUNDLE_ID}.user.json" "${RECEIPT_DIR}/${BUNDLE_ID}.machine.json"; do
    [[ "$r" == "$RECEIPT" || ! -f "$r" ]] && continue
    warn "Still active in the other scope: ${r} (re-run with the matching --machine)"
  done
  for i in "${FOUND_IDX[@]}"; do
    [[ "${CH_ID[$i]}" == "$BUNDLE_ID" ]] && continue
    for r in "${RECEIPT_DIR}/${CH_ID[$i]}.user.json" \
             "${RECEIPT_DIR}/${CH_ID[$i]}.machine.json" \
             "${RECEIPT_DIR}/${CH_ID[$i]}.json"; do
      [[ -f "$r" ]] && { other_note+=" ${CH_ID[$i]}"; break; }
    done
  done
  [[ -n "$other_note" ]] && \
    warn "Still active on other channels (re-run with --channel):${other_note}"

  section "Result"
  echo "  Policy keys      : ${removed} removed, ${restored} restored to prior values"
  [[ $pol_failed -gt 0 || $pref_failed -gt 0 ]] && \
    echo "  ${RED}Failures${RESET}         : ${pol_failed} polic(y/ies), ${pref_failed} pref file(s) — receipt kept"
  echo "  ${BOLD}Restart ${CHANNEL_NAME}.${RESET}"
  [[ $pol_failed -gt 0 || $pref_failed -gt 0 ]] && return 1
  return 0
}

# ── STATUS ───────────────────────────────────────────────────────────────────
cmd_status() {
  section "Brave Origin — status"
  local ver; ver=$(installed_version)
  info "Target : ${CHANNEL_NAME} (${BUNDLE_ID}) ${ver}"
  [[ "$ver" == "$VALIDATED_AGAINST" ]] || \
    warn "Policy set last verified against ${VALIDATED_AGAINST}; this is ${ver}. Re-check for new Origin policies."

  probe_supported_keys
  local managed="no"; device_is_managed && managed="yes"

  # Every receipt for this channel, both scopes and the pre-split name. One of
  # them missing from this list is a plist nothing can roll back.
  local r found_receipt=0
  for r in "${RECEIPT_DIR}/${BUNDLE_ID}.user.json" \
           "${RECEIPT_DIR}/${BUNDLE_ID}.machine.json" "$LEGACY_RECEIPT"; do
    [[ -f "$r" ]] || continue
    found_receipt=1
    info "Receipt: ${r} ${DIM}($(receipt_summary "$r"))${RESET}"
  done
  [[ $found_receipt -eq 0 ]] && \
    warn "No receipt — deactivate will refuse to run until activate creates one."

  # Report BOTH scopes: a stale copy at the other path enforces policy silently.
  local p label
  for p in "$USER_PLIST" "$MACHINE_PLIST"; do
    [[ "$p" == "$USER_PLIST" ]] && label="user scope" || label="machine scope"
    section "Policies — ${p} ${DIM}(${label})${RESET}"
    if [[ ! -f "$p" ]]; then
      skip "file does not exist"
      continue
    fi
    if ! plist_parses "$p"; then
      fail "not a valid plist — cannot report on it"
      continue
    fi
    local active=0 missing=0 inert=0 entry key want cur ktype effect colour
    printf "  %-30s %-8s %-9s %s\n" "KEY" "WANT" "IN FILE" "EFFECT"
    for entry in "${POLICIES[@]}"; do
      IFS="|" read -r key want _ <<< "$entry"
      # Report the type where it is not a boolean: Brave's schema rejects a
      # string "true", and printing the bare value would call that enforced.
      ktype=$(plist_key_type "$p" "$key")
      case "$ktype" in
        "")   cur="(unset)" ;;
        bool) cur=$(plist_raw "$p" "$key") ;;
        *)    cur="(${ktype})" ;;
      esac
      if ! is_supported "$key"; then
        effect="inert (not in build)"; colour="$DIM"; (( inert++ )) || true
      elif [[ "$cur" == "$want" ]]; then
        effect="enforced"; colour="$GREEN"; (( active++ )) || true
      else
        effect="not applied"; colour="$RED"; (( missing++ )) || true
      fi
      printf "  ${colour}%-30s %-8s %-9s %s${RESET}\n" "$key" "$want" "$cur" "$effect"
    done
    echo "  ${DIM}enforced ${active} · not applied ${missing} · inert ${inert}${RESET}"
  done

  section "Profile prefs"
  # Same profile selection as the writer, or every run reports a false negative
  # for the profiles the writer deliberately skips (System Profile, Guest).
  local files; files=$(profile_pref_files)
  for entry in "${PROFILE_PREFS[@]}"; do
    IFS="|" read -r name want <<< "$entry"
    as_user /usr/bin/env NAME="$name" WANT="$want" FILES="$files" python3 <<'PY'
import json, os
name, want = os.environ["NAME"], os.environ["WANT"]
hits, good = [], True
paths = [p for p in os.environ["FILES"].split("\n") if p.strip()]
for p in paths:
    try: d = json.load(open(p, encoding="utf-8"))
    except Exception: hits.append(f"{os.path.basename(os.path.dirname(p))}=unreadable"); good = False; continue
    node = d
    for k in name.split("."):
        node = node.get(k) if isinstance(node, dict) else None
        if node is None: break
    got = "unset" if node is None else str(node).lower()
    if got != want: good = False
    hits.append(f"{os.path.basename(os.path.dirname(p))}={got}")
print(f"  [{'+' if paths and good else '-'}] {name} (want {want}) :: {', '.join(hits) or 'no profiles found'}")
PY
  done

  section "Local State"
  for entry in "${LOCAL_STATE_PREFS[@]}"; do
    IFS="|" read -r name want <<< "$entry"
    as_user /usr/bin/env NAME="$name" WANT="$want" LS="$LOCAL_STATE" python3 <<'PY'
import json, os
name, want, path = os.environ["NAME"], os.environ["WANT"], os.environ["LS"]
if not os.path.isfile(path):
    print(f"  [-] {name} :: Local State not found"); raise SystemExit
try: d = json.load(open(path, encoding="utf-8"))
except Exception as exc:
    print(f"  [-] {name} :: unreadable ({exc})"); raise SystemExit
node = d
for k in name.split("."):
    node = node.get(k) if isinstance(node, dict) else None
    if node is None: break
got = "unset" if node is None else str(node).lower()
print(f"  [{'+' if got == want else '-'}] {name} (want {want}) :: {got}")
PY
  done

  section "Environment"
  echo "  Device managed : ${managed} ${DIM}(sensitive policies are blocked when 'no')${RESET}"
  echo "  ${CHANNEL_NAME} running : $(brave_running && echo yes || echo no)"
  echo
  echo "  ${DIM}This reads files, not the browser. brave://policy is authoritative.${RESET}"
  return 0
}

case "$CMD" in
  activate)   cmd_activate   ;;
  deactivate) cmd_deactivate ;;
  status)     cmd_status     ;;
esac
