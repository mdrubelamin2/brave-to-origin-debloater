# brave-to-origin

Applies the preference set that **Brave Origin upgrade mode** enforces to a standard
Brave install, using Brave's own enterprise-policy mechanism. macOS, Linux and Windows.

Every key and value was verified against `brave-core` at `v1.94.117`. Nothing is patched,
repacked or injected into Brave.

## Install

No clone needed. The installer detects your OS, finds installed Brave channels, and asks
what to do.

**macOS and Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/mdrubelamin2/brave-to-origin/main/install.sh | sudo bash
```

**Windows** (PowerShell, as administrator)

```powershell
irm https://raw.githubusercontent.com/mdrubelamin2/brave-to-origin/main/install.ps1 | iex
```

It fetches `origin.sh` / `origin.ps1` at a pinned tag, verifies its SHA-256, runs it, and
deletes it. Non-interactive:

```bash
... | sudo bash -s -- activate --channel com.brave.Browser.beta
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mdrubelamin2/brave-to-origin/main/install.ps1))) -Action status
```

Or clone the repo and run `origin.sh` / `origin.ps1` directly.

**Restart Brave afterwards.** Every policy is `dynamic_refresh: false`. Verify at
`brave://policy`.

## Commands

| | |
|---|---|
| `activate` | Apply the policy set and the standalone-build prefs |
| `deactivate` | Undo exactly what `activate` recorded |
| `status` | Report what is applied. Changes nothing |

| Flag | Effect |
|---|---|
| `--dry-run` / `-DryRun` | Print planned changes, write nothing |
| `--channel <id>` / `-Channel` | Target one install instead of auto-detecting |
| `--machine` (macOS) | Machine-wide policy path instead of per-user |
| `-User` (Windows) | Write `HKCU` instead of `HKLM`. Needs no elevation |
| `--no-color` / `-NoColor` | Suppress ANSI colour |

## What it changes

**16 policies**, at the same `POLICY_LEVEL_MANDATORY` Brave Origin uses.

| Policy | Value | Policy | Value |
|---|---|---|---|
| `TorDisabled` | `true` | `BraveNewsDisabled` | `true` |
| `BraveRewardsDisabled` | `true` | `BraveVPNDisabled` | `true` |
| `BraveWalletDisabled` | `true` | `BraveTalkDisabled` | `true` |
| `BraveAIChatEnabled` | `false` | `BraveStatsPingEnabled` | `false` |
| `BraveP3AEnabled` | `false` | `BraveLocalAIEnabled` | `false` |
| `BraveWaybackMachineEnabled` | `false` | `BraveSpeedreaderEnabled` | `false` |
| `BravePlaylistEnabled` | `false` | `BraveWebDiscoveryEnabled` | `false` |
| `EmailAliasesEnabled` | `false` | `PsstEnabled` | `false` |

**4 prefs**, which have no policy equivalent. Profile prefs apply to `Default` and
`Profile N`, never `System Profile` or `Guest Profile`.

| Pref | Value | Why |
|---|---|---|
| `brave.show_side_panel_button` | `false` | Mirrors Origin's registered default |
| `brave.brave_search_conversion.dismissed` | `true` | Suppresses the NTP search promo |
| `brave.branded_wallpaper_notification_dismissed` | `true` | Closest reachable stand-in for `brave_ads` being compiled out |
| `user_experience_metrics.reporting_enabled` | `false` | Crash and metrics reporting, in `Local State` |

Two policies are inert depending on the build, and are reported as such rather than
counted as applied: `PsstEnabled` does not exist before 1.95, and `BraveVPNDisabled` is
compiled out on Linux.

**What it cannot do:** unlock `brave://settings/origin` (gated on
`IsBraveOriginPurchased()`), shrink the binary (Origin compiles features out), or change
branding and update channel.

## Undo

`activate` writes a receipt before its first change, recording every key it touched and
that key's **prior value and type**. `deactivate` acts only on that receipt. Keys that
were absent are removed, keys that already existed are restored to their exact prior
value and type, and anything not in the receipt is left alone.

Without a receipt, `deactivate` refuses to run. These are the same keys an MDM profile
writes, and deleting those is not its business.

| | Receipt location |
|---|---|
| macOS | `/Library/Application Support/brave-origin-clone/` |
| Linux | `/var/lib/brave-to-origin/` |
| Windows | `%ProgramData%\brave-to-origin\`, or `%LOCALAPPDATA%` with `-User` |

## Platforms

| | Policy store | Scope | Per-channel |
|---|---|---|---|
| macOS | `/Library/Managed Preferences/<user>/<bundle-id>.plist` | user, or machine with `--machine` | yes |
| Linux | `/etc/brave/policies/managed/brave-to-origin.json` | machine only | **no** |
| Windows | `HKLM\SOFTWARE\Policies\BraveSoftware\Brave` | machine, or `HKCU` with `-User` | **no** |

Four things worth knowing:

- **Linux and Windows policies are global.** Every channel reads the same directory or
  registry key, so the store records which channels asked for it and is only removed when
  the last one deactivates.
- **Linux `managed/` is last-file-wins.** `status` lists any other file there that sets
  the same keys, and says which way it sorts.
- **Snap Brave is refused.** Its AppArmor profile cannot read `/etc/brave`, so writing
  there would report success and change nothing. Flatpak works, but needs a restart.
- **On Windows, HKLM beats HKCU.** `-User` needs no elevation but cannot override a
  policy an administrator has already set.

## Development

```bash
./tests/run_tests.sh              # macOS + Linux, 51 cases
pwsh tests/Run-Tests.ps1          # Windows, 21 cases
pwsh tests/Test-Ps51Compat.ps1    # PowerShell 5.1 syntax and encoding gate
./tests/check_release.sh v1.2.3   # pins, checksums, every suite
```

No `sudo`, no Brave install, nothing written outside `$TMPDIR`. The Linux and Windows
backends are tested on macOS by rewriting a copy of the script at its seams: the registry
becomes a JSON file and the system paths move into a temp directory. See
`tests/sandbox.sh` and `tests/WindowsSandbox.ps1`.

[`docs/DESIGN.md`](docs/DESIGN.md) covers why the receipt works the way it does, the
per-platform reasoning, and the claims that source review disproved.

## Limitations

- **`deactivate` has only been proven by the test suites** on Linux and Windows. Real
  machines have run `activate` and `status` on all three platforms.
- **The policy set is pinned to a version.** Verified against `152.1.94.117`. `status`
  warns when the installed version differs.
- **`status` reads files and the registry, not the browser.** `brave://policy` is
  authoritative.
- **Reboot persistence on macOS is untested.** There are reports that `mdmclient` removes
  raw plists from `/Library/Managed Preferences` at boot unless they arrive via a signed
  configuration profile. If policies vanish after a restart, package them as a
  `.mobileconfig`.
- Nothing has exercised the snap refusal, the Flatpak policy linking, or the Windows
  separate-admin-account case.

## If you own Brave Origin

You do not need this. `Settings -> System -> Brave Origin -> Refresh Origin` drives the
same `BraveOriginPolicyManager` from inside, including the `brave://settings/origin`
toggles this cannot reach.

## Sources

- [`brave_origin_service_factory.cc`](https://github.com/brave/brave-core/blob/master/browser/brave_origin/brave_origin_service_factory.cc) - the policy set, defaults and `user_settable` flags
- [`brave_simple_policy_map.h`](https://github.com/brave/brave-core/blob/master/browser/policy/brave_simple_policy_map.h) - pref to policy key mapping
- [`brave_profile_policy_provider.cc`](https://github.com/brave/brave-core/blob/master/components/brave_policy/brave_profile_policy_provider.cc) - `POLICY_LEVEL_MANDATORY`, `POLICY_SOURCE_BRAVE`
- [`brave_profile_prefs.cc`](https://github.com/brave/brave-core/blob/master/browser/brave_profile_prefs.cc) - `kShowSidePanelButton` default
- [`brave_search_conversion/utils.cc`](https://github.com/brave/brave-core/blob/master/components/brave_search_conversion/utils.cc) - NTP promo suppression
- [`view_counter_pref_registry.cc`](https://github.com/brave/brave-core/blob/master/components/ntp_background_images/common/view_counter_pref_registry.cc) - branded-wallpaper pref
- [`metrics_reporting_util.cc`](https://github.com/brave/brave-core/blob/master/browser/metrics/metrics_reporting_util.cc) - metrics default per channel
- [`brave_main_delegate.cc`](https://github.com/brave/brave-core/blob/master/app/brave_main_delegate.cc) - the Linux `/etc/brave/policies` override
- [`policy_loader_mac.mm`](https://chromium.googlesource.com/chromium/src/+/main/components/policy/core/common/policy_loader_mac.mm) and [`policy_loader_win.cc`](https://chromium.googlesource.com/chromium/src/+/main/components/policy/core/common/policy_loader_win.cc) - how each platform reads policy
- [Brave Group Policy documentation](https://support.brave.app/hc/en-us/articles/360039248271-Group-Policy)
