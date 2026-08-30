# Design notes

Why the tool works the way it does. The [README](../README.md) covers what it does.

## The receipt

These policy keys are exactly what an MDM profile, or another debloat script, would also
write. A tool that deletes them by name on `deactivate` silently destroys configuration
it never created. So `activate` records what it touched and `deactivate` acts only on
that record.

**Value and type, not just value.** A key holding the string `"true"`, or an integer, is
not a boolean. Rebuilding every prior as a boolean is data loss wearing the costume of a
rollback. A prior whose type cannot be reproduced faithfully - a dict, an array,
`REG_BINARY` - is refused outright rather than overwritten with a substitute.

**Written before the first change, atomically.** A receipt written after the work is a
receipt that does not exist when the work is interrupted. A truncating write that fails
partway destroys the only record that makes rollback possible. `activate` also traps
`INT`, `TERM` and `HUP`; a run cut off partway leaves a receipt marked `provisional`,
which `deactivate` rolls back like any other.

**Earliest prior wins.** Re-running `activate` keeps the first recorded prior, so
rollback reaches the untouched machine rather than the state the last run left.

**One receipt per scope.** On macOS, `activate` followed by `activate --machine`
populates two plists, and a single receipt can only describe one of them. The other would
be left enforcing policy with nothing able to roll it back.

**The prior is stored twice** on Linux and Windows, in both the per-channel receipt and
the shared-store record. The duplication is deliberate: it is the only copy of a third
party's configuration that survives losing one record, and destroying an MDM-deployed
file is the one thing this must never do.

## Per-platform

### macOS: why the per-user path

Policies go to `/Library/Managed Preferences/<user>/<bundle-id>.plist`. That is the path
`PolicyLoaderMac::GetManagedPolicyPath()` constructs and the only one Chromium installs a
`FilePathWatcher` on. It also yields `POLICY_SCOPE_USER`, matching how Brave Origin
publishes its own policies.

`--machine` writes `/Library/Managed Preferences/<bundle-id>.plist`. Brave still reads
it, but reports `POLICY_SCOPE_MACHINE`, and changes are only picked up on the 15-minute
`AsyncPolicyLoader` poll, on "Reload policies", or at restart. `status` reports both
paths, so a stale copy at the other one cannot enforce policy unnoticed.

Do not chase recommended level with `defaults write`. That is the documented
recommended-level path on macOS, these policies reject it, and community reports link
user-plist writes for Brave policy keys to `EXC_BREAKPOINT` crashes at startup. All the
templates declare `can_be_recommended: false`, so mandatory is the only level available.

### Linux: a file of our own

`app/brave_main_delegate.cc` overrides the policy directory to `/etc/brave/policies` with
`create=false`, so nothing creates it. Brave reads every `*.json` in `managed/`, which
means the tool can write its own file instead of sharing a namespace. That removes the
need for typed per-key priors on policies entirely; `deactivate` removes one file.

The consequences are that policies are global across channels, and that a
lexicographically later file wins. Both are surfaced rather than hidden: the store
records which channels claimed it, and `status` reports conflicting files.

`BraveVPNDisabled` is compiled out on Linux - `enable_brave_vpn_v1/v2` list
`is_win || is_android || is_mac || is_ios`, with no `is_linux` - so it is reported as
not-written rather than applied.

### Windows: both models at once

The policy key is channel-independent; brave-core patches out the product suffix, so
every channel reads `SOFTWARE\Policies\BraveSoftware\Brave`. That is the Linux problem,
and it brings the channel refcount with it. But the key is shared with MDM, like the
macOS plist, so it also needs typed per-value priors. Windows is the only platform that
needs both.

`Recommended` and `3rdparty` are reserved subkeys and are never touched. The key itself
is removed only when it holds no values and no subkeys.

Profile prefs are spliced as raw JSON text rather than parsed and re-serialised, because
PowerShell 5.1's `ConvertFrom-Json` collapses `2.0` to `2` and Chromium then discards the
pref as the wrong type. A round trip would quietly corrupt settings the tool never
touched.

Both `.ps1` files are pure ASCII. PowerShell 5.1 reads a BOM-less script as ANSI, so a
single em dash mid-file mis-decodes and the parse fails with an error naming a line
nowhere near the cause. A BOM would also work, but only if it survives every copy, and
nothing enforces that.

## Why a pref, not `MetricsReportingEnabled`

`MetricsReportingEnabled` was flagged `sensitive: true` in Chromium's templates, and
`PolicyLoaderMac`/`PolicyLoaderWin` filter sensitive policies on a machine that is
neither MDM-enrolled nor domain-joined - the policy is read and then `SetBlocked()`,
silently discarded. The `Local State` pref works regardless.

Brave has since removed the `sensitive` flag from that policy (`#35742`, April 2026), so
on current builds the workaround may be unnecessary. It has not been re-tested, and the
pref costs nothing.

On stable the pref is close to redundant: `GetDefaultPrefValueForMetricsReporting()`
already returns `false` for `Channel::STABLE`. On Beta, Dev and Nightly it returns `true`,
so there the pref is the only thing turning reporting off. Nightly is `Channel::CANARY`
in `version_info`; there is no `NIGHTLY` enumerator.

## Privileges and verification

The script runs as root because the policy paths require it, but every file under the
user's home is edited **as that user** via `sudo -u`. Root writing by path into a
user-writable directory is a privilege-escalation primitive: a planted symlink at a
predictable temp path turns it into an arbitrary root write and `chown`. Temp files use
`mkstemp` and the original file's mode is carried across.

PlistBuddy exits 0 even when it cannot save - permission denied, immutable flag, full
disk. Every write is therefore read back, and the type is checked as well as the value.

The script refuses to: run while the target Brave is running, run `deactivate` without a
receipt, modify a policy store that does not parse, or delete any key the receipt does not
claim.

## The binary really is smaller

Measured on the same version, `151.1.93.138`: the Brave Origin arm64 framework is
232.3 MiB against stable's 245.9 MiB. A naive `du` of the bundles reports 687M vs 444M,
but that gap is architecture, not features - Origin ships universal while an installed
stable has been thinned to arm64. The real difference is about 5.5%, and policy cannot
reproduce it.

## Corrections

Claims in earlier versions of the documentation that source review disproved.

| Previous claim | Reality |
|---|---|
| "Survey Panelist removed, cannot be replicated" | Already replicated. `isSurveyPanelistAllowed` is `feature && !kDisabledByPolicy`, satisfied by `BraveRewardsDisabled` |
| "Promotional NTP banners: no policy or pref" | `IsNTPPromotionEnabled()` also honours a writable pref |
| "`BraveLocalAIEnabled`, `PsstEnabled` present in release" | Neither existed at 1.93. `BraveLocalAIEnabled` shipped in 1.94; `PsstEnabled` is still master-only |
| "`BackgroundModeEnabled` applies on macOS" | Chromium declares it `supported_on: chrome.win, chrome.linux`. Removed |
| "Managed policies always win, unlike Brave Origin" | Brave Origin is also `POLICY_LEVEL_MANDATORY`. The difference is the settings UI |
| "`deactivate` removes only its own keys" | It matched on key name only, and would have stripped keys written by another tool. True now, via the receipt |
| "`branded_wallpaper_notification_dismissed` mirrors a standalone default" | It is registered `false` in every build. It is an inferred workaround |
| "One receipt per channel is enough" | Two scopes, or two channels sharing one store, left the second enforcing policy with nothing able to roll it back |
