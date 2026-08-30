# Brave to Origin — policy clone for standard Brave (macOS, Linux, Windows)

Applies the 16 preferences that **Brave Origin upgrade mode** enforces, using Brave's
own enterprise-policy mechanism, plus the standalone-build defaults reachable without
a custom binary.

Every key, value and pref name was verified against `brave-core` and against the
shipped macOS binary. Claims that source review disproved are listed in
[Corrections](#corrections).

---

## Run it without cloning

**macOS and Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/mdrubelamin2/brave-to-origin/main/install.sh | sudo bash
```

**Windows**, in an elevated PowerShell:

```powershell
irm https://raw.githubusercontent.com/mdrubelamin2/brave-to-origin/main/install.ps1 | iex
```

It finds your installed Brave channels, asks which one and whether to activate,
deactivate or check status, then fetches `origin.sh` at a pinned tag, verifies its
SHA-256 and runs it. Nothing is left on disk afterwards except the receipt, which is
what a later `deactivate` needs.

Non-interactive, for scripts:

```bash
... | sudo bash -s -- activate
... | sudo bash -s -- status --channel com.brave.Browser.beta
... | sudo bash -s -- deactivate
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mdrubelamin2/brave-to-origin/main/install.ps1))) -Action activate
& ([scriptblock]::Create((irm ...))) -Action status -Channel com.brave.Browser.beta
```

> **This is `curl | sudo bash`.** You are running code from the internet as root on the
> word of a TLS certificate. The installer pins a tag rather than tracking `main` and
> checks a SHA-256 before running anything, but neither of those protects you if this
> repository itself is compromised. Reading both files first is the honest advice, and
> cloning is always available:

```bash
git clone https://github.com/mdrubelamin2/brave-to-origin && cd brave-to-origin
sudo ./origin.sh activate       # apply
sudo ./origin.sh deactivate     # undo, using the receipt activate wrote
sudo ./origin.sh status         # report what is applied and what Brave will honour

sudo ./origin.sh activate --dry-run
```

## Options

`origin.sh` takes these; the installer forwards anything it does not recognise.

| Option | Effect |
|---|---|
| `--dry-run` | Print planned changes, write nothing |
| `--channel <bundle-id>` | Target a specific install instead of auto-detecting |
| `--machine` | Use the machine-wide policy path ([lower fidelity](#why-the-per-user-path)) |
| `--no-color` | Suppress ANSI colour (automatic when output is piped) |
| `-h`, `--help` | Usage on stdout, exit 0. Running with no command prints usage on stderr and exits 1 |

**Requires `python3`** (Xcode Command Line Tools) — every JSON edit goes through it.
The script checks for it before writing anything. `strings` is used if present, with a
pure-shell fallback.

**Quit Brave first.** The script refuses to run otherwise: Brave rewrites `Preferences`
and `Local State` from memory on exit and would discard the pref changes. It re-checks
afterwards and warns if Brave started mid-run.

**Restart Brave afterwards.** Every one of these policies declares `dynamic_refresh: false`.

Verify at `brave://policy`.

> `activate` and `deactivate` run `killall cfprefsd`, a system-wide restart of the
> preferences cache daemon. Brave's own documentation prescribes it after a PlistBuddy
> edit; it respawns immediately, but it does briefly affect other apps.

### Tests

```bash
./tests/run_tests.sh              # macOS + Linux, 51 cases
pwsh tests/Run-Tests.ps1          # Windows, 21 cases
pwsh tests/Test-Ps51Compat.ps1    # PowerShell 5.1 syntax gate
./tests/check_release.sh v1.2.3   # release gate: pins, checksums, all suites
```

No `sudo`, no Brave install, nothing written outside `$TMPDIR`. The Linux backend is
covered too: nine cases force the script onto its Linux paths with every system root
redirected, so they run on macOS. See [Known limitations](#known-limitations) for what
a sandboxed suite cannot reach.

---

## Provenance: the receipt

These 16 policy keys are exactly what an MDM profile, or another debloat script, would
also write. A tool that deletes them by name on `deactivate` will silently destroy
configuration it never created.

So `activate` writes a receipt to
`/Library/Application Support/brave-origin-clone/<bundle-id>.<scope>.json` recording
every key it touched, **that key's prior value, and the prior's type**. `deactivate`
acts only on that receipt:

- keys the receipt shows were **absent** before → removed
- keys that **already existed** → restored to their prior value *and type*, not deleted
- prefs → restored to their prior value and type, including "was absent"
- anything not in the receipt → left alone and reported

The type matters. A key holding the string `"true"`, or an integer, is not a boolean,
and rebuilding it as one is data loss wearing the costume of a rollback. A prior whose
type cannot be reproduced faithfully — a dict or an array — is refused outright rather
than overwritten with a substitute.

One receipt **per scope**, because `activate` followed by `activate --machine` populates
two plists and a single receipt can only describe one of them. A receipt written by an
older version, under the unsuffixed name, is still honoured.

The receipt is written **before** the first change, not after the last one, and written
atomically — a truncating write that failed partway would destroy the very record that
makes rollback possible. `activate` traps `INT`, `TERM` and `HUP`. A run cut off partway
leaves a receipt marked `provisional`, which `deactivate` rolls back like any other.

Re-running `activate` keeps the *earliest* recorded prior, so rollback reaches the
untouched machine rather than the state your last run left behind.

**Without a receipt, `deactivate` refuses to run.** It will not guess which keys are
its own.

---

## What this can and cannot do

| | Status |
|---|---|
| The 16 upgrade-mode policies | Applied, at the same mandatory level Brave Origin uses |
| Survey Panelist hidden | Achieved, as a side effect of `BraveRewardsDisabled` |
| P3A / usage-ping toggles greyed out | Achieved, via `IsManagedPreference()` |
| Search-conversion NTP promo | Achieved, via profile pref |
| Crash / metrics reporting off | Achieved, via Local State pref (not policy — see below) |
| Sidebar button hidden | Achieved, via profile pref |
| `brave://settings/origin` toggles | **Not possible.** Gated on `IsBraveOriginPurchased()` |
| Smaller binary / reduced attack surface | **Not possible.** Origin compiles features out |
| Own branding, bundle ID, update channel | **Not possible.** Separate build artefact |

### The binary really is smaller

Measured on the same version (151.1.93.138):

| Build | arm64 framework |
|---|---|
| Brave Origin | 232.3 MiB |
| Brave stable | 245.9 MiB |

A naive `du` of the bundles reports 687M vs 444M, but that gap is architecture, not
features: Origin ships universal (`x86_64 arm64`) while an installed stable has been
thinned to `arm64`. The real difference is ~13.6 MiB, about 5.5%.

---

## Section A — the 16 upgrade-mode policies

Source: [`brave_origin_service_factory.cc`](https://github.com/brave/brave-core/blob/master/browser/brave_origin/brave_origin_service_factory.cc),
maps `kBraveOriginBrowserMetadata` (4) and `kBraveOriginProfileMetadata` (12).
Keys resolve through
[`brave_simple_policy_map.h`](https://github.com/brave/brave-core/blob/master/browser/policy/brave_simple_policy_map.h).

### Browser-level

| Policy | Value | User settable | Pref |
|---|---|---|---|
| `TorDisabled` | `true` | no | `tor::prefs::kTorDisabled` |
| `BraveStatsPingEnabled` | `false` | yes | `kStatsReportingEnabled` |
| `BraveP3AEnabled` | `false` | yes | `p3a::kP3AEnabled` |
| `BraveLocalAIEnabled` | `false` | yes | `local_ai::prefs::kBraveLocalAIEnabled` |

### Profile-level

| Policy | Value | User settable | Pref |
|---|---|---|---|
| `BraveWaybackMachineEnabled` | `false` | yes | `kBraveWaybackMachineEnabled` |
| `BraveRewardsDisabled` | `true` | no | `brave_rewards::prefs::kDisabledByPolicy` |
| `BraveWalletDisabled` | `true` | no | `brave_wallet::kBraveWalletDisabledByPolicy` |
| `BraveAIChatEnabled` | `false` | no | `ai_chat::prefs::kEnabledByPolicy` |
| `BraveSpeedreaderEnabled` | `false` | yes | `speedreader::kSpeedreaderEnabled` |
| `BravePlaylistEnabled` | `false` | yes | `playlist::kPlaylistEnabledPref` |
| `BraveNewsDisabled` | `true` | no | `brave_news::prefs::kBraveNewsDisabledByPolicy` |
| `BraveVPNDisabled` | `true` | no | `brave_vpn::prefs::kManagedBraveVPNDisabled` |
| `BraveTalkDisabled` | `true` | no | `brave_talk::prefs::kDisabledByPolicy` |
| `BraveWebDiscoveryEnabled` | `false` | yes | `kWebDiscoveryEnabled` |
| `EmailAliasesEnabled` | `false` | no | `email_aliases::prefs::kEmailAliasesEnabled` |
| `PsstEnabled` | `false` | no | `psst::prefs::kPsstEnabled` |

Seven are `user_settable`; nine are locked.

### One is inert on the current release

`PsstEnabled` exists on `brave-core` **master** but not in the shipped release. At tag
`v1.94.117` its policy template returns 404 and the string is absent from the macOS
framework binary. It landed on master on 2026-08-11, after the 1.94 branch cut.

`BraveLocalAIEnabled` was inert too, and no longer is: it was added to
`kBraveOriginBrowserMetadata` in 1.94 and both its template and its string are present
at `v1.94.117`. So the shipped release carries 15 of these 16 policies.

The script probes the installed binary, writes them anyway, and labels them *inert*.
Writing is harmless — `PolicyLoaderMac::Load()` iterates the compiled-in schema, so a
key it does not know is never read — and it means an inert key starts applying on its
own when Brave ships it, with no re-run needed. `BraveLocalAIEnabled` is the worked
example: installs made before 1.94 began enforcing it at the 1.94 upgrade, untouched.

That silence is the reason for the probe: an unrecognised key produces no value, no
error, and no row at `brave://policy`.

> If the framework binary cannot be read at all, the script says so and writes all 16
> keys unprobed rather than guessing that none are supported.

### "User settable" does not mean recommended-level

Brave Origin publishes all 16 as `POLICY_LEVEL_MANDATORY` — see
`brave_profile_policy_provider.cc` and `brave_browser_policy_provider.cc`. The level
here matches exactly. `user_settable` governs whether the `brave://settings/origin`
panel can flip the stored value, not the policy level.

There is no workaround: all 15 templates that exist at `v1.94.117` declare
`can_be_recommended: false`, and so does the master-only `PsstEnabled`.

> **Do not** chase recommended level with `defaults write`. That is the documented
> recommended-level path on macOS, these policies reject it, and community reports link
> user-plist writes for Brave policy keys to `EXC_BREAKPOINT` crashes at startup.

---

## Section B — prefs

No policy equivalent exists for these, so the script writes them as prefs.

### Profile prefs

Applied to `Default` and `Profile N` only — `System Profile` and `Guest Profile` are
deliberately skipped. `status` uses the same selection.

| Pref | Value | Basis |
|---|---|---|
| `brave.show_side_panel_button` | `false` | **Mirrored default.** `brave_profile_prefs.cc` registers it as `!IS_BRAVE_ORIGIN_BRANDED` |
| `brave.brave_search_conversion.dismissed` | `true` | **Equivalent effect.** `IsNTPPromotionEnabled()` short-circuits on this pref exactly as it does on the Origin suppression path |
| `brave.branded_wallpaper_notification_dismissed` | `true` | **Inferred workaround.** Registered `false` in *every* build including Origin; Origin instead compiles `brave_ads` out (`enable_brave_ads = !is_brave_origin_branded`). Dismissing the notification is the closest reachable approximation |

> Brave rewrites `branded_wallpaper_notification_dismissed` back to `false` whenever the
> Rewards enabled-pref changes (`ViewCounterService::ResetNotificationState()`). Toggling
> Rewards will undo it; re-run `activate`.

### Local State pref

| Pref | Value |
|---|---|
| `user_experience_metrics.reporting_enabled` | `false` |

**Why a pref and not the `MetricsReportingEnabled` policy.** That policy is flagged
`sensitive: true` in Chromium's templates, and `PolicyLoaderMac::Load()` ends with:

```cpp
if (base::FeatureList::GetInstance() &&
    base::FeatureList::IsEnabled(
        features::kUseManagementServiceForSensitivePolicies)) {
  should_filter = ShouldFilterSensitivePolicies();
} else {
  should_filter = !ShouldHonorPolicies();
}
if (should_filter) { FilterSensitivePolicies(&chrome_policy); }
```

`kUseManagementServiceForSensitivePolicies` is enabled by default, so the live path is
`AsyncPolicyLoader::ShouldFilterSensitivePolicies()`, which filters unless platform
management is `TRUSTED`. The `!ShouldHonorPolicies()` branch now runs only before
FeatureList init.

Either way the outcome is the same: on a Mac that is neither MDM-enrolled nor
domain-joined the policy is read and then `SetBlocked()` — silently discarded. The pref
works regardless.

On **stable** it is close to redundant: `GetDefaultPrefValueForMetricsReporting()`
already returns `false` for `Channel::STABLE`. On **Beta, Dev and Nightly** that
function returns `true`, so there this pref is the only thing turning reporting off.
Nightly is `Channel::CANARY` in `version_info`; there is no `NIGHTLY` enumerator.

`status` reports whether your device is managed, so you can see which regime applies.

---

## How it works

### Platforms

| | Policy store | Scope | Per-channel? | Nudge |
|---|---|---|---|---|
| macOS | `/Library/Managed Preferences/<user>/<bundle-id>.plist`, shared | user, or machine with `--machine` | yes, one plist per bundle ID | `killall cfprefsd` |
| Linux | `/etc/brave/policies/managed/brave-to-origin.json`, ours alone | machine only | **no**, one directory for all channels | none |
| Windows | `HKLM\SOFTWARE\Policies\BraveSoftware\Brave`, shared | machine, or HKCU with `-User` | **no**, one key for all channels | none |

The two backends differ more than the table suggests, and the difference is in our
favour on Linux. macOS forces every tool into one shared plist, which is why the
receipt has to record each key's prior value and type. Brave on Linux reads *every*
`*.json` in `managed/`, so the tool writes its own file and `deactivate` removes it.
Nothing else in that directory is ever touched.

Two Linux consequences worth stating plainly:

**Policies are global.** Every channel reads the same directory — there is no
per-channel policy on Linux, and no user scope. `--machine` is accepted and ignored.
So `activate` on stable also policies beta. Because deactivating one channel must not
strip the policies another still wants, the policy file carries a list of the channels
that asked for it, and it is only removed when the last one deactivates. `status`
names the channels holding it.

**Files sorting after ours override ours.** `managed/` is applied in lexicographic
order, last file wins. `status` lists every other file there that sets any of our keys
and says which way it sorts, because an MDM-deployed `zz-corp.json` silently beats us.

### Windows

The registry key is **channel-independent** — brave-core patches out the product
suffix, so stable, beta, dev and nightly all read `...\Policies\BraveSoftware\Brave`.
That is the Linux problem again, so the same channel refcount applies. But the key is
shared with MDM and anything else writing Brave policy, so it *also* needs the macOS
model: every value's prior is recorded with its registry type and restored as that
type. Windows is the only platform that needs both.

Values are `REG_DWORD` 0/1. The reserved `Recommended` and `3rdparty` subkeys are never
touched, and the key itself is removed only when it holds no values and no subkeys at
all. A prior of a type that cannot be reproduced faithfully — `REG_BINARY`,
`REG_MULTI_SZ` — is refused rather than overwritten.

`-User` writes `HKCU` instead and needs no elevation, which is the way in on a locked
down machine. Brave reads both hives, but **HKLM wins**, so `-User` cannot override a
policy an administrator already set.

None of these policies is `sensitive: true`, so unlike macOS none of them is filtered
on a machine that is not domain-joined — consumer Windows honours all of them. Every
one is `dynamic_refresh: false`, so **restart Brave**. `gpupdate /force` shortens the
≤15-minute policy reload but does not remove the restart.

The profile prefs are edited as raw JSON text rather than parsed and re-serialised,
because PowerShell 5.1's `ConvertFrom-Json` collapses `2.0` to `2` and Chromium then
discards the pref as the wrong type. Everything outside the edited span stays
byte-identical.

`BraveVPNDisabled` is **compiled out on Linux** — `enable_brave_vpn_v1/v2` list
`is_win || is_android || is_mac || is_ios`, with no `is_linux`. It is reported as
not-written rather than applied, so 15 of 16 is the correct Linux result.

**Snap is refused.** snapd's `browser_support` AppArmor profile whitelists
`/etc/opt/chrome` and `/etc/chromium` and nothing else, so a snap Brave cannot read
`/etc/brave` at all. Writing there would report success and change nothing.

**Flatpak works**, because the manifest grants `--filesystem=host-etc` and its
`brave.sh` symlinks the host's managed policies at launch — but only at launch, so
restart Brave. Its profile lives at `~/.var/app/com.brave.Browser/config/BraveSoftware/`.

### Why the per-user path (macOS)

Policies go to `/Library/Managed Preferences/<user>/<bundle-id>.plist` by default.

That is the path `PolicyLoaderMac::GetManagedPolicyPath()` constructs, and the **only**
one Chromium installs a `FilePathWatcher` on. It also yields `POLICY_SCOPE_USER`,
matching how Brave Origin publishes its own policies.

`--machine` writes to `/Library/Managed Preferences/<bundle-id>.plist`. Brave still
reads it, but reports `POLICY_SCOPE_MACHINE`, and changes are only picked up on the
15-minute `AsyncPolicyLoader` poll, on "Reload policies", or at restart.

`status` reports **both** paths, so a stale copy at the other one cannot enforce policy
unnoticed.

### Channels

**macOS.** Bundle IDs from `app/theme/brave/BRANDING*` and
`app/theme/brave_origin/BRANDING`; user-data directory names from `build/config.gni`
(`brave_product_dir_name`).

| Channel | Bundle ID | User-data directory |
|---|---|---|
| Stable | `com.brave.Browser` | `BraveSoftware/Brave-Browser` |
| Beta | `com.brave.Browser.beta` | `BraveSoftware/Brave-Browser-Beta` |
| Nightly | `com.brave.Browser.nightly` | `BraveSoftware/Brave-Browser-Nightly` |
| Dev | `com.brave.Browser.dev` | `BraveSoftware/Brave-Browser-Dev` |
| Origin standalone | `com.brave.Browser.origin` | `BraveSoftware/Brave-Origin` |

Unlike Chrome — which hardcodes `com.google.Chrome` for all channels — Brave is not
built with `GOOGLE_CHROME_BRANDING`, so each channel reads **its own** bundle ID.

Auto-detection prefers a real Brave over the Origin standalone build, since these
policies are meaningless where the features are compiled out.

**Linux.** There are no bundle IDs; the same strings are reused as channel names so
`--channel` reads the same on both platforms. Detection is by binary path, and the
profile directory has **no `User Data` component**.

| Channel | Binary | Profile directory |
|---|---|---|
| Stable | `/opt/brave.com/brave/brave` | `~/.config/BraveSoftware/Brave-Browser` |
| Beta | `/opt/brave.com/brave-beta/brave` | `~/.config/BraveSoftware/Brave-Browser-Beta` |
| Nightly | `/opt/brave.com/brave-nightly/brave` | `~/.config/BraveSoftware/Brave-Browser-Nightly` |

`$XDG_CONFIG_HOME` is honoured when set. Brave ships **no dev channel on Linux**, and
the version is read from `dpkg-query` or `rpm -q` rather than by launching anything.

> Brave's own docs write `com.brave.browser` in prose but `com.brave.Browser` in their
> commands. Preference domains are case-sensitive; `BRANDING` confirms the capital **B**.

### Privileges

The script runs as root because `/Library/Managed Preferences` requires it. Every file
under your home directory is edited **as you**, not as root, via `sudo -u`. Root writing
by path into a user-writable directory is a privilege-escalation primitive — a planted
symlink at a predictable temp path turns it into an arbitrary root write and `chown`.
Temp files use `mkstemp` (random name, `O_EXCL`, mode 0600) and the original file's mode
is carried across, so `Preferences` and `Local State` stay `0600`.

### Verification, not optimism

PlistBuddy exits **0 even when it cannot save** — permission denied, immutable flag,
full disk. Every write is therefore read back before being reported, and keys are
written delete-then-`Add` so a pre-existing string-typed key cannot survive as a string
that Brave's boolean schema rejects.

### Things the script refuses to do

- Run while the target Brave is running.
- Run `deactivate` without a receipt.
- Modify or delete a plist that does not parse.
- Delete any key the receipt does not claim.

---

## Corrections

Claims in earlier versions of this document that source review disproved:

| Previous claim | Reality |
|---|---|
| "Survey Panelist removed — cannot be replicated" | Already replicated. In non-branded builds `isSurveyPanelistAllowed` is `feature && !kDisabledByPolicy`, satisfied by `BraveRewardsDisabled=true` |
| "Promotional NTP banners — no policy or pref" | `ShouldSuppressForBraveOrigin()` keys off `IsBraveOriginPurchased()`, not just the build flag, and `IsNTPPromotionEnabled()` also honours a writable pref |
| "`BraveLocalAIEnabled`, `PsstEnabled` ✓ in release" | Neither existed in the shipped release at 1.93. `BraveLocalAIEnabled` shipped in 1.94; `PsstEnabled` is still master-only |
| "`BackgroundModeEnabled` — standalone leaves it off on non-Linux" | Chromium declares it `supported_on: chrome.win, chrome.linux`. It never applied on macOS, and the cited source file does not exist in `brave-core`. Removed |
| "`MetricsReportingEnabled` approximates the standalone default" | Blocked as a sensitive policy on unmanaged Macs. Now a Local State pref |
| "16 policies + 3 extras" | The script wrote 18 policy keys under a header saying 16 |
| "Managed policies always win, unlike Brave Origin" | Brave Origin is also `POLICY_LEVEL_MANDATORY`. The difference is the settings UI |
| "8 user-settable policies" | Seven |
| "`deactivate` removes only its own keys" | It matched on key name only, and would have stripped 8 keys written by another tool. True now, via the receipt |
| "`branded_wallpaper_notification_dismissed` mirrors a standalone default" | It is registered `false` in every build. It is an inferred workaround for `brave_ads` being compiled out |
| "The receipt restores a key's prior value" | It rebuilt every prior as a boolean. A string prior came back `false`, an integer came back `true`. Now typed, and unrestorable types are refused |
| "One receipt per channel" | `activate` then `activate --machine` left the first plist enforced with no receipt able to roll it back. Now one receipt per scope |
| "`activate` records what it changed" | It recorded it *after* mutating. An interrupt left the machine changed with no record. The receipt is now written first, and the run traps `INT`/`TERM`/`HUP` |
| "`status` reports both scopes" | It exited silently, mid-report, on any install with no `Profile N` directory — the common shape. An unmatched glob made the helper return 1 under `set -e` |

---

## Known limitations

**Windows is verified by source and sandbox, not on a Windows machine.** The
registry is faked by a JSON file and the seams are rewritten in a copy, the same way
the Linux backend is tested. Nothing has run against a real registry, a real Brave
install, or PowerShell 5.1 — the suite runs on PowerShell 7, so `tests/Test-Ps51Compat.ps1`
walks the AST for constructs 5.1 rejects. Confirm on a real machine before trusting it.

**Linux is confirmed working** on Fedora with GNOME. The remaining Linux unknowns are
the snap refusal and the Flatpak policy linking, neither of which was exercised there.

**Reboot persistence is untested.** There are community reports that `mdmclient` removes
raw plists from `/Library/Managed Preferences` at boot unless they arrive via a signed
configuration profile. Not reproduced here. If policies vanish after a restart, package
them as a `.mobileconfig` — the officially supported delivery route.

**`deactivate` is per-channel and per-scope.** One run cleans the scope its receipt
names. `status` lists every receipt found for the channel, and names any other channel
with a live receipt, so a second scope or channel cannot sit enforced unnoticed — re-run
with `--machine` or `--channel` to clear it.

**`status` reads files, not the browser.** It cross-checks the installed binary's policy
schema, reports both scopes and your device-management state, but `brave://policy`
remains authoritative.

**The policy set is pinned to a version.** It was verified against Brave
`152.1.94.117`; `status` warns when the installed version differs, since Brave may have
added Origin policies since.

**The tests do not run as root.** `./tests/run_tests.sh` covers 51 cases — the
activate/deactivate round trip, typed restores, the earliest-prior merge, scope
separation, receipt refusals, dry runs, an interrupted `activate`, and the installer's
checksum gate — against sandboxed copies of both scripts in a temp directory. It needs no `sudo`, no Brave install
and touches nothing outside `$TMPDIR`, which is what makes it runnable; the cost is that
`/Library/Managed Preferences` itself, `chown root:wheel`, the `sudo -u` privilege drop
and `killall cfprefsd` are exercised only in real use. See `tests/sandbox.sh` for the
four seams the sandbox rewrites.

---

## If you own Brave Origin

The `brave://settings/origin` toggles cannot be reached by scripting. If you have
purchased Origin you do not need to: the supported upgrade flow on standard Brave gives
genuine 1:1 behaviour, including the toggles, because it drives the same
`BraveOriginPolicyManager` this script can only imitate from outside.

`Settings → System → Brave Origin → Refresh Origin`, then restart.

---

## Sources

- [`brave_origin_service_factory.cc`](https://github.com/brave/brave-core/blob/master/browser/brave_origin/brave_origin_service_factory.cc) — the 16 prefs, defaults and `user_settable` flags
- [`brave_simple_policy_map.h`](https://github.com/brave/brave-core/blob/master/browser/policy/brave_simple_policy_map.h) — pref → policy key mapping
- [`brave_profile_policy_provider.cc`](https://github.com/brave/brave-core/blob/master/components/brave_policy/brave_profile_policy_provider.cc) — `POLICY_LEVEL_MANDATORY`, `POLICY_SOURCE_BRAVE`
- [`brave_origin_utils.cc`](https://github.com/brave/brave-core/blob/master/components/brave_origin/brave_origin_utils.cc) — `IsBraveOriginPurchased()`
- [`brave_profile_prefs.cc`](https://github.com/brave/brave-core/blob/master/browser/brave_profile_prefs.cc) — `kShowSidePanelButton` default
- [`metrics_reporting_util.cc`](https://github.com/brave/brave-core/blob/master/browser/metrics/metrics_reporting_util.cc) — metrics default per channel
- [`brave_settings_ui.cc`](https://github.com/brave/brave-core/blob/master/browser/ui/webui/brave_settings_ui.cc) — Survey Panelist gating
- [`brave_search_conversion/utils.cc`](https://github.com/brave/brave-core/blob/master/components/brave_search_conversion/utils.cc) — NTP promo suppression
- [`view_counter_pref_registry.cc`](https://github.com/brave/brave-core/blob/master/components/ntp_background_images/common/view_counter_pref_registry.cc) — branded-wallpaper pref registration
- [`build/config.gni`](https://github.com/brave/brave-core/blob/master/build/config.gni) — user-data directory names
- [`policy_definitions/BraveSoftware/`](https://github.com/brave/brave-core/tree/master/components/policy/resources/templates/policy_definitions/BraveSoftware) — `can_be_recommended`, `dynamic_refresh`
- [`policy_loader_mac.mm`](https://chromium.googlesource.com/chromium/src/+/main/components/policy/core/common/policy_loader_mac.mm) — schema iteration, forced → mandatory, sensitive-policy filtering
- [Brave Group Policy documentation](https://support.brave.app/hc/en-us/articles/360039248271-Group-Policy)
