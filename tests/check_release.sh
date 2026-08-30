#!/usr/bin/env bash
# Release gate. Run before tagging.
#
#   ./tests/check_release.sh v1.2.0
#
# Checks the things that can only be wrong at release time, and that no suite
# can see because they are about what is pinned rather than what the code does.
# v1.0.0 shipped with its checksum gate disabled because a release step rewrote
# a placeholder everywhere, including inside the comparison that detected it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TAG="${1:-}"
FAIL=0
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; RESET=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; RESET=""; }
bad()  { echo "${RED}[x]${RESET} $*"; FAIL=1; }
good() { echo "${GREEN}[+]${RESET} $*"; }

# 1. No unsubstituted placeholders anywhere.
if grep -rn '__ORIGIN_[A-Z_]*__' install.sh install.ps1 2>/dev/null; then
  bad "unsubstituted placeholder in an installer"
else
  good "no unsubstituted placeholders"
fi

# 2. The pinned checksums match the files that will actually be fetched.
sh_sha=$(shasum -a 256 origin.sh | cut -d' ' -f1)
ps_sha=$(shasum -a 256 origin.ps1 | cut -d' ' -f1)
sh_pin=$(grep '^PINNED_SHA256=' install.sh | cut -d'"' -f2)
ps_pin=$(grep "^\$PinnedSha256 = " install.ps1 | cut -d"'" -f2)

[[ "$sh_sha" == "$sh_pin" ]] && good "install.sh pins the current origin.sh" \
  || bad "install.sh pins ${sh_pin:-<empty>}, origin.sh is ${sh_sha}"
[[ "$ps_sha" == "$ps_pin" ]] && good "install.ps1 pins the current origin.ps1" \
  || bad "install.ps1 pins ${ps_pin:-<empty>}, origin.ps1 is ${ps_sha}"

# 3. Both pins are real 64-hex checksums, not a placeholder that happens to
#    match itself — the exact shape of the v1.0.0 failure.
for pair in "install.sh:$sh_pin" "install.ps1:$ps_pin"; do
  f="${pair%%:*}"; v="${pair#*:}"
  [[ "$v" =~ ^[0-9a-f]{64}$ ]] && good "$f pin is a 64-hex checksum" \
    || bad "$f pin is not a checksum: [${v}]"
done

# 4. Both installers pin the tag being cut.
if [[ -n "$TAG" ]]; then
  sh_ref=$(grep '^PINNED_REF=' install.sh | cut -d'"' -f2)
  ps_ref=$(grep "^\$PinnedRef = " install.ps1 | cut -d"'" -f2)
  [[ "$sh_ref" == "$TAG" ]] && good "install.sh pins ${TAG}" || bad "install.sh pins ${sh_ref}, not ${TAG}"
  [[ "$ps_ref" == "$TAG" ]] && good "install.ps1 pins ${TAG}" || bad "install.ps1 pins ${ps_ref}, not ${TAG}"
else
  echo "    (pass a tag to check the pinned refs too)"
fi

# 5. PSScriptAnalyzer's own 5.1 checks, when it is available. This is what
#    caught the missing-BOM/non-ASCII problem that the hand-written lint did
#    not know to look for.
if command -v pwsh >/dev/null 2>&1 && \
   pwsh -NoProfile -Command 'if (Get-Module -ListAvailable PSScriptAnalyzer) { exit 0 } else { exit 1 }' 2>/dev/null; then
  out=$(pwsh -NoProfile -Command '
    $s = @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @("5.1","7.0") } } }
    $bad = @()
    foreach ($f in @("origin.ps1","install.ps1")) {
      $bad += Invoke-ScriptAnalyzer -Path $f -Settings $s |
        Where-Object { $_.RuleName -eq "PSUseCompatibleSyntax" -or $_.Message -like "*BOM*" }
    }
    if ($bad) { $bad | ForEach-Object { Write-Output $_.Message }; exit 1 }' 2>&1)
  if [[ -n "$out" ]]; then bad "PSScriptAnalyzer 5.1: $out"; else good "PSScriptAnalyzer 5.1 checks clean"; fi
else
  echo "    (PSScriptAnalyzer not installed - 5.1 rule check skipped)"
fi

# 6. Every suite green.
bash tests/run_tests.sh >/dev/null 2>&1 && good "bash suite passes" || bad "bash suite fails"
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File tests/Run-Tests.ps1 >/dev/null 2>&1 && good "PowerShell suite passes" || bad "PowerShell suite fails"
  pwsh -NoProfile -File tests/Test-Ps51Compat.ps1 >/dev/null 2>&1 && good "PowerShell 5.1 lint clean" || bad "PowerShell 5.1 lint fails"
else
  echo "    (pwsh not installed — PowerShell suites skipped)"
fi

echo
[[ $FAIL -eq 0 ]] && echo "${GREEN}ready to tag${RESET}" || echo "${RED}not ready${RESET}"
exit $FAIL
