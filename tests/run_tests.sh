#!/usr/bin/env bash
# Test suite for origin.sh. Runs unprivileged, touches nothing outside its own
# temp directory, and needs no Brave install. See sandbox.sh for the four seams
# it rewrites.
#
#   ./tests/run_tests.sh          # all tests
#   ./tests/run_tests.sh receipt  # only tests whose name matches
#
# Every test asserts on observable state — the plist, the profile JSON, the
# receipt, the exit status — never on log text, so wording changes do not
# break it.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source tests/sandbox.sh

FILTER="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
[[ -t 1 ]] || { GREEN=""; RED=""; DIM=""; RESET=""; }

# ── Harness ──────────────────────────────────────────────────────────────────
SBX=""; SCRIPT=""; PLIST=""; RECEIPT_DIR=""; PREFS=""; PREFS2=""; LOCAL_STATE=""

setup() {
  SBX=$(mktemp -d)
  SCRIPT=$(sandbox_build "$SBX")
  PLIST="${SBX}/Library/Managed Preferences/tester/com.brave.Browser.plist"
  RECEIPT_DIR="${SBX}/Library/Application Support/brave-origin-clone"
  local data="${SBX}/home/tester/Library/Application Support/BraveSoftware/Brave-Browser"
  PREFS="${data}/Default/Preferences"
  PREFS2="${data}/Profile 1/Preferences"
  LOCAL_STATE="${data}/Local State"
  sandbox_json "$PREFS"  '{"brave":{"other":1}}'
  sandbox_json "$PREFS2" '{"brave":{"other":2}}'
  sandbox_json "$LOCAL_STATE" '{"user_experience_metrics":{"reporting_enabled":true}}'
}
teardown() { [[ -n "$SBX" && "$SBX" == /*/* ]] && rm -rf "$SBX"; }

run() { bash "$SCRIPT" "$@" --no-color; }            # exit status preserved
run_q() { run "$@" >/dev/null 2>&1; }

# Assertions. Each prints the mismatch itself; the caller only reports pass/fail.
_fail_msg=""
assert() { # assert <condition-description> <actual> <expected>
  if [[ "$2" != "$3" ]]; then
    _fail_msg+="      $1: expected [$3], got [$2]"$'\n'; return 1
  fi
}
assert_file_exists()  { [[ -e "$1" ]] || { _fail_msg+="      missing file: $1"$'\n'; return 1; }; }
assert_file_absent()  { [[ ! -e "$1" ]] || { _fail_msg+="      file should not exist: $1"$'\n'; return 1; }; }

plist_type()  { plutil -type "$2" "$1" 2>/dev/null || echo "__absent__"; }
plist_value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || echo "__absent__"; }
json_get() { # json_get <file> <dotted.path>
  F="$1" P="$2" python3 -c '
import json, os, sys
d = json.load(open(os.environ["F"]))
for part in os.environ["P"].split("."):
    if not isinstance(d, dict) or part not in d: print("__absent__"); sys.exit()
    d = d[part]
print(json.dumps(d))'
}
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

test_case() {
  local name="$1"; shift
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return 0
  _fail_msg=""
  setup
  if "$@" && [[ -z "$_fail_msg" ]]; then
    echo "${GREEN}ok${RESET}   $name"; (( ++PASS ))
  else
    echo "${RED}FAIL${RESET} $name"; printf '%s' "$_fail_msg"
    (( ++FAIL )); FAILED_NAMES+=("$name")
  fi
  teardown
}

# ── Tests ────────────────────────────────────────────────────────────────────

t_activate_applies() {
  run_q activate
  assert_file_exists "$PLIST" || return 1
  assert "TorDisabled type"  "$(plist_type "$PLIST" TorDisabled)" "bool" || return 1
  assert "TorDisabled value" "$(plist_value "$PLIST" TorDisabled)" "true" || return 1
  assert "BraveP3AEnabled"   "$(plist_value "$PLIST" BraveP3AEnabled)" "false" || return 1
  assert "side panel pref" "$(json_get "$PREFS" brave.show_side_panel_button)" "false" || return 1
  assert "metrics pref" \
    "$(json_get "$LOCAL_STATE" user_experience_metrics.reporting_enabled)" "false" || return 1
  assert "second profile also written" \
    "$(json_get "$PREFS2" brave.show_side_panel_button)" "false" || return 1
}

t_roundtrip_restores_exactly() {
  local before_prefs before_ls before_p2
  before_prefs=$(sha "$PREFS"); before_ls=$(sha "$LOCAL_STATE"); before_p2=$(sha "$PREFS2")
  run_q activate
  run_q deactivate
  assert_file_absent "$PLIST" || return 1
  assert "Preferences byte-identical"  "$(sha "$PREFS")"       "$before_prefs" || return 1
  assert "Profile 1 byte-identical"    "$(sha "$PREFS2")"      "$before_p2" || return 1
  assert "Local State byte-identical"  "$(sha "$LOCAL_STATE")" "$before_ls" || return 1
}

t_receipt_written_and_cleared() {
  run_q activate
  assert_file_exists "${RECEIPT_DIR}/com.brave.Browser.user.json" || return 1
  run_q deactivate
  assert_file_absent "${RECEIPT_DIR}/com.brave.Browser.user.json" || return 1
}

# A prior that is not a boolean must come back with its ORIGINAL type. The old
# code rebuilt every prior as `Add :key bool <rendering>`, so a string became
# false and an integer became true.
t_restores_string_prior_with_type() {
  mkdir -p "$(dirname "$PLIST")"
  plutil -create xml1 "$PLIST" >/dev/null 2>&1 || printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$PLIST"
  plutil -insert TorDisabled -string "hello" "$PLIST"
  run_q activate
  assert "overwritten to policy value" "$(plist_value "$PLIST" TorDisabled)" "true" || return 1
  run_q deactivate
  assert "type restored" "$(plist_type "$PLIST" TorDisabled)" "string" || return 1
  assert "value restored" "$(plist_value "$PLIST" TorDisabled)" "hello" || return 1
}

t_restores_integer_prior_with_type() {
  mkdir -p "$(dirname "$PLIST")"
  plutil -create xml1 "$PLIST" >/dev/null 2>&1 || printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$PLIST"
  plutil -insert BraveP3AEnabled -integer 7 "$PLIST"
  run_q activate
  run_q deactivate
  assert "type restored" "$(plist_type "$PLIST" BraveP3AEnabled)" "integer" || return 1
  assert "value restored" "$(plist_value "$PLIST" BraveP3AEnabled)" "7" || return 1
}

# An empty string is a value, not an absence. The old existence check compared
# the printed value to "", so it deleted a key that was really there.
t_empty_string_prior_is_not_absence() {
  mkdir -p "$(dirname "$PLIST")"
  plutil -create xml1 "$PLIST" >/dev/null 2>&1 || printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$PLIST"
  plutil -insert BraveNewsDisabled -string "" "$PLIST"
  run_q activate
  run_q deactivate
  assert "key survived" "$(plist_type "$PLIST" BraveNewsDisabled)" "string" || return 1
}

# JSON prefs have the same hazard: a pref stored as the string "false" must not
# come back as the boolean false.
t_restores_string_typed_pref() {
  sandbox_json "$PREFS" '{"brave":{"show_side_panel_button":"false"}}'
  run_q activate
  assert "overwritten to boolean" "$(json_get "$PREFS" brave.show_side_panel_button)" "false" || return 1
  run_q deactivate
  assert "string type restored" "$(json_get "$PREFS" brave.show_side_panel_button)" '"false"' || return 1
}

# The receipt used to be a `key|value` text format. A value containing a pipe or
# a newline silently truncated the record.
t_pref_value_with_pipe_and_newline() {
  sandbox_json "$PREFS" '{"brave":{"show_side_panel_button":"a|b\nc|d"}}'
  run_q activate
  run_q deactivate
  assert "awkward value survived" \
    "$(json_get "$PREFS" brave.show_side_panel_button)" '"a|b\nc|d"' || return 1
}

# A pref that was absent must be removed on rollback, not set to false.
t_absent_pref_removed_on_rollback() {
  sandbox_json "$PREFS" '{"brave":{"other":1}}'
  run_q activate
  run_q deactivate
  assert "pref gone again" "$(json_get "$PREFS" brave.show_side_panel_button)" "__absent__" || return 1
  assert "unrelated pref untouched" "$(json_get "$PREFS" brave.other)" "1" || return 1
}

# Repeated activate must keep the EARLIEST prior, so rollback reaches the
# untouched machine rather than the state the previous run left.
t_double_activate_keeps_earliest_prior() {
  mkdir -p "$(dirname "$PLIST")"
  plutil -create xml1 "$PLIST" >/dev/null 2>&1 || printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$PLIST"
  plutil -insert TorDisabled -string "original" "$PLIST"
  run_q activate
  run_q activate
  run_q deactivate
  assert "earliest prior wins" "$(plist_value "$PLIST" TorDisabled)" "original" || return 1
}

# activate then activate --machine populates two plists. One receipt could only
# ever describe one of them, leaving the other enforced and unrollbackable.
t_scopes_have_separate_receipts() {
  local machine_plist="${SBX}/Library/Managed Preferences/com.brave.Browser.plist"
  run_q activate
  run_q activate --machine
  assert_file_exists "${RECEIPT_DIR}/com.brave.Browser.user.json" || return 1
  assert_file_exists "${RECEIPT_DIR}/com.brave.Browser.machine.json" || return 1
  assert_file_exists "$machine_plist" || return 1
  run_q deactivate --machine
  assert_file_absent "$machine_plist" || return 1
  assert_file_exists "$PLIST" || return 1          # user scope still enforced
  run_q deactivate
  assert_file_absent "$PLIST" || return 1          # and still rollbackable
}

t_deactivate_without_receipt_refuses() {
  run_q activate
  rm -f "${RECEIPT_DIR}/com.brave.Browser.user.json"
  run_q deactivate
  assert "exits non-zero" "$?" "1" || return 1
  assert "keys left alone" "$(plist_value "$PLIST" TorDisabled)" "true" || return 1
}

# A truncated receipt used to yield zero loop iterations, all counters zero, and
# a deleted receipt with every key still applied.
t_malformed_receipt_refused_and_kept() {
  run_q activate
  local r="${RECEIPT_DIR}/com.brave.Browser.user.json"
  printf '%s' '{"plist":"/nope"' > "$r"          # truncated JSON
  run_q deactivate
  assert_file_exists "$r" || return 1
  assert "keys still applied" "$(plist_value "$PLIST" TorDisabled)" "true" || return 1
}

t_receipt_missing_required_key_refused() {
  run_q activate
  local r="${RECEIPT_DIR}/com.brave.Browser.user.json"
  printf '%s' '{"plist":"'"$PLIST"'"}' > "$r"    # valid JSON, no priors
  run_q deactivate
  assert_file_exists "$r" || return 1
  assert "keys still applied" "$(plist_value "$PLIST" TorDisabled)" "true" || return 1
}

# Keys this script never wrote must survive rollback untouched.
t_foreign_key_survives_rollback() {
  mkdir -p "$(dirname "$PLIST")"
  plutil -create xml1 "$PLIST" >/dev/null 2>&1 || printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$PLIST"
  plutil -insert SomeOtherMDMPolicy -string "not ours" "$PLIST"
  run_q activate
  run_q deactivate
  assert "foreign key kept" "$(plist_value "$PLIST" SomeOtherMDMPolicy)" "not ours" || return 1
}

t_dry_run_writes_nothing() {
  local before; before=$(sha "$PREFS")
  run_q activate --dry-run
  assert_file_absent "$PLIST" || return 1
  assert_file_absent "${RECEIPT_DIR}/com.brave.Browser.user.json" || return 1
  assert "prefs untouched" "$(sha "$PREFS")" "$before" || return 1
}

t_dry_run_deactivate_writes_nothing() {
  run_q activate
  local before_plist; before_plist=$(sha "$PLIST")
  run_q deactivate --dry-run
  assert_file_exists "${RECEIPT_DIR}/com.brave.Browser.user.json" || return 1
  assert "plist untouched" "$(sha "$PLIST")" "$before_plist" || return 1
}

t_refuses_while_brave_running() {
  SBX_BRAVE_RUNNING=1 run_q activate
  assert "exits non-zero" "$?" "1" || return 1
  assert_file_absent "$PLIST" || return 1
}

# The window the trap closes: mutation has begun but the run dies. The receipt
# must already be on disk, and must be enough to roll back.
t_interrupted_activate_is_rollbackable() {
  # Background the script directly, never through the `run` wrapper: a shell
  # function backgrounds as a subshell, so $! would be the subshell and the
  # signal would never reach origin.sh.
  bash "$SCRIPT" activate --no-color >/dev/null 2>&1 &
  local pid=$!
  # Kill as soon as the receipt appears; if the run finishes first that is fine
  # too — either way a receipt must exist and deactivate must work.
  local i=0
  while (( i < 200 )); do
    [[ -e "${RECEIPT_DIR}/com.brave.Browser.user.json" ]] && break
    sleep 0.01; (( ++i ))
  done
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  assert_file_exists "${RECEIPT_DIR}/com.brave.Browser.user.json" || return 1
  run_q deactivate
  assert_file_absent "$PLIST" || return 1
  assert "prefs rolled back" "$(json_get "$PREFS" brave.show_side_panel_button)" "__absent__" || return 1
}

t_status_runs_clean_before_and_after() {
  run_q status; local a=$?
  run_q activate
  run_q status; local b=$?
  assert "status before activate" "$a" "0" || return 1
  assert "status after activate"  "$b" "0" || return 1
}

t_unreadable_prefs_keeps_receipt() {
  run_q activate
  printf '%s' 'not json at all' > "$PREFS"
  run_q deactivate
  assert "deactivate reports failure" "$?" "1" || return 1
  assert_file_exists "${RECEIPT_DIR}/com.brave.Browser.user.json" || return 1
}

# A single-profile install (no "Profile 1") is the common shape. `status` used
# to abort silently on it: the unmatched glob made profile_pref_files return 1,
# and a bare assignment from it tripped `set -e`.
t_status_with_only_default_profile() {
  rm -rf "$(dirname "$PREFS2")"
  run_q status
  assert "status exits 0" "$?" "0" || return 1
  local out; out=$(run status 2>&1)
  case "$out" in
    *Environment*) : ;;
    *) _fail_msg+="      status stopped early; never reached the Environment section"$'\n'; return 1 ;;
  esac
}

t_activate_with_only_default_profile() {
  rm -rf "$(dirname "$PREFS2")"
  run_q activate
  assert "exits 0" "$?" "0" || return 1
  assert "pref applied" "$(json_get "$PREFS" brave.show_side_panel_button)" "false" || return 1
}

# A corrupt receipt must never be treated as "no prior receipt". Doing so would
# record the values the previous run installed as if they were the untouched
# machine's, and silently destroy the only copy of the real priors.
t_corrupt_prior_receipt_refuses_activate() {
  mkdir -p "$(dirname "$PLIST")"
  plutil -create xml1 "$PLIST" >/dev/null 2>&1 || printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$PLIST"
  plutil -insert TorDisabled -string "original" "$PLIST"
  run_q activate
  local r="${RECEIPT_DIR}/com.brave.Browser.user.json"
  printf '%s' '{"plist": truncated' > "$r"
  run_q activate
  assert "second activate refuses" "$?" "1" || return 1
  assert "corrupt receipt not overwritten" "$(cat "$r")" '{"plist": truncated' || return 1
}

# Deleting a Brave profile after activate must not wedge deactivate forever.
t_vanished_profile_does_not_wedge_deactivate() {
  run_q activate
  rm -rf "$(dirname "$PREFS2")"
  run_q deactivate
  assert "deactivate succeeds" "$?" "0" || return 1
  assert_file_absent "${RECEIPT_DIR}/com.brave.Browser.user.json" || return 1
}

# Progress belongs on stdout. When these lines went to stderr, whether they
# appeared at all — and in what order — depended on how the caller consumed the
# two streams, so a successful run could look like it had silently done nothing.
t_pref_progress_goes_to_stdout() {
  local out
  out=$(run activate 2>/dev/null)
  case "$out" in *"Default/Preferences"*) : ;;
    *) _fail_msg+="      profile pref confirmation missing from stdout"$'\n'; return 1 ;;
  esac
  case "$out" in *"Local State"*) : ;;
    *) _fail_msg+="      Local State confirmation missing from stdout"$'\n'; return 1 ;;
  esac
}

# And the Result block must state the pref outcome on its own, so the summary is
# complete even if the inline lines are lost.
t_result_summarises_prefs() {
  local out
  out=$(run activate 2>/dev/null)
  case "$out" in *"Prefs written"*) : ;;
    *) _fail_msg+="      Result block does not summarise prefs"$'\n'; return 1 ;;
  esac
}

# ── install.sh ───────────────────────────────────────────────────────────────
# The bootstrap the curl one-liner runs. Sandboxed the same way: only the two
# root preconditions and the /Applications lookup are rewritten.

installer() { bash "$(sandbox_installer "$SBX")" "$@" 2>&1; }

t_installer_verifies_checksum() {
  local sha out
  sha=$(shasum -a 256 "$SCRIPT" | cut -d' ' -f1)
  out=$(ORIGIN_SOURCE="$SCRIPT" ORIGIN_SHA256="$sha" installer status)
  assert "exit 0" "$?" "0" || return 1
  case "$out" in *"Checksum verified"*) : ;;
    *) _fail_msg+="      installer did not report a verified checksum"$'\n'; return 1 ;;
  esac
}

t_installer_refuses_bad_checksum() {
  local out
  out=$(ORIGIN_SOURCE="$SCRIPT" ORIGIN_SHA256="0000000000000000000000000000000000000000000000000000000000000000" installer status)
  assert "exit non-zero" "$?" "1" || return 1
  case "$out" in *"Checksum mismatch"*) : ;;
    *) _fail_msg+="      expected a checksum mismatch refusal"$'\n'; return 1 ;;
  esac
  # And it must not have run the script anyway.
  case "$out" in *"Brave Origin — status"*)
    _fail_msg+="      origin.sh ran despite the mismatch"$'\n'; return 1 ;;
  esac
}

t_installer_passes_action_through() {
  local out
  out=$(ORIGIN_SOURCE="$SCRIPT" ORIGIN_SHA256=skip installer activate)
  assert "exit 0" "$?" "0" || return 1
  assert_file_exists "$PLIST" || return 1
  assert "pref applied" "$(json_get "$PREFS" brave.show_side_panel_button)" "false" || return 1
}

t_installer_reports_rollback_command() {
  local out
  out=$(ORIGIN_SOURCE="$SCRIPT" ORIGIN_SHA256=skip installer activate)
  case "$out" in *"deactivate --channel com.brave.Browser"*) : ;;
    *) _fail_msg+="      no pasteable rollback command in the output"$'\n'; return 1 ;;
  esac
  # And never a temp path the user cannot act on.
  case "$out" in *"sudo ${SBX}"*|*"/var/folders"*"origin.sh deactivate"*)
    _fail_msg+="      rollback hint pointed at a temp path"$'\n'; return 1 ;;
  esac
}

# Piped to bash with no arguments and no terminal, it must say what to do rather
# than hang waiting on a prompt that can never be answered.
t_installer_without_tty_or_action_explains() {
  local out
  out=$(ORIGIN_SOURCE="$SCRIPT" ORIGIN_SHA256=skip installer < /dev/null)
  assert "exit non-zero" "$?" "1" || return 1
  case "$out" in *"activate"*) : ;;
    *) _fail_msg+="      no guidance on how to pass an action"$'\n'; return 1 ;;
  esac
}

t_installer_lists_installed_channels() {
  local out
  out=$(ORIGIN_SOURCE="$SCRIPT" ORIGIN_SHA256=skip installer status)
  case "$out" in *"Brave (stable)"*) : ;;
    *) _fail_msg+="      installed channels were not listed"$'\n'; return 1 ;;
  esac
}

# The pinned checksum must actually be checked. An earlier release pinned the
# real value into the "is it still a placeholder?" comparison as well, which
# silently disabled verification while still looking pinned.
t_installer_pinned_sha_is_enforced() {
  local pinned out
  pinned=$(grep '^PINNED_SHA256=' install.sh | cut -d'"' -f2)
  case "$pinned" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
    *) _fail_msg+="      PINNED_SHA256 is not a checksum: [$pinned]"$'\n'; return 1 ;;
  esac
  assert "pinned sha is 64 hex chars" "${#pinned}" "64" || return 1
  # Feeding it a file whose checksum is the pinned one must verify, not warn.
  out=$(ORIGIN_SOURCE="$SCRIPT" ORIGIN_SHA256="$(shasum -a 256 "$SCRIPT" | cut -d' ' -f1)" installer status)
  case "$out" in
    *"Checksum verified"*) : ;;
    *) _fail_msg+="      a matching checksum did not report as verified"$'\n'; return 1 ;;
  esac
  case "$out" in
    *"not verified"*) _fail_msg+="      verification was skipped, not performed"$'\n'; return 1 ;;
  esac
}

# ── Run ──────────────────────────────────────────────────────────────────────
echo "origin.sh test suite"
echo "${DIM}sandboxed: no root, no real Brave, nothing written outside \$TMPDIR${RESET}"
echo

test_case "activate applies policies and prefs"        t_activate_applies
test_case "roundtrip restores files exactly"           t_roundtrip_restores_exactly
test_case "receipt written on activate, cleared on deactivate" t_receipt_written_and_cleared
test_case "restores string prior with its type"        t_restores_string_prior_with_type
test_case "restores integer prior with its type"       t_restores_integer_prior_with_type
test_case "empty-string prior is not treated as absent" t_empty_string_prior_is_not_absence
test_case "restores string-typed pref as a string"     t_restores_string_typed_pref
test_case "receipt survives a value with pipe and newline" t_pref_value_with_pipe_and_newline
test_case "absent pref is removed, not falsified"      t_absent_pref_removed_on_rollback
test_case "double activate keeps earliest prior"       t_double_activate_keeps_earliest_prior
test_case "each scope gets its own receipt"            t_scopes_have_separate_receipts
test_case "deactivate without receipt refuses"         t_deactivate_without_receipt_refuses
test_case "malformed receipt refused and kept"         t_malformed_receipt_refused_and_kept
test_case "receipt missing a required key is refused"  t_receipt_missing_required_key_refused
test_case "foreign key survives rollback"              t_foreign_key_survives_rollback
test_case "dry-run activate writes nothing"            t_dry_run_writes_nothing
test_case "dry-run deactivate writes nothing"          t_dry_run_deactivate_writes_nothing
test_case "refuses to run while Brave is running"      t_refuses_while_brave_running
test_case "interrupted activate is rollbackable"       t_interrupted_activate_is_rollbackable
test_case "status runs clean before and after"         t_status_runs_clean_before_and_after
test_case "unreadable prefs keeps the receipt"         t_unreadable_prefs_keeps_receipt
test_case "pref progress goes to stdout"               t_pref_progress_goes_to_stdout
test_case "result block summarises prefs"              t_result_summarises_prefs
test_case "status works with only a Default profile"    t_status_with_only_default_profile
test_case "activate works with only a Default profile"  t_activate_with_only_default_profile
test_case "corrupt prior receipt refuses activate"     t_corrupt_prior_receipt_refuses_activate
test_case "vanished profile does not wedge deactivate" t_vanished_profile_does_not_wedge_deactivate

test_case "installer verifies the checksum"            t_installer_verifies_checksum
test_case "installer refuses a bad checksum"           t_installer_refuses_bad_checksum
test_case "installer passes the action through"        t_installer_passes_action_through
test_case "installer prints a pasteable rollback"      t_installer_reports_rollback_command
test_case "installer without tty or action explains"   t_installer_without_tty_or_action_explains
test_case "installer lists installed channels"         t_installer_lists_installed_channels
test_case "installer enforces the pinned checksum"     t_installer_pinned_sha_is_enforced

echo
if (( FAIL == 0 )); then
  echo "${GREEN}${PASS} passed${RESET}"
else
  echo "${RED}${FAIL} failed${RESET}, ${PASS} passed"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
fi
exit $(( FAIL > 0 ))
