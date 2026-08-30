#!/usr/bin/env bash
# =============================================================================
# Brave to Origin — one-shot installer
# =============================================================================
#
#   curl -fsSL https://raw.githubusercontent.com/mdrubelamin2/brave-to-origin/main/install.sh | sudo bash
#
# Fetches origin.sh at a pinned tag, verifies its SHA-256, and runs it. Nothing
# is left behind: the script is downloaded to a temp file and deleted after.
# The receipt it writes lives outside all of this — /Library/Application Support
# on macOS, /var/lib on Linux — so a later `deactivate` needs none of it.
#
# Non-interactive form, for scripts and CI:
#   ... | sudo bash -s -- activate
#   ... | sudo bash -s -- status --channel com.brave.Browser.beta
#
# ENV OVERRIDES (testing)
#   ORIGIN_REF     git ref to fetch instead of the pinned tag
#   ORIGIN_SHA256  expected checksum, or "skip" to bypass verification
#   ORIGIN_SOURCE  local file or URL to use instead of downloading
# =============================================================================

set -euo pipefail

REPO="mdrubelamin2/brave-to-origin"
# Pinned, not a moving branch: piping a URL to root should not mean "whatever
# that branch says today". Bump both together when cutting a release.
PINNED_REF="v1.2.3"
PINNED_SHA256="0760d69f427029b04a7a9518bb6407918768b7d91320493d34138977787a6880"

REF="${ORIGIN_REF:-$PINNED_REF}"
EXPECTED_SHA="${ORIGIN_SHA256:-$PINNED_SHA256}"
SOURCE="${ORIGIN_SOURCE:-https://raw.githubusercontent.com/${REPO}/${REF}/origin.sh}"

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; BOLD=""; RESET=""
fi
info() { echo "${CYAN}[*]${RESET} $*"; }
ok()   { echo "${GREEN}[+]${RESET} $*"; }
warn() { echo "${YELLOW}[!]${RESET} $*"; }
err()  { echo "${RED}[x]${RESET} $*" >&2; exit 1; }

CURL_CMD="curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash"

# ── Guards ───────────────────────────────────────────────────────────────────
# The two desktop platforms whose policy store is a file. Windows keeps its in
# the registry, which neither this nor origin.sh writes.
case "$(uname -s)" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *) err "Unsupported platform: $(uname -s). This supports macOS and Linux." ;;
esac

# Snap confines Brave with an AppArmor profile whose browser_support abstraction
# whitelists only /etc/opt/chrome and /etc/chromium, so a policy file under
# /etc/brave would be written successfully and then never read.
SNAP_BRAVE="/snap/brave/current/opt/brave.com/brave/brave"

# Piping to `bash` rather than `sudo bash` is the likeliest mistake, and it
# fails deep inside origin.sh rather than here, so catch it up front.
[[ "$EUID" -eq 0 ]] || err "Needs root: the policy store is under /Library on macOS, /etc on Linux.
    Re-run as: ${CURL_CMD}"

# sudo exports SUDO_USER; without it there is no way to know whose profile and
# whose per-user policy path to target, and root's own are the wrong answer.
[[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] || \
  err "Run this through sudo from your own account, not as root directly.
    ${CURL_CMD}"

command -v curl >/dev/null 2>&1 || err "curl not found."
# coreutils ships sha256sum and a minimal Fedora, Arch or Alpine has no shasum
# at all; macOS is the other way round. Pick whichever is here, once.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  err "Neither sha256sum nor shasum found; cannot verify the download."
fi

echo
echo "${BOLD}Brave to Origin${RESET} ${DIM}— ${REPO} @ ${REF}${RESET}"
echo

# ── Which Brave is installed ─────────────────────────────────────────────────
# Kept in step with origin.sh's own table. Order matters: the first match is the
# default, and a real Brave beats the Origin standalone build, whose features
# are compiled out and so cannot be governed by policy.
CH_NAME=("Brave (stable)" "Brave Beta" "Brave Nightly" "Brave Dev" "Brave Origin standalone")
CH_APP=("/Applications/Brave Browser.app" "/Applications/Brave Browser Beta.app" \
        "/Applications/Brave Browser Nightly.app" "/Applications/Brave Browser Dev.app" \
        "/Applications/Brave Origin.app")
CH_ID=("com.brave.Browser" "com.brave.Browser.beta" "com.brave.Browser.nightly" \
       "com.brave.Browser.dev" "com.brave.Browser.origin")
CH_PKG=("" "" "" "" "")

# Linux ships no dev channel and no Origin standalone. The IDs are reused as
# channel names so --channel reads the same on both platforms.
if [[ "$PLATFORM" == "linux" ]]; then
  CH_NAME=("Brave (stable)" "Brave Beta" "Brave Nightly")
  CH_APP=("/opt/brave.com/brave/brave" "/opt/brave.com/brave-beta/brave" \
          "/opt/brave.com/brave-nightly/brave")
  CH_ID=("com.brave.Browser" "com.brave.Browser.beta" "com.brave.Browser.nightly")
  CH_PKG=("brave-browser" "brave-browser-beta" "brave-browser-nightly")
  # Flatpak reaches the host's /etc/brave policies (--filesystem=host-etc, and
  # brave.sh symlinks them at launch), so it is a supported target.
  # $HOME is root's under sudo; the per-user Flatpak install is under the
  # invoking user's home, which the password database is the only honest source
  # for.
  # `|| true`: getent is absent from minimal containers, and exits 2 when the
  # user is unknown. Under `set -e` either would abort the installer silently;
  # the default below is already the answer for "no home found".
  USER_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
  for fp in "/var/lib/flatpak/app/com.brave.Browser" \
            "${USER_HOME:-/nonexistent}/.local/share/flatpak/app/com.brave.Browser"; do
    [[ -d "$fp" ]] || continue
    CH_NAME+=("Brave (Flatpak)"); CH_APP+=("$fp")
    CH_ID+=("com.brave.Browser.flatpak"); CH_PKG+=("")
    break
  done
fi

FOUND_IDX=()
for i in "${!CH_APP[@]}"; do
  [[ -e "${CH_APP[$i]}" ]] && FOUND_IDX+=("$i")
done
if [[ ${#FOUND_IDX[@]} -eq 0 ]]; then
  [[ "$PLATFORM" == "macos" ]] && err "No Brave install found in /Applications."
  [[ -e "$SNAP_BRAVE" ]] && err "Only the snap build of Brave is installed, and policies cannot reach it.
    Its AppArmor profile allows reading policies from /etc/opt/chrome and
    /etc/chromium only, so anything written to /etc/brave/policies would be
    ignored. Install the .deb/.rpm from brave.com, or the Flatpak, and re-run."
  err "No Brave install found under /opt/brave.com."
fi
[[ "$PLATFORM" == "linux" && -e "$SNAP_BRAVE" ]] && \
  warn "A snap Brave is also installed. Policies cannot reach it."

app_version() {
  local v
  if [[ "$PLATFORM" == "macos" ]]; then
    v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          "${1}/Contents/Info.plist" 2>/dev/null) || v=""
  else
    # Same order origin.sh uses: package database first, the binary second.
    # A Debian version carries an epoch and a revision Brave's own does not.
    v=""
    if [[ -n "$2" ]] && command -v dpkg-query >/dev/null 2>&1; then
      v=$(dpkg-query -W -f='${Version}' "$2" 2>/dev/null || true)
      v="${v#*:}"; v="${v%%-*}"
    fi
    if [[ -z "$v" && -n "$2" ]] && command -v rpm >/dev/null 2>&1; then
      v=$(rpm -q --qf '%{VERSION}' "$2" 2>/dev/null || true)
    fi
    if [[ -z "$v" && -f "$1" && -x "$1" ]]; then
      v=$(sudo -u "$SUDO_USER" "$1" --product-version 2>/dev/null || true)
    fi
  fi
  # PlistBuddy reports a missing file on stdout, not stderr, so an unfiltered
  # fallback prints its error as if it were the version.
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] && echo "$v" || echo "unknown"
}

echo "${BOLD}Installed:${RESET}"
for i in "${FOUND_IDX[@]}"; do
  printf '  %-26s %s\n' "${CH_NAME[$i]}" "$(app_version "${CH_APP[$i]}" "${CH_PKG[$i]}")"
done
echo

# ── Choose action and channel ────────────────────────────────────────────────
# Arguments win. Otherwise ask, reading from the terminal rather than stdin,
# which is the pipe carrying this script.
ACTION=""; CHANNEL=""; PASSTHRU=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    activate|deactivate|status) ACTION="$1"; shift ;;
    --channel) [[ $# -ge 2 ]] || err "--channel needs a bundle ID."
               CHANNEL="$2"; shift 2 ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

have_tty() { exec 3</dev/tty 2>/dev/null && exec 3<&-; }

need_tty() {
  have_tty || err "No terminal to prompt on, so I cannot ask which ${1}.
    Pass it instead:
    ${CURL_CMD} -s -- activate --channel com.brave.Browser"
}

ask() { # ask <prompt> <max> -> echoes the chosen number
  local prompt="$1" max="$2" reply
  while true; do
    printf '%s' "$prompt" > /dev/tty
    read -r reply < /dev/tty || { echo >/dev/tty; err "Cancelled."; }
    [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= max )) && { echo "$reply"; return 0; }
    echo "  Enter a number between 1 and ${max}." > /dev/tty
  done
}

if [[ -z "$ACTION" ]]; then
  need_tty "action"
  echo "${BOLD}What would you like to do?${RESET}"
  echo "  1) activate    apply the Brave Origin policy set"
  echo "  2) deactivate  undo it, using the receipt activate wrote"
  echo "  3) status      report what is applied, change nothing"
  echo
  action_choice=$(ask "  Choice [1-3]: " 3)
  case "$action_choice" in
    1) ACTION="activate" ;; 2) ACTION="deactivate" ;; 3) ACTION="status" ;;
  esac
  echo
fi

if [[ -z "$CHANNEL" ]]; then
  if [[ ${#FOUND_IDX[@]} -eq 1 ]]; then
    CHANNEL="${CH_ID[${FOUND_IDX[0]}]}"
    info "Targeting ${CH_NAME[${FOUND_IDX[0]}]} ${DIM}(the only install found)${RESET}"
  else
    need_tty "install to target"
    echo "${BOLD}Which install?${RESET}"
    n=0
    for i in "${FOUND_IDX[@]}"; do n=$(( n + 1 )); echo "  ${n}) ${CH_NAME[$i]}"; done
    echo
    channel_choice=$(ask "  Choice [1-${n}]: " "$n")
    CHANNEL="${CH_ID[${FOUND_IDX[$(( channel_choice - 1 ))]}]}"
    echo
  fi
fi

# ── Fetch and verify ─────────────────────────────────────────────────────────
TMP=$(mktemp -d) || err "Could not create a temp directory."
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM HUP
SCRIPT="${TMP}/origin.sh"

if [[ -f "$SOURCE" ]]; then
  info "Using local ${SOURCE}"
  cp "$SOURCE" "$SCRIPT"
else
  info "Fetching origin.sh @ ${REF}"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$SCRIPT" "$SOURCE" \
    || err "Download failed: ${SOURCE}"
fi

ACTUAL_SHA=$(sha256_of "$SCRIPT")
# Anything that is not 64 hex characters is not a checksum: an unreplaced
# placeholder, an empty value, or an explicit "skip". Matching on the literal
# placeholder text would be fragile — a release script that rewrites it
# everywhere would disable verification without changing a visible line.
if [[ "$EXPECTED_SHA" == "skip" ]] || [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]]; then
  warn "Checksum not verified (${EXPECTED_SHA})."
  warn "SHA-256 is ${ACTUAL_SHA}"
elif [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  err "Checksum mismatch — refusing to run.
    expected ${EXPECTED_SHA}
    got      ${ACTUAL_SHA}
    Either the release moved or the download was tampered with."
else
  ok "Checksum verified"
fi

# origin.sh does its own preflight, so a corrupt-but-correctly-hashed file still
# will not run: this only catches a truncated download that somehow matched.
bash -n "$SCRIPT" || err "Downloaded script does not parse."

# ── Run it ───────────────────────────────────────────────────────────────────
echo
# Tell origin.sh how the user invoked it, so anything it prints back — the
# rollback command especially — is a command they can actually paste.
export ORIGIN_INVOCATION="${CURL_CMD} -s --"
RC=0
bash "$SCRIPT" "$ACTION" --channel "$CHANNEL" ${PASSTHRU[@]+"${PASSTHRU[@]}"} || RC=$?

if [[ $RC -eq 0 && "$ACTION" == "activate" ]]; then
  echo
  echo "${DIM}To undo this later, without cloning anything:${RESET}"
  echo "  ${CURL_CMD} -s -- deactivate --channel ${CHANNEL}"
fi
exit $RC
