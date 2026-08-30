# =============================================================================
# Brave Origin — policy clone for standard Brave on Windows
# =============================================================================
#
# The Windows half of origin.sh. Same three commands, same guarantees, same
# receipt discipline; only the policy backend differs.
#
# THE WINDOWS POLICY BACKEND
#   Brave reads HKLM\SOFTWARE\Policies\BraveSoftware\Brave and the HKCU key of
#   the same name, HKLM winning on conflict. brave-core patches the product
#   suffix out of the policy path, so that ONE key serves every channel — the
#   Linux situation, where activating stable also policies beta.
#
#   But unlike Linux's own file under managed/, this key is shared with MDM,
#   Group Policy and every other tool that writes Brave policy — the macOS
#   situation, where a prior value has to be captured with its type and put
#   back exactly.
#
#   So this needs both models at once, and has both: per-value typed priors
#   like macOS, and a channel refcount like Linux. The prior is written into
#   the per-channel receipt AND the refcount record. That redundancy is
#   deliberate: losing one record must not lose the only copy of an MDM's
#   values.
#
#   `Recommended` and `3rdparty` under that key are reserved subkeys owned by
#   Chromium's policy system and by extensions. Nothing here writes them, and
#   the key itself is only ever removed when it holds no subkeys at all.
#
# PROVENANCE
#   `activate` records what it changed, and each value's prior and registry
#   type, in a receipt under %ProgramData%\brave-to-origin (or %LOCALAPPDATA%
#   with -User). `deactivate` acts only on that receipt. Without one it will
#   not guess, because these value names are exactly what an MDM would write.
#
# WHAT THIS DOES NOT DO
#   - It does not unlock brave://settings/origin. Those toggles are gated on
#     IsBraveOriginPurchased(), which requires real SKU credentials.
#   - It does not shrink the binary. Origin compiles features out; policy
#     cannot reproduce that.
#   - It does not make the 7 "user_settable" policies user-toggleable. All 16
#     declare can_be_recommended:false, so mandatory is the only level.
#
# Usage:
#   .\origin.ps1 activate|deactivate|status [-User] [-Channel <id>]
#                                           [-DryRun] [-NoColor]
#
# Restart Brave afterwards — every policy is dynamic_refresh:false. `gpupdate
# /force` shortens the <=15-minute policy reload; it does not remove the
# restart. Verify at brave://policy.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('activate', 'deactivate', 'status', 'help')]
    [string]$Command,

    # Channel ID, e.g. com.brave.Browser.beta. The IDs are macOS bundle IDs
    # reused as channel names, exactly as origin.sh reuses them on Linux, so
    # -Channel reads the same on every platform.
    [string]$Channel,

    # Write HKCU instead of HKLM. Needs no elevation, and Brave reads it — but
    # an HKLM value of the same name wins, so this cannot override a policy an
    # administrator or an MDM has already set.
    [switch]$User,

    [switch]$DryRun,
    [switch]$NoColor
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Set to 1 by anything that failed but did not abort the run, so a caller can
# tell "rolled back" from "rolled back except for three values".
$script:ExitCode = 0

# ── Platform ─────────────────────────────────────────────────────────────────
# One line, one place to look, one place to override. $IsWindows does not exist
# in Windows PowerShell 5.1, which is what every Windows 10 and 11 box ships.
$script:IsWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

# The policy set was last checked against this Brave version. Windows reports
# Brave's own version (1.94.117), not the Chromium-major-prefixed string the
# macOS bundle carries, so the number here differs from origin.sh's on purpose.
$script:ValidatedAgainst = '1.94.117'

# How to tell the user to run this again. When install.ps1 fetched the script
# to a temp file, $PSCommandPath is that temp path and repeating it back would
# be useless, so the installer sets this to the command the user actually ran.
$script:SelfCommand = if ($env:ORIGIN_INVOCATION) { $env:ORIGIN_INVOCATION } else { '.\origin.ps1' }

# ── Output ───────────────────────────────────────────────────────────────────
# Write-Host cannot be redirected in 5.1, so everything goes to the success
# stream and errors to stderr. Colour is ANSI, off unless the host says it can
# render it: 5.1's console does not enable virtual terminal sequences on its
# own, and raw escape codes in a transcript are worse than no colour.
$script:CanColor = $false
if (-not $NoColor) {
    try { $script:CanColor = [bool]$Host.UI.SupportsVirtualTerminal } catch { $script:CanColor = $false }
}
$script:Red = ''; $script:Green = ''; $script:Yellow = ''
$script:Cyan = ''; $script:Dim = ''; $script:Bold = ''; $script:Reset = ''
if ($script:CanColor) {
    $e = [char]27
    $script:Red = "$e[0;31m"; $script:Green = "$e[0;32m"; $script:Yellow = "$e[1;33m"
    $script:Cyan = "$e[0;36m"; $script:Dim = "$e[2m"; $script:Bold = "$e[1m"; $script:Reset = "$e[0m"
}

function Write-Info { param([string]$Message) Write-Output ("{0}[*]{1} {2}" -f $script:Cyan, $script:Reset, $Message) }
function Write-Ok { param([string]$Message) Write-Output ("{0}[+]{1} {2}" -f $script:Green, $script:Reset, $Message) }
function Write-Warn { param([string]$Message) Write-Output ("{0}[!]{1} {2}" -f $script:Yellow, $script:Reset, $Message) }
function Write-Fail { param([string]$Message) Write-Output ("{0}[x]{1} {2}" -f $script:Red, $script:Reset, $Message) }
function Write-Skip { param([string]$Message) Write-Output ("{0}[-] {1}{2}" -f $script:Dim, $Message, $script:Reset) }
function Write-Section { param([string]$Title) Write-Output ''; Write-Output ("{0}{1}{2}" -f $script:Bold, $Title, $script:Reset) }

function Stop-WithError {
    param([string]$Message)
    [Console]::Error.WriteLine(("{0}[x]{1} {2}" -f $script:Red, $script:Reset, $Message))
    exit 1
}

function Show-Usage {
    Write-Output ''
    Write-Output ("{0}Usage:{1} {2} <activate|deactivate|status> [options]" -f $script:Bold, $script:Reset, $script:SelfCommand)
    Write-Output ''
    Write-Output '  activate     Apply the Brave Origin policy set and standalone-default prefs'
    Write-Output '  deactivate   Undo exactly what activate recorded in its receipt'
    Write-Output '  status       Report what is applied, and what Brave will actually honour'
    Write-Output ''
    Write-Output ("{0}Options:{1}" -f $script:Bold, $script:Reset)
    Write-Output '  -User            Write HKCU instead of HKLM. No elevation needed, but an'
    Write-Output '                   HKLM value of the same name still wins'
    Write-Output '  -Channel <id>    Target channel, e.g. com.brave.Browser.beta'
    Write-Output '  -DryRun          Show planned changes without writing'
    Write-Output '  -NoColor         Suppress ANSI colour'
    Write-Output ''
}

if ($Command -eq 'help') { Show-Usage; exit 0 }
if (-not $Command) { Show-Usage; exit 1 }
if (-not $script:IsWindowsHost) {
    Stop-WithError 'This script supports Windows only. Use origin.sh on macOS and Linux.'
}

# ── Path roots ───────────────────────────────────────────────────────────────
# Every root this script can touch, one per line, so there is exactly one place
# to look and one place to redirect.
$script:PolicyKeyPathMachine = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$script:PolicyKeyPathUser = 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave'
$script:PolicyKeyPath = if ($User) { $script:PolicyKeyPathUser } else { $script:PolicyKeyPathMachine }
$script:ReceiptDirMachine = Join-Path $env:ProgramData 'brave-to-origin'
$script:ReceiptDirUser = Join-Path $env:LOCALAPPDATA 'brave-to-origin'
$script:ReceiptDir = if ($User) { $script:ReceiptDirUser } else { $script:ReceiptDirMachine }
$script:ProfileRoot = Join-Path $env:LOCALAPPDATA 'BraveSoftware'
$script:ProgramFilesRoot = $env:ProgramFiles
$script:ProgramFilesX86Root = ${env:ProgramFiles(x86)}
$script:LocalAppDataRoot = $env:LOCALAPPDATA
$script:UpdaterKeyRoots = @('SOFTWARE\WOW6432Node\BraveSoftware\Update\Clients', 'SOFTWARE\BraveSoftware\Update\Clients')

$script:Hive = if ($User) { 'HKCU' } else { 'HKLM' }
$script:Scope = if ($User) { 'user' } else { 'machine' }
# Reserved subkeys of the policy key. Chromium owns `Recommended`; extensions
# own `3rdparty`. Removing either would take policy nothing here ever wrote.
$script:ReservedSubKeys = @('Recommended', '3rdparty')

# ── Registry seam ────────────────────────────────────────────────────────────
# Every registry read and write in this script goes through these six
# functions and nothing else. They are the only code here that cannot run
# anywhere but Windows.

function Get-PolicyValueRaw {
    # Returns $null when the value is absent, otherwise @{ Type = <kind>;
    # Value = <object> }. Absence and an empty string are different answers:
    # an empty REG_SZ read as "missing" would be deleted on rollback and
    # reported as removed by a delete that never happened.
    param([string]$KeyPath, [string]$Name)
    $key = Get-Item -LiteralPath $KeyPath -ErrorAction SilentlyContinue
    if ($null -eq $key) { return $null }
    if (@($key.GetValueNames()) -notcontains $Name) { return $null }
    $kind = $key.GetValueKind($Name)
    # DoNotExpandEnvironmentNames: a REG_EXPAND_SZ must be recorded as the
    # unexpanded text it holds, or the restore writes the expansion back.
    $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return @{ Type = [string]$kind; Value = $value }
}

function Set-PolicyValueRaw {
    # Creates the key if it is absent. Never verifies — the caller reads the
    # value back, because a write that reports success and did not land is the
    # failure this whole tool exists to make visible.
    param([string]$KeyPath, [string]$Name, $Value, [string]$Type)
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        New-Item -Path $KeyPath -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -LiteralPath $KeyPath -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}

function Remove-PolicyValueRaw {
    param([string]$KeyPath, [string]$Name)
    Remove-ItemProperty -LiteralPath $KeyPath -Name $Name -Force -ErrorAction SilentlyContinue
}

function Test-PolicyKeyExists {
    param([string]$KeyPath)
    return (Test-Path -LiteralPath $KeyPath)
}

function Get-PolicyValueNames {
    # Every value under the key, ours and everyone else's. Only the key-removal
    # guard needs this, and it needs the foreign ones: a key still holding an
    # MDM's values must survive.
    param([string]$KeyPath)
    $key = Get-Item -LiteralPath $KeyPath -ErrorAction SilentlyContinue
    if ($null -eq $key) { return @() }
    return @($key.GetValueNames())
}

function Get-PolicySubKeyNames {
    param([string]$KeyPath)
    $key = Get-Item -LiteralPath $KeyPath -ErrorAction SilentlyContinue
    if ($null -eq $key) { return @() }
    return @($key.GetSubKeyNames())
}

function Get-UpdaterVersion {
    # `pv` under the updater's Clients key is what Brave's own updater writes,
    # and it is the only source that names the version actually installed
    # rather than the newest one staged on disk.
    param([string]$Guid, [string]$Hive)
    foreach ($root in $script:UpdaterKeyRoots) {
        $path = "${Hive}:\$root\$Guid"
        $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $key) { continue }
        if (@($key.GetValueNames()) -notcontains 'pv') { continue }
        $pv = [string]$key.GetValue('pv')
        if ($pv) { return $pv }
    }
    return $null
}

function Test-Elevated {
    # Administrators-group membership of the *current token*, which is what
    # decides whether HKLM is writable — not whether the account is an admin.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-BraveRunning {
    # The process is brave.exe on every channel, so the executable path is the
    # only thing that tells the channels apart.
    param([string]$ExePath)
    foreach ($proc in @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $proc.Path } catch { $path = $null }
        if ($path -and $path -eq $ExePath) { return $true }
    }
    # Get-Process cannot read .Path for another user's process without
    # elevation, and a second signed-in user with Brave open rewrites
    # Preferences on exit just the same. WMI answers where the .NET property
    # is denied.
    try {
        $rows = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='brave.exe'" -ErrorAction Stop)
    } catch {
        return $false
    }
    foreach ($row in $rows) {
        if ($row.ExecutablePath -and $row.ExecutablePath -eq $ExePath) { return $true }
    }
    return $false
}

function Protect-ReceiptDirectory {
    # A receipt holds the user's own profile-pref values, which nothing but an
    # administrator has any business reading back out of %ProgramData%. Only
    # ever called on a directory this run created: an existing one may have
    # been tightened deliberately, and widening it back is not our call.
    # Well-known SIDs, not names, because "Administrators" is localised.
    param([string]$Path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $account = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $account, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# ── The 16 Brave Origin policies ─────────────────────────────────────────────
# brave_origin_service_factory.cc: kBraveOriginBrowserMetadata (4) and
# kBraveOriginProfileMetadata (12). Keys via brave_simple_policy_map.h.
# Booleans are REG_DWORD 0/1 on Windows; there is no REG_SZ "true".
$script:Policies = @(
    @{ Key = 'TorDisabled'; Value = $true; Settable = 'locked' }
    @{ Key = 'BraveStatsPingEnabled'; Value = $false; Settable = 'settable' }
    @{ Key = 'BraveP3AEnabled'; Value = $false; Settable = 'settable' }
    @{ Key = 'BraveLocalAIEnabled'; Value = $false; Settable = 'settable' }
    @{ Key = 'BraveWaybackMachineEnabled'; Value = $false; Settable = 'settable' }
    @{ Key = 'BraveRewardsDisabled'; Value = $true; Settable = 'locked' }
    @{ Key = 'BraveWalletDisabled'; Value = $true; Settable = 'locked' }
    @{ Key = 'BraveAIChatEnabled'; Value = $false; Settable = 'locked' }
    @{ Key = 'BraveSpeedreaderEnabled'; Value = $false; Settable = 'settable' }
    @{ Key = 'BravePlaylistEnabled'; Value = $false; Settable = 'settable' }
    @{ Key = 'BraveNewsDisabled'; Value = $true; Settable = 'locked' }
    @{ Key = 'BraveVPNDisabled'; Value = $true; Settable = 'locked' }
    @{ Key = 'BraveTalkDisabled'; Value = $true; Settable = 'locked' }
    @{ Key = 'BraveWebDiscoveryEnabled'; Value = $false; Settable = 'settable' }
    @{ Key = 'EmailAliasesEnabled'; Value = $false; Settable = 'locked' }
    @{ Key = 'PsstEnabled'; Value = $false; Settable = 'locked' }
)

# Linux compiles BraveVPNDisabled out; Windows does not. enable_brave_vpn_v1
# and v2 both list is_win, and none of the 16 is flagged sensitive:true, so
# none is filtered on a consumer machine that is neither domain-joined nor
# MDM-enrolled. Every key applies here.
$script:UnsupportedKeys = @()

# Standalone-build defaults with no policy equivalent.
$script:ProfilePrefs = @(
    @{ Name = 'brave.show_side_panel_button'; Value = $false }
    @{ Name = 'brave.brave_search_conversion.dismissed'; Value = $true }
    @{ Name = 'brave.branded_wallpaper_notification_dismissed'; Value = $true }
)
# Crash/metrics reporting is a pref, not the MetricsReportingEnabled policy:
# that policy is sensitive:true, and origin.sh's reasoning for preferring the
# pref holds here too — the pref works whatever the management state is.
$script:LocalStatePrefs = @(
    @{ Name = 'user_experience_metrics.reporting_enabled'; Value = $false }
)

# Registry types whose value can be put back exactly as it was found. A
# REG_BINARY or REG_MULTI_SZ has no faithful single-value representation in a
# JSON receipt, and writing a substitute would destroy the original — those
# are refused, never guessed at.
$script:RestorableKinds = @('String', 'ExpandString', 'DWord', 'QWord')

# ── Channels ─────────────────────────────────────────────────────────────────
# One policy key serves all four, so these differ only in where they are
# installed, where their profile lives, and which updater GUID reports their
# version.
$script:Channels = @(
    @{ Id = 'com.brave.Browser'; Suffix = ''; Name = 'Brave'; Guid = '{AFE6A462-C574-4B8A-AF43-4CC60DF4563B}' }
    @{ Id = 'com.brave.Browser.beta'; Suffix = '-Beta'; Name = 'Brave Beta'; Guid = '{103BD053-949B-43A8-9120-2E424887DE11}' }
    @{ Id = 'com.brave.Browser.dev'; Suffix = '-Dev'; Name = 'Brave Dev'; Guid = '{CB2150F2-595F-4633-891A-E39720CE0531}' }
    @{ Id = 'com.brave.Browser.nightly'; Suffix = '-Nightly'; Name = 'Brave Nightly'; Guid = '{C6CB981E-DB30-4876-8639-109F8933582C}' }
)

function Get-ChannelExePath {
    # All three install locations are probed, first hit wins. Machine vs
    # per-user is decided by which root the exe was found under; it does NOT
    # decide which hive gets written, because the policy key is not per-install.
    param([hashtable]$ChannelInfo)
    $roots = @(
        @{ Root = $script:ProgramFilesRoot; Machine = $true }
        @{ Root = $script:ProgramFilesX86Root; Machine = $true }
        @{ Root = $script:LocalAppDataRoot; Machine = $false }
    )
    foreach ($candidate in $roots) {
        if (-not $candidate.Root) { continue }
        $dir = Join-Path $candidate.Root ('BraveSoftware\Brave-Browser' + $ChannelInfo.Suffix + '\Application')
        $exe = Join-Path $dir 'brave.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            return @{ Exe = $exe; AppDir = $dir; Machine = $candidate.Machine }
        }
    }
    return $null
}

function Expand-UserDataDirTemplate {
    # Brave expands ${name}, NOT %VAR%. A literal %LOCALAPPDATA% in this value
    # stays literal, so expanding environment variables here would produce a
    # path Brave never uses. Chromium's own substitution list, in
    # policy/core/common/policy_paths / path_parser_win.cc.
    param([string]$Template)
    $map = @{
        'machine_name'     = $env:COMPUTERNAME
        'user_name'        = $env:USERNAME
        'documents'        = [Environment]::GetFolderPath('MyDocuments')
        'local_app_data'   = $env:LOCALAPPDATA
        'roaming_app_data' = $env:APPDATA
        'profile'          = $env:USERPROFILE
        'global_app_data'  = $env:ProgramData
        'program_files'    = $env:ProgramFiles
        'windows'          = $env:SystemRoot
        # Terminal-services values. Absent outside an RDP session, in which
        # case Brave substitutes an empty string and so does this.
        'client_name'      = $env:CLIENTNAME
        'session_name'     = $env:SESSIONNAME
    }
    $result = $Template
    foreach ($name in $map.Keys) {
        $replacement = $map[$name]
        if ($null -eq $replacement) { $replacement = '' }
        $result = $result.Replace('${' + $name + '}', $replacement)
    }
    return $result
}

function Get-UserDataDirOverride {
    # HKLM first, then HKCU, matching Brave's own precedence. The value
    # relocates the profile for EVERY channel, since the policy key is shared.
    foreach ($keyPath in @($script:PolicyKeyPathMachine, $script:PolicyKeyPathUser)) {
        $raw = Get-PolicyValueRaw -KeyPath $keyPath -Name 'UserDataDir'
        if ($null -eq $raw) { continue }
        $text = [string]$raw.Value
        if (-not $text) { continue }
        # One pair of surrounding quotes, the way a value pasted out of a
        # command line arrives. Only one pair: a path may legitimately end in
        # a quote character.
        if ($text.Length -ge 2 -and $text.StartsWith('"') -and $text.EndsWith('"')) {
            $text = $text.Substring(1, $text.Length - 2)
        }
        return (Expand-UserDataDirTemplate -Template $text)
    }
    return $null
}

function Get-ChannelUserDataDir {
    param([hashtable]$ChannelInfo)
    $override = Get-UserDataDirOverride
    if ($override) { return $override }
    # Windows keeps the "User Data" component that Linux drops.
    return (Join-Path $script:ProfileRoot ('Brave-Browser' + $ChannelInfo.Suffix + '\User Data'))
}

function Get-BraveVersion {
    param([hashtable]$ChannelInfo, $Install)
    if ($null -ne $Install) {
        $hive = if ($Install.Machine) { 'HKLM' } else { 'HKCU' }
        $pv = Get-UpdaterVersion -Guid $ChannelInfo.Guid -Hive $hive
        if ($pv) { return $pv }
        # Second: the versioned subdirectory beside brave.exe. Parsed as
        # [version], never sorted as text — "1.94.117" sorts after "1.100.4".
        $best = $null
        foreach ($dir in @(Get-ChildItem -LiteralPath $Install.AppDir -Directory -ErrorAction SilentlyContinue)) {
            $parsed = $null
            if ([System.Version]::TryParse($dir.Name, [ref]$parsed)) {
                if ($null -eq $best -or $parsed -gt $best) { $best = $parsed }
            }
        }
        if ($null -ne $best) { return $best.ToString() }
        try {
            $product = (Get-Item -LiteralPath $Install.Exe).VersionInfo.ProductVersion
            if ($product) { return ([string]$product).Trim() }
        } catch {
            # brave.exe is a stub whose resources an antivirus lock can make
            # unreadable; an unknown version is not a reason to stop.
        }
    }
    return 'unknown'
}

# ── Capability probe ─────────────────────────────────────────────────────────
# The policy loader walks the compiled-in schema and only queries keys it finds
# there. An unknown key is never read: no value, no error, no row at
# brave://policy. Probing the shipped binary makes that visible rather than
# silent, the same way origin.sh probes the framework with `strings`.
$script:SupportedKeys = $null
$script:ProbeUnavailable = '__PROBE_UNAVAILABLE__'

function Get-PolicyProbeFile {
    # The policy schema is linked into the big content DLL beside brave.exe,
    # whose name has changed across Chromium versions. The largest DLL in the
    # versioned directory is that file whatever it is called this release.
    param($Install)
    if ($null -eq $Install) { return $null }
    $best = $null
    foreach ($dir in @(Get-ChildItem -LiteralPath $Install.AppDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
            if ($null -eq $best -or $file.Length -gt $best.Length) { $best = $file }
        }
    }
    if ($null -ne $best) { return $best.FullName }
    return $Install.Exe
}

function Find-AsciiNeedles {
    # Chunked ordinal scan. The needles are ASCII policy names, so the bytes
    # can be read as ASCII without decoding the file. Chunks overlap by the
    # longest needle so a name straddling a boundary is still found.
    param([string]$Path, [string[]]$Needles)
    $found = New-Object 'System.Collections.Generic.HashSet[string]'
    $longest = 0
    foreach ($needle in $Needles) { if ($needle.Length -gt $longest) { $longest = $needle.Length } }
    $chunk = 1048576
    $buffer = New-Object byte[] $chunk
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $carry = ''
        while ($true) {
            $read = $stream.Read($buffer, 0, $chunk)
            if ($read -le 0) { break }
            $text = $carry + [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
            foreach ($needle in $Needles) {
                if (-not $found.Contains($needle) -and $text.Contains($needle)) { [void]$found.Add($needle) }
            }
            if ($found.Count -eq $Needles.Count) { break }
            $keep = [Math]::Min($longest, $text.Length)
            $carry = $text.Substring($text.Length - $keep)
        }
    } finally {
        $stream.Dispose()
    }
    return @($found)
}

function Initialize-SupportedKeys {
    param($Install)
    $probeFile = Get-PolicyProbeFile -Install $Install
    if (-not $probeFile -or -not (Test-Path -LiteralPath $probeFile -PathType Leaf)) {
        Write-Warn 'Brave binary not found; cannot verify which policies this build knows.'
        $script:SupportedKeys = @($script:ProbeUnavailable)
        return
    }
    $names = @($script:Policies | ForEach-Object { $_.Key })
    try {
        $hits = Find-AsciiNeedles -Path $probeFile -Needles $names
    } catch {
        Write-Warn ("Could not read {0} for the capability probe; treating build support as unknown." -f $probeFile)
        $script:SupportedKeys = @($script:ProbeUnavailable)
        return
    }
    # Any real Brave binary contains at least TorDisabled. Zero matches means
    # the probe failed, not that Brave supports nothing — do not act on it.
    if (@($hits).Count -eq 0) {
        Write-Warn 'Capability probe returned nothing; treating build support as unknown.'
        $script:SupportedKeys = @($script:ProbeUnavailable)
        return
    }
    $script:SupportedKeys = @($hits)
}

function Test-KeySupported {
    param([string]$Key)
    if ($script:UnsupportedKeys -contains $Key) { return $false }
    if ($null -eq $script:SupportedKeys) { return $true }
    if ($script:SupportedKeys -contains $script:ProbeUnavailable) { return $true }
    return ($script:SupportedKeys -contains $Key)
}

# ── JSON text editing ────────────────────────────────────────────────────────
# Preferences and Local State are edited as TEXT, not by parsing to objects and
# writing them back. Windows PowerShell 5.1's ConvertFrom-Json collapses every
# JSON number to Int32/Int64/Double, so a round trip rewrites 2.0 as 2 and
# Chromium then discards the pref as the wrong type — silent data loss in a
# file this tool promises to leave otherwise untouched.
#
# So a scanner walks the raw text, finds the exact span of the value on a
# dotted path, and splices. Everything outside that span is byte-identical,
# and the prior is recorded as the raw JSON token, which restores exactly.

function Get-JsonValueEnd {
    # $Index is the first character of a JSON value. Returns one past its last.
    param([string]$Text, [int]$Index)
    $c = $Text[$Index]
    if ($c -eq '"') {
        $i = $Index + 1
        while ($i -lt $Text.Length) {
            if ($Text[$i] -eq '\') { $i += 2; continue }
            if ($Text[$i] -eq '"') { return $i + 1 }
            $i++
        }
        throw 'unterminated string'
    }
    if ($c -eq '{' -or $c -eq '[') {
        $depth = 0
        $i = $Index
        $inString = $false
        while ($i -lt $Text.Length) {
            $ch = $Text[$i]
            if ($inString) {
                if ($ch -eq '\') { $i += 2; continue }
                if ($ch -eq '"') { $inString = $false }
            } elseif ($ch -eq '"') {
                $inString = $true
            } elseif ($ch -eq '{' -or $ch -eq '[') {
                $depth++
            } elseif ($ch -eq '}' -or $ch -eq ']') {
                $depth--
                if ($depth -eq 0) { return $i + 1 }
            }
            $i++
        }
        throw 'unterminated container'
    }
    # true / false / null / number, all of which end at a structural character.
    $i = $Index
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq ',' -or $ch -eq '}' -or $ch -eq ']' -or [char]::IsWhiteSpace($ch)) { break }
        $i++
    }
    if ($i -eq $Index) { throw 'empty value' }
    return $i
}

function Get-JsonValueKind {
    param([string]$Text, [int]$Index)
    switch ($Text[$Index]) {
        '"' { return 'string' }
        '{' { return 'object' }
        '[' { return 'array' }
        't' { return 'boolean' }
        'f' { return 'boolean' }
        'n' { return 'null' }
        default { return 'number' }
    }
}

function Skip-JsonWhitespace {
    param([string]$Text, [int]$Index)
    $i = $Index
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    return $i
}

function Find-JsonMember {
    # Walks the members of the object whose '{' is at $ObjectStart, one level
    # only. Returns $null when the name is absent.
    param([string]$Text, [int]$ObjectStart, [string]$Name)
    $i = Skip-JsonWhitespace -Text $Text -Index ($ObjectStart + 1)
    while ($i -lt $Text.Length -and $Text[$i] -ne '}') {
        if ($Text[$i] -ne '"') { throw 'malformed object member' }
        $memberStart = $i
        $keyEnd = Get-JsonValueEnd -Text $Text -Index $i
        # Chromium pref keys are plain ASCII, so the literal between the quotes
        # is the name. A \u-escaped key would not match, and would then read as
        # absent rather than as something to overwrite.
        $key = $Text.Substring($memberStart + 1, $keyEnd - $memberStart - 2)
        $i = Skip-JsonWhitespace -Text $Text -Index $keyEnd
        if ($Text[$i] -ne ':') { throw 'malformed object member' }
        $valueStart = Skip-JsonWhitespace -Text $Text -Index ($i + 1)
        $valueEnd = Get-JsonValueEnd -Text $Text -Index $valueStart
        if ($key -ceq $Name) {
            return @{
                MemberStart = $memberStart
                MemberEnd   = $valueEnd
                ValueStart  = $valueStart
                ValueEnd    = $valueEnd
                Kind        = (Get-JsonValueKind -Text $Text -Index $valueStart)
            }
        }
        $i = Skip-JsonWhitespace -Text $Text -Index $valueEnd
        if ($i -lt $Text.Length -and $Text[$i] -eq ',') {
            $i = Skip-JsonWhitespace -Text $Text -Index ($i + 1)
        }
    }
    return $null
}

function Resolve-JsonPath {
    # Walks a dotted path. Returns Found with the leaf's spans, or the deepest
    # object that does exist so a caller can insert into it.
    param([string]$Text, [string[]]$Parts)
    $root = Skip-JsonWhitespace -Text $Text -Index 0
    if ($root -ge $Text.Length -or $Text[$root] -ne '{') { throw 'top level is not a JSON object' }
    $objectStart = $root
    for ($depth = 0; $depth -lt $Parts.Length; $depth++) {
        $member = Find-JsonMember -Text $Text -ObjectStart $objectStart -Name $Parts[$depth]
        if ($null -eq $member) {
            return @{ Found = $false; Blocked = $false; ContainerStart = $objectStart; Depth = $depth }
        }
        if ($depth -eq $Parts.Length - 1) {
            $member.Found = $true
            $member.Blocked = $false
            $member.ContainerStart = $objectStart
            $member.Depth = $depth
            return $member
        }
        if ($member.Kind -ne 'object') {
            # An intermediate that is not an object cannot be descended into,
            # and replacing it with one would destroy a value no rollback could
            # rebuild. origin.sh's Python overwrites it; refusing is the same
            # decision it makes for a leaf holding a container.
            return @{ Found = $false; Blocked = $true; BlockedAt = $Parts[$depth]; BlockedKind = $member.Kind; Depth = $depth }
        }
        $objectStart = $member.ValueStart
    }
    throw 'empty path'
}

function Get-JsonPrefRecord {
    # The receipt's record for one pref: its JSON type and its raw token.
    param([string]$Text, [string]$Name)
    $found = Resolve-JsonPath -Text $Text -Parts ($Name.Split('.'))
    if ($found.Blocked) { return @{ type = 'blocked'; blocked_at = $found.BlockedAt; blocked_kind = $found.BlockedKind } }
    if (-not $found.Found) { return @{ type = 'absent' } }
    return @{ type = $found.Kind; value = $Text.Substring($found.ValueStart, $found.ValueEnd - $found.ValueStart) }
}

function Set-JsonPrefText {
    # Splices $Literal in as the value at the dotted path, creating any missing
    # objects along it. Returns the new text.
    param([string]$Text, [string]$Name, [string]$Literal)
    $parts = $Name.Split('.')
    $found = Resolve-JsonPath -Text $Text -Parts $parts
    if ($found.Blocked) { throw ("{0} is a JSON {1}, not an object" -f $found.BlockedAt, $found.BlockedKind) }
    if ($found.Found) {
        return $Text.Substring(0, $found.ValueStart) + $Literal + $Text.Substring($found.ValueEnd)
    }
    # Build the missing tail: "b":{"c":<literal>} for a path a.b.c missing at b.
    $fragment = $Literal
    for ($i = $parts.Length - 1; $i -gt $found.Depth; $i--) {
        $fragment = '"' + $parts[$i] + '":' + $fragment
        $fragment = '{' + $fragment + '}'
    }
    $fragment = '"' + $parts[$found.Depth] + '":' + $fragment
    $body = Skip-JsonWhitespace -Text $Text -Index ($found.ContainerStart + 1)
    if ($body -lt $Text.Length -and $Text[$body] -ne '}') { $fragment = $fragment + ',' }
    return $Text.Substring(0, $found.ContainerStart + 1) + $fragment + $Text.Substring($found.ContainerStart + 1)
}

function Remove-JsonPrefText {
    # Removes the member at the dotted path, then any container the removal
    # left empty — the same tidy-up origin.sh's unset_path does.
    param([string]$Text, [string]$Name)
    $parts = @($Name.Split('.'))
    $result = $Text
    for ($depth = $parts.Length - 1; $depth -ge 0; $depth--) {
        $slice = @($parts[0..$depth])
        $found = Resolve-JsonPath -Text $result -Parts $slice
        if ($found.Blocked -or -not $found.Found) { break }
        if ($depth -lt $parts.Length - 1) {
            # Only drop a parent that the leaf's removal actually emptied.
            if ($found.Kind -ne 'object') { break }
            $body = Skip-JsonWhitespace -Text $result -Index ($found.ValueStart + 1)
            if ($result[$body] -ne '}') { break }
        }
        $start = $found.MemberStart
        $end = $found.MemberEnd
        # Take one adjacent comma with it, whichever side has one, or the
        # object is left with a dangling separator.
        $before = $start - 1
        while ($before -ge 0 -and [char]::IsWhiteSpace($result[$before])) { $before-- }
        $after = Skip-JsonWhitespace -Text $result -Index $end
        if ($before -ge 0 -and $result[$before] -eq ',') {
            $start = $before
        } elseif ($after -lt $result.Length -and $result[$after] -eq ',') {
            $end = $after + 1
        }
        $result = $result.Substring(0, $start) + $result.Substring($end)
    }
    return $result
}

function Read-JsonFileText {
    param([string]$Path)
    # Chromium writes these files as UTF-8 with no BOM. ReadAllText would strip
    # one silently and the rewrite would drop it, so read the bytes.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # Named, because U+FEFF is not whitespace: without this the JSON scanner
    # reports "top level is not a JSON object", which is a safe refusal wearing
    # a misleading reason.
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'starts with a UTF-8 BOM, which Chromium does not write'
    }
    # throwOnInvalidBytes: the permissive decoder turns a bad byte into U+FFFD,
    # and the rewrite would then persist that replacement — corrupting a file
    # this tool promises to leave byte-identical outside the span it edits.
    return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
}

function Write-FileAtomic {
    # Temp file in the same directory, flushed to disk, then replaced. A
    # truncating write that fails partway destroys a profile.
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ('.brave-to-origin-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $stream = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)   # $true: to the disk, not just the OS cache
    } finally {
        $stream.Dispose()
    }
    try {
        if (Test-Path -LiteralPath $Path) {
            # File.Replace is the atomic swap; Move-Item is not, and would
            # leave nothing at the path if it failed between the two steps.
            # [NullString]::Value, not $null: PowerShell binds a bare $null to
            # a .NET string parameter as "", and Replace rejects an empty
            # backup path.
            [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# ── Receipt ──────────────────────────────────────────────────────────────────
# The schema every reader and writer agrees on. A receipt that parses but has
# no policies_prior is worse than no receipt at all: deactivate would find
# nothing to restore, count no failures, and then delete the file.

function Test-JsonObject {
    param($Value)
    if ($null -eq $Value) { return $false }
    return ($Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject')
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-JsonArrayProperty {
    # Asked instead of type-testing what Get-Prop returned: a function's return
    # value is unrolled, so a one-element channel list arrives as a bare string
    # and would be rejected as malformed. A bool cannot be unrolled.
    param($Object, [string]$Name)
    if (-not (Test-JsonObject $Object)) { return $false }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $false }
    return ($property.Value -is [System.Array])
}

function Test-PriorRecordShape {
    # Returns the complaint, or $null. A prior whose recorded value cannot be
    # turned back into the type it claims is unusable, and finding that out
    # mid-rollback is finding it out too late: prefs are already restored and
    # some values already put back.
    param($Record, [string]$Name)
    if (-not (Test-JsonObject $Record)) { return ('prior for "{0}" is not a JSON object' -f $Name) }
    $type = Get-Prop -Object $Record -Name 'type'
    if ($null -eq $type -or $type -isnot [string]) { return ('prior for "{0}" has no type' -f $Name) }
    if ($type -eq 'absent') { return $null }
    # A type outside RestorableKinds is refused with a message during rollback,
    # never substituted, so it is a usable record of "leave this alone".
    if ($script:RestorableKinds -notcontains $type) { return $null }
    $value = Get-Prop -Object $Record -Name 'value'
    if ($null -eq $value) { return ('prior for "{0}" is a {1} with no value' -f $Name, $type) }
    $text = [string]$value
    if ($type -eq 'DWord') {
        $number = 0
        if (-not [int]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            return ('prior for "{0}" is a REG_DWORD holding "{1}", which is not a number' -f $Name, $text)
        }
    }
    if ($type -eq 'QWord') {
        $number = [long]0
        if (-not [long]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            return ('prior for "{0}" is a REG_QWORD holding "{1}", which is not a number' -f $Name, $text)
        }
    }
    return $null
}

function Test-ReceiptShape {
    # Returns the complaint, or $null when the receipt is usable.
    param($Receipt)
    if (-not (Test-JsonObject $Receipt)) { return 'receipt is not a JSON object' }
    foreach ($field in @('policy_key', 'channel')) {
        $value = Get-Prop -Object $Receipt -Name $field
        if ($null -eq $value) { return ('receipt is missing "{0}"' -f $field) }
        if ($value -isnot [string]) { return ('receipt field "{0}" has the wrong type' -f $field) }
    }
    foreach ($field in @('policies_prior', 'prefs_prior')) {
        $value = Get-Prop -Object $Receipt -Name $field
        if ($null -eq $value) { return ('receipt is missing "{0}"' -f $field) }
        if (-not (Test-JsonObject $value)) { return ('receipt field "{0}" has the wrong type' -f $field) }
    }
    foreach ($property in (Get-Prop -Object $Receipt -Name 'policies_prior').PSObject.Properties) {
        $complaint = Test-PriorRecordShape -Record $property.Value -Name $property.Name
        if ($complaint) { return $complaint }
    }
    return $null
}

function Get-ReceiptDirForHive {
    # The two hives keep their receipts in different directories, and a
    # hive-suffixed filename joined onto only one of them can never be found:
    # every cross-scope check has to resolve the directory from the hive, not
    # from the scope this run happens to target.
    param([string]$Hive)
    if ($Hive.ToLower() -eq 'hkcu') { return $script:ReceiptDirUser }
    return $script:ReceiptDirMachine
}

function Get-ReceiptPath {
    # <channel>.<hive>.json. The hive is in the name because one channel can be
    # activated in both, and a single receipt can only describe one of them —
    # the other would be left enforcing policy with nothing able to roll it back.
    param([string]$ChannelId, [string]$Hive)
    return (Join-Path (Get-ReceiptDirForHive -Hive $Hive) ("{0}.{1}.json" -f $ChannelId, $Hive.ToLower()))
}

function Get-RefcountPath {
    param([string]$Hive)
    return (Join-Path (Get-ReceiptDirForHive -Hive $Hive) ("policy-key.{0}.json" -f $Hive.ToLower()))
}

function Read-JsonRecord {
    # $null when the file is absent. Throws when it is there and unreadable,
    # because a malformed record holds the only copy of a prior and must abort
    # the run rather than be replaced.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = Read-JsonFileText -Path $Path
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        throw ("{0} is not valid JSON: {1}" -f $Path, $_.Exception.Message)
    }
}

function Write-JsonRecord {
    param([string]$Path, $Object)
    if (-not (Test-Path -LiteralPath $script:ReceiptDir -PathType Container)) {
        New-Item -Path $script:ReceiptDir -ItemType Directory -Force | Out-Null
        if (-not $User) {
            try {
                Protect-ReceiptDirectory -Path $script:ReceiptDir
            } catch {
                Write-Warn ("Could not restrict permissions on {0}: {1}" -f $script:ReceiptDir, $_.Exception.Message)
            }
        }
    }
    # -Depth: 5.1 defaults to 2 and silently renders anything deeper as a type
    # name, which would turn every prior into the string "System.Collections...".
    Write-FileAtomic -Path $Path -Text (($Object | ConvertTo-Json -Depth 10) + "`r`n")
}

# ── Priors ───────────────────────────────────────────────────────────────────

function Get-PolicyPriors {
    # Every prior value read, with its registry type, BEFORE the first write.
    # Returns Priors (ordered hashtable) and Refused (key -> reason) for values
    # whose type cannot be restored faithfully.
    param([string]$KeyPath)
    $priors = [ordered]@{}
    $refused = @{}
    foreach ($policy in $script:Policies) {
        $raw = Get-PolicyValueRaw -KeyPath $KeyPath -Name $policy.Key
        if ($null -eq $raw) {
            $priors[$policy.Key] = @{ type = 'absent' }
            continue
        }
        if ($script:RestorableKinds -notcontains $raw.Type) {
            $refused[$policy.Key] = ("prior is a REG_{0}" -f $raw.Type.ToUpper())
            continue
        }
        # Recorded in its own JSON type, not stringified: a REG_DWORD 5 belongs
        # in the receipt as 5. Casting it to text invents a representation the
        # registry never held, and the restore has to parse it back anyway.
        $priors[$policy.Key] = @{ type = $raw.Type; value = $raw.Value }
    }
    return @{ Priors = $priors; Refused = $refused }
}

function ConvertTo-PriorTable {
    # A priors object read back out of a receipt, as a hashtable of hashtables.
    param($JsonObject)
    $table = [ordered]@{}
    if (-not (Test-JsonObject $JsonObject)) { return $table }
    foreach ($property in $JsonObject.PSObject.Properties) {
        $record = $property.Value
        if (-not (Test-JsonObject $record)) { continue }
        $entry = @{}
        foreach ($field in $record.PSObject.Properties) { $entry[$field.Name] = $field.Value }
        $table[$property.Name] = $entry
    }
    return $table
}

function Merge-Priors {
    # Earliest wins. Re-running activate must not record the values the
    # previous run installed as if they were the untouched machine's.
    param($Newest, $Older)
    $merged = [ordered]@{}
    foreach ($key in $Newest.Keys) { $merged[$key] = $Newest[$key] }
    foreach ($key in $Older.Keys) { $merged[$key] = $Older[$key] }
    return $merged
}

function Restore-PolicyValue {
    # Puts one value back with the type it was recorded under, then reads it
    # back: a DWord 1 that returned as a string "1" is a failed restore, not a
    # silent type change. Returns $true only when the readback matches.
    param([string]$KeyPath, [string]$Name, [hashtable]$Prior)
    $type = [string]$Prior['type']
    $text = [string]$Prior['value']
    $value = $null
    # TryParse, not Parse: a receipt whose recorded value is not a number is a
    # failure this run must report and count, not a raw .NET FormatException
    # thrown out of the middle of a rollback that has already restored prefs.
    switch ($type) {
        'DWord' {
            $number = 0
            if (-not [int]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $false }
            $value = $number
        }
        'QWord' {
            $number = [long]0
            if (-not [long]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $false }
            $value = $number
        }
        'String' { $value = $text }
        'ExpandString' { $value = $text }
        default { return $false }
    }
    try {
        Set-PolicyValueRaw -KeyPath $KeyPath -Name $Name -Value $value -Type $type
    } catch {
        return $false
    }
    $back = Get-PolicyValueRaw -KeyPath $KeyPath -Name $Name
    if ($null -eq $back) { return $false }
    return ($back.Type -eq $type -and ([string]$back.Value) -eq $text)
}

function Remove-PolicyValueVerified {
    param([string]$KeyPath, [string]$Name)
    Remove-PolicyValueRaw -KeyPath $KeyPath -Name $Name
    return ($null -eq (Get-PolicyValueRaw -KeyPath $KeyPath -Name $Name))
}

function Remove-PolicyKeyIfEmpty {
    # Only when the key holds no values and no subkeys at all. `Recommended`
    # and `3rdparty` are somebody else's policy; -Recurse is absent on purpose
    # so that even a wrong count cannot take them.
    param([string]$KeyPath)
    if (-not (Test-PolicyKeyExists -KeyPath $KeyPath)) { return $false }
    if (@(Get-PolicySubKeyNames -KeyPath $KeyPath).Count -gt 0) { return $false }
    if (@(Get-PolicyValueNames -KeyPath $KeyPath).Count -gt 0) { return $false }
    try {
        Remove-Item -LiteralPath $KeyPath -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# ── Channel selection ────────────────────────────────────────────────────────

function Test-ChannelHasReceipt {
    param([string]$ChannelId)
    foreach ($hive in @('hklm', 'hkcu')) {
        if (Test-Path -LiteralPath (Get-ReceiptPath -ChannelId $ChannelId -Hive $hive) -PathType Leaf) {
            return $true
        }
    }
    return $false
}

$script:Installs = @{}
foreach ($channelInfo in $script:Channels) {
    $install = Get-ChannelExePath -ChannelInfo $channelInfo
    if ($null -ne $install) { $script:Installs[$channelInfo.Id] = $install }
}

$script:Target = $null
$script:TargetInstall = $null
if ($Channel) {
    foreach ($channelInfo in $script:Channels) {
        if ($channelInfo.Id -eq $Channel) { $script:Target = $channelInfo }
    }
    if ($null -eq $script:Target) {
        Stop-WithError ("Unknown channel '{0}'. Known: {1}" -f $Channel, (($script:Channels | ForEach-Object { $_.Id }) -join ', '))
    }
    if (-not $script:Installs.ContainsKey($script:Target.Id)) {
        # An uninstalled channel can still hold a receipt, and still hold an
        # entry in the refcount on the shared policy key. Refusing here is what
        # would make that entry impossible to release.
        if ($Command -eq 'activate') { Stop-WithError ("'{0}' is not installed." -f $script:Target.Name) }
        if (-not (Test-ChannelHasReceipt -ChannelId $script:Target.Id)) {
            Stop-WithError ("'{0}' is not installed and has no receipt, so there is nothing to act on." -f $script:Target.Name)
        }
        Write-Warn ("'{0}' is no longer installed. Acting on its receipt alone." -f $script:Target.Name)
    }
} else {
    foreach ($channelInfo in $script:Channels) {
        if ($null -eq $script:Target -and $script:Installs.ContainsKey($channelInfo.Id)) { $script:Target = $channelInfo }
    }
    if ($null -eq $script:Target -and $Command -ne 'activate') {
        # Nothing installed to default to, so default to what there is a
        # receipt for — that state is what deactivate and status exist to reach.
        foreach ($channelInfo in $script:Channels) {
            if ($null -eq $script:Target -and (Test-ChannelHasReceipt -ChannelId $channelInfo.Id)) { $script:Target = $channelInfo }
        }
    }
    if ($null -eq $script:Target) {
        Stop-WithError ("No Brave install found under {0}, {1} or {2}." -f $script:ProgramFilesRoot, $script:ProgramFilesX86Root, $script:LocalAppDataRoot)
    }
}
if ($script:Installs.ContainsKey($script:Target.Id)) { $script:TargetInstall = $script:Installs[$script:Target.Id] }

$script:UserDataDir = Get-ChannelUserDataDir -ChannelInfo $script:Target
$script:LocalStatePath = Join-Path $script:UserDataDir 'Local State'
$script:ReceiptPath = Get-ReceiptPath -ChannelId $script:Target.Id -Hive $script:Hive
$script:RefcountPath = Get-RefcountPath -Hive $script:Hive

function Get-ProfilePrefFiles {
    # Default and Profile N only. System Profile and Guest Profile are
    # deliberately skipped, and status uses the same selection so it cannot
    # report a false negative for a profile the writer never touches.
    $files = @()
    foreach ($name in @('Default')) {
        $path = Join-Path $script:UserDataDir (Join-Path $name 'Preferences')
        if (Test-Path -LiteralPath $path -PathType Leaf) { $files += $path }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $script:UserDataDir -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^Profile \d+$') { continue }
        $path = Join-Path $dir.FullName 'Preferences'
        if (Test-Path -LiteralPath $path -PathType Leaf) { $files += $path }
    }
    return @($files)
}

function Assert-BraveClosed {
    if ($null -eq $script:TargetInstall) { return }
    if (Test-BraveRunning -ExePath $script:TargetInstall.Exe) {
        Stop-WithError ("{0} is running. Quit it completely, then re-run.`r`n    Brave rewrites Preferences and Local State on exit and would discard these changes." -f $script:Target.Name)
    }
}

function Assert-Elevated {
    if ($User) { return }
    if (Test-Elevated) { return }
    Stop-WithError ("Writing {0} needs an elevated session.`r`n    Start Windows Terminal or PowerShell with 'Run as administrator', then:`r`n      {1} {2}`r`n    Or write your own user's policy key instead, which needs no elevation:`r`n      {1} {2} -User" -f $script:PolicyKeyPath, $script:SelfCommand, $Command)
}

function Get-PrefLiteral {
    param($Value)
    if ($Value) { return 'true' }
    return 'false'
}

# ── Pref reading and writing ─────────────────────────────────────────────────

function Read-PrefPriors {
    # One record per pref for one file. Returns @{ Records; Error }: Error set
    # means the file could not be read, and a file whose prior could not be
    # captured is a file this run must not write.
    #
    # Nothing in here prints. A PowerShell function returns EVERY uncaptured
    # value, so a Write-Output beside a `return` hands the caller the printed
    # lines as well — the caller reports, these compute.
    param([string]$Path, $Prefs)
    try {
        $text = Read-JsonFileText -Path $Path
    } catch {
        return @{ Records = $null; Error = ("unreadable ({0})" -f $_.Exception.Message) }
    }
    $records = [ordered]@{}
    foreach ($pref in $Prefs) {
        try {
            $records[$pref.Name] = Get-JsonPrefRecord -Text $text -Name $pref.Name
        } catch {
            return @{ Records = $null; Error = ("{0} could not be read ({1})" -f $pref.Name, $_.Exception.Message) }
        }
    }
    return @{ Records = $records; Error = $null }
}

# Failure counters live at script scope for the same reason: the pref writers
# below print, so they cannot also return a count.
$script:PrefWriteFailures = 0
$script:PrefRestoreFailures = 0

function Set-PrefFile {
    # Applies every pref to one file in a single atomic write.
    param([string]$Path, $Prefs)
    $label = Join-Path (Split-Path -Leaf (Split-Path -Parent $Path)) (Split-Path -Leaf $Path)
    try {
        $text = Read-JsonFileText -Path $Path
    } catch {
        Write-Fail ("    {0}: unreadable, left untouched ({1})" -f $label, $_.Exception.Message)
        $script:PrefWriteFailures++
        return
    }
    $changed = 0
    foreach ($pref in $Prefs) {
        # Guarded like every other call site. This one runs after the receipt is
        # written and the registry already mutated, and a file truncated between
        # the capture read and this one throws out of the scanner — which would
        # abort activate rather than count one more pref file as failed.
        $record = $null
        try {
            $record = Get-JsonPrefRecord -Text $text -Name $pref.Name
        } catch {
            Write-Fail ("    {0}: {1} could not be read ({2}); left untouched" -f $label, $pref.Name, $_.Exception.Message)
            $script:PrefWriteFailures++
            continue
        }
        if ($record['type'] -eq 'blocked') {
            Write-Fail ("    {0}: {1} sits under a JSON {2}; left untouched" -f $label, $pref.Name, $record['blocked_kind'])
            $script:PrefWriteFailures++
            continue
        }
        if ($record['type'] -eq 'object' -or $record['type'] -eq 'array') {
            # Overwriting it would destroy a value no rollback could rebuild,
            # and the boolean this pref wants is not a substitute for a container.
            Write-Fail ("    {0}: {1} holds a JSON {2}; left untouched" -f $label, $pref.Name, $record['type'])
            $script:PrefWriteFailures++
            continue
        }
        $want = Get-PrefLiteral -Value $pref.Value
        # Type as well as value: a stored 1 is not an already-true boolean.
        if ($record['type'] -eq 'boolean' -and $record['value'] -eq $want) { continue }
        $text = Set-JsonPrefText -Text $text -Name $pref.Name -Literal $want
        $changed++
    }
    if ($changed -gt 0) {
        try {
            Write-FileAtomic -Path $Path -Text $text
        } catch {
            Write-Fail ("    {0}: write failed, left untouched ({1})" -f $label, $_.Exception.Message)
            $script:PrefWriteFailures++
            return
        }
        Write-Output ("    {0}: {1} pref(s) written" -f $label, $changed)
    } else {
        Write-Output ("    {0}: already set" -f $label)
    }
}

function Restore-PrefFile {
    # Puts the recorded priors back into one file.
    param([string]$Path, $Records)
    $label = Join-Path (Split-Path -Leaf (Split-Path -Parent $Path)) (Split-Path -Leaf $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        # The profile is gone, so there is nothing left to restore. Counting it
        # as a failure would keep the receipt forever and make every later
        # deactivate exit non-zero.
        Write-Skip ("gone, nothing to restore: {0}" -f $Path)
        return
    }
    try {
        $text = Read-JsonFileText -Path $Path
    } catch {
        Write-Fail ("    unreadable, skipped: {0} ({1})" -f $Path, $_.Exception.Message)
        $script:PrefRestoreFailures++
        return
    }
    $original = $text
    $restored = 0
    foreach ($property in $Records.PSObject.Properties) {
        $name = $property.Name
        $record = $property.Value
        $kind = [string](Get-Prop -Object $record -Name 'type')
        try {
            if ($kind -eq 'absent') {
                $text = Remove-JsonPrefText -Text $text -Name $name
            } elseif (@('boolean', 'string', 'number', 'null') -contains $kind) {
                $text = Set-JsonPrefText -Text $text -Name $name -Literal ([string](Get-Prop -Object $record -Name 'value'))
            } else {
                Write-Fail ("    {0}: recorded prior is a {1}; left as it is" -f $name, $kind)
                $script:PrefRestoreFailures++
                continue
            }
        } catch {
            Write-Fail ("    {0}: could not be restored ({1})" -f $name, $_.Exception.Message)
            $script:PrefRestoreFailures++
            continue
        }
        $restored++
    }
    # Nothing was spliced — every record was already as recorded, or every one
    # failed. Rewriting the file byte-for-byte gains nothing and can only lose.
    if ($text -ne $original) {
        try {
            Write-FileAtomic -Path $Path -Text $text
        } catch {
            Write-Fail ("    write failed, left untouched: {0} ({1})" -f $Path, $_.Exception.Message)
            $script:PrefRestoreFailures++
            return
        }
    }
    Write-Output ("    {0}: {1} pref(s) restored" -f $label, $restored)
}

function Get-PrefCurrentValue {
    # For status: the raw JSON token, or "unset".
    param([string]$Path, [string]$Name)
    try {
        $text = Read-JsonFileText -Path $Path
        $record = Get-JsonPrefRecord -Text $text -Name $Name
    } catch {
        return 'unreadable'
    }
    if ($record['type'] -eq 'absent' -or $record['type'] -eq 'blocked') { return 'unset' }
    return [string]$record['value']
}

# ── ACTIVATE ─────────────────────────────────────────────────────────────────
# The order here is the design: read every prior value, write the receipt, and
# only then touch anything. Mutating first means an abort before the receipt is
# written leaves the machine changed with no record of what it had been.

function Invoke-ActivateDryRun {
    Write-Section 'Brave Origin policies'
    Write-Skip ("would write {0}" -f $script:PolicyKeyPath)
    foreach ($policy in $script:Policies) {
        $note = ''
        if (-not (Test-KeySupported -Key $policy.Key)) {
            $note = ("{0} (inert: not in this build){1}" -f $script:Dim, $script:Reset)
        }
        Write-Skip ("would set {0} = {1} (REG_DWORD {2}){3}" -f $policy.Key, $policy.Value.ToString().ToLower(), [int][bool]$policy.Value, $note)
    }
    Write-Section 'Standalone-build defaults (profile prefs)'
    foreach ($file in Get-ProfilePrefFiles) { Write-Skip ("would update {0}" -f $file) }
    Write-Section 'Crash / metrics reporting (Local State)'
    Write-Skip ("would update {0}" -f $script:LocalStatePath)
    Write-Section 'Result'
    Write-Output '  Dry run — no changes made.'
}

function Invoke-Activate {
    Write-Section 'Brave Origin — activating'
    Write-Info ("Target : {0} ({1}) {2}" -f $script:Target.Name, $script:Target.Id, (Get-BraveVersion -ChannelInfo $script:Target -Install $script:TargetInstall))
    Write-Info ("Policy : {0}  [{1} scope]" -f $script:PolicyKeyPath, $script:Scope)
    Write-Info ("Profile: {0}" -f $script:UserDataDir)

    if ($DryRun) {
        Write-Warn 'Dry run — nothing will be written.'
        Initialize-SupportedKeys -Install $script:TargetInstall
        Invoke-ActivateDryRun
        return
    }

    Assert-Elevated
    Assert-BraveClosed
    Initialize-SupportedKeys -Install $script:TargetInstall

    # ── Capture ──────────────────────────────────────────────────────────────
    # Nothing below this heading writes; nothing above the receipt does either.
    Write-Section 'Reading current values'
    $captured = Get-PolicyPriors -KeyPath $script:PolicyKeyPath
    $refused = $captured.Refused

    $prefPriors = [ordered]@{}
    $prefFiles = @(Get-ProfilePrefFiles)
    $capturedFiles = @()
    foreach ($file in $prefFiles) {
        $read = Read-PrefPriors -Path $file -Prefs $script:ProfilePrefs
        if ($read.Error) {
            Write-Fail ("    {0}: {1}, left untouched" -f (Split-Path -Leaf $file), $read.Error)
            $script:PrefWriteFailures++
            continue
        }
        $prefPriors[$file] = $read.Records
        $capturedFiles += $file
    }
    if ($prefFiles.Count -eq 0) {
        # There is no Windows equivalent of origin.sh's `sudo -u` drop to the
        # login user. "Run as administrator" with a SEPARATE admin account
        # points %LOCALAPPDATA% at that account's profile, so the HKLM policies
        # land, the Section B prefs are written for nobody, and the run would
        # otherwise print its success footer and exit 0.
        if ($null -ne $script:TargetInstall -and -not $User -and (Test-Elevated)) {
            Stop-WithError ("{0} is installed but no profile was found under {1}.`r`n    An elevated session started as a different account sees THAT account's`r`n    %LOCALAPPDATA%, not yours, so the standalone-default prefs would be`r`n    written for nobody while the policies applied machine-wide.`r`n    Sign in as the account that uses Brave and run '{2} activate -User', or`r`n    elevate from that account. Nothing has been changed." -f $script:Target.Name, $script:UserDataDir, $script:SelfCommand)
        }
        Write-Warn ("No profile found under {0}." -f $script:UserDataDir)
    }

    $localStateCaptured = $false
    if (Test-Path -LiteralPath $script:LocalStatePath -PathType Leaf) {
        $read = Read-PrefPriors -Path $script:LocalStatePath -Prefs $script:LocalStatePrefs
        if ($read.Error) {
            Write-Fail ("    Local State: {0}, left untouched" -f $read.Error)
            $script:PrefWriteFailures++
        } else {
            $prefPriors[$script:LocalStatePath] = $read.Records
            $localStateCaptured = $true
        }
    } else {
        Write-Warn 'Local State not found; metrics pref skipped.'
    }
    $localStateNote = if ($localStateCaptured) { 'Local State' } else { 'Local State NOT read' }
    Write-Ok ("{0} policy value(s), {1} profile pref file(s), {2}" -f $script:Policies.Count, $capturedFiles.Count, $localStateNote)

    # ── Refcount, then receipt, then the first write ─────────────────────────
    # The refcount holds the EARLIEST prior across every channel. When it
    # already exists, its copy is the untouched machine and this run's freshly
    # read values are our own writing — so it wins.
    $refcount = $null
    try {
        $refcount = Read-JsonRecord -Path $script:RefcountPath
    } catch {
        Stop-WithError ("{0} Refusing to replace it: it holds the only copy of the prior values." -f $_.Exception.Message)
    }
    $priors = $captured.Priors
    if ($null -ne $refcount) {
        $recorded = Get-Prop -Object $refcount -Name 'prior'
        if (-not (Test-JsonObject $recorded) -or -not (Test-JsonArrayProperty -Object $refcount -Name 'channels')) {
            Stop-WithError ("{0} is malformed. Refusing to replace it: it holds the only copy of the prior values." -f $script:RefcountPath)
        }
        foreach ($member in @(Get-Prop -Object $refcount -Name 'channels')) {
            if ($member -isnot [string]) {
                Stop-WithError ("{0} lists a non-string channel. Refusing to touch it." -f $script:RefcountPath)
            }
        }
        $priors = Merge-Priors -Newest $priors -Older (ConvertTo-PriorTable -JsonObject $recorded)
    }

    $existing = $null
    try {
        $existing = Read-JsonRecord -Path $script:ReceiptPath
    } catch {
        # Skipping the merge here would record the values the PREVIOUS run
        # installed as if they were the untouched machine's, and the write that
        # follows would destroy the last copy of the real priors.
        Stop-WithError ("Existing receipt {0} is unreadable: {1}" -f $script:ReceiptPath, $_.Exception.Message)
    }
    if ($null -ne $existing) {
        $complaint = Test-ReceiptShape -Receipt $existing
        if ($complaint) { Stop-WithError ("Existing receipt {0} is unusable ({1}). Refusing to overwrite it." -f $script:ReceiptPath, $complaint) }
        $priors = Merge-Priors -Newest $priors -Older (ConvertTo-PriorTable -JsonObject (Get-Prop -Object $existing -Name 'policies_prior'))
        # Prefs the earlier receipt recorded are the earlier machine, so they
        # win too, per file and per pref.
        $earlierPrefs = Get-Prop -Object $existing -Name 'prefs_prior'
        foreach ($fileProperty in $earlierPrefs.PSObject.Properties) {
            if (-not $prefPriors.Contains($fileProperty.Name)) {
                $prefPriors[$fileProperty.Name] = $fileProperty.Value
                continue
            }
            $merged = [ordered]@{}
            foreach ($name in $prefPriors[$fileProperty.Name].Keys) { $merged[$name] = $prefPriors[$fileProperty.Name][$name] }
            foreach ($prefProperty in $fileProperty.Value.PSObject.Properties) { $merged[$prefProperty.Name] = $prefProperty.Value }
            $prefPriors[$fileProperty.Name] = $merged
        }
    }

    $channelList = @($script:Target.Id)
    if ($null -ne $refcount) {
        $channelList = @(Get-Prop -Object $refcount -Name 'channels')
        if ($channelList -notcontains $script:Target.Id) { $channelList += $script:Target.Id }
    }

    $receipt = [ordered]@{
        channel        = $script:Target.Id
        hive           = $script:Hive
        scope          = $script:Scope
        policy_key     = $script:PolicyKeyPath
        user_data_dir  = $script:UserDataDir
        brave_version  = (Get-BraveVersion -ChannelInfo $script:Target -Install $script:TargetInstall)
        written_at     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        state          = 'provisional'
        # Mirrored from the refcount on purpose. It is the only copy of an
        # MDM's values that survives losing policy-key.<hive>.json, and
        # destroying theirs is the one thing this must never do.
        policies_prior = $priors
        prefs_prior    = $prefPriors
    }
    $complaint = Test-ReceiptShape -Receipt ((($receipt | ConvertTo-Json -Depth 10) | ConvertFrom-Json))
    if ($complaint) { Stop-WithError ("Refusing to write a malformed receipt to {0}: {1}" -f $script:ReceiptPath, $complaint) }
    try {
        Write-JsonRecord -Path $script:ReceiptPath -Object $receipt
    } catch {
        Stop-WithError ("Could not write the receipt at {0}; nothing was changed. ({1})" -f $script:ReceiptPath, $_.Exception.Message)
    }
    Write-Info ("Receipt written before any change: {0}" -f $script:ReceiptPath)

    # The refcount records the same prior, and it too must be written before
    # the values it protects are overwritten — afterwards, the "prior" would be
    # our own writing. It comes second so that a failed receipt write cannot
    # leave this channel listed here with nothing able to release it.
    $refcountRecord = [ordered]@{
        policy_key = $script:PolicyKeyPath
        prior      = $priors
        channels   = @($channelList)
        updated_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    }
    try {
        Write-JsonRecord -Path $script:RefcountPath -Object $refcountRecord
    } catch {
        Stop-WithError ("Could not record the policy-key state at {0}; nothing was written. ({1})" -f $script:RefcountPath, $_.Exception.Message)
    }

    # ── Mutate ───────────────────────────────────────────────────────────────
    $applied = 0; $inert = 0; $failed = 0
    Write-Section 'Brave Origin policies'
    foreach ($policy in $script:Policies) {
        $note = ''
        if (-not (Test-KeySupported -Key $policy.Key)) {
            $note = ("{0} (inert: not in this build){1}" -f $script:Dim, $script:Reset)
            $inert++
        }
        if ($refused.ContainsKey($policy.Key)) {
            Write-Fail ("{0} — left untouched: {1}, which cannot be restored exactly" -f $policy.Key, $refused[$policy.Key])
            $failed++
            continue
        }
        $want = [int][bool]$policy.Value
        try {
            Set-PolicyValueRaw -KeyPath $script:PolicyKeyPath -Name $policy.Key -Value $want -Type 'DWord'
        } catch {
            Write-Fail ("{0} — write failed: {1}" -f $policy.Key, $_.Exception.Message)
            $failed++
            continue
        }
        $back = Get-PolicyValueRaw -KeyPath $script:PolicyKeyPath -Name $policy.Key
        if ($null -ne $back -and $back.Type -eq 'DWord' -and [int]$back.Value -eq $want) {
            Write-Ok ("{0} = {1} {2}({3}){4}{5}" -f $policy.Key, $policy.Value.ToString().ToLower(), $script:Dim, $policy.Settable, $script:Reset, $note)
            $applied++
        } else {
            Write-Fail ("{0} — write did NOT take effect" -f $policy.Key)
            $failed++
        }
    }
    $others = @($channelList | Where-Object { $_ -ne $script:Target.Id })
    if ($others.Count -gt 0) {
        Write-Info ("Policy key: {0} {1}(also active for: {2}){3}" -f $script:PolicyKeyPath, $script:Dim, ($others -join ', '), $script:Reset)
    } else {
        Write-Info ("Policy key: {0}" -f $script:PolicyKeyPath)
    }

    Write-Section 'Standalone-build defaults (profile prefs)'
    foreach ($file in $capturedFiles) {
        Set-PrefFile -Path $file -Prefs $script:ProfilePrefs
    }

    Write-Section 'Crash / metrics reporting (Local State)'
    if ($localStateCaptured) {
        Set-PrefFile -Path $script:LocalStatePath -Prefs $script:LocalStatePrefs
    } else {
        Write-Skip 'not written (prior value was not captured)'
    }

    $receipt['state'] = 'complete'
    try {
        Write-JsonRecord -Path $script:ReceiptPath -Object $receipt
    } catch {
        Write-Warn ("Could not mark the receipt complete at {0}; it is still usable. ({1})" -f $script:ReceiptPath, $_.Exception.Message)
    }

    # Brave may have been launched while we were writing; its in-memory copy
    # would overwrite the JSON edits on exit.
    if ($null -ne $script:TargetInstall -and (Test-BraveRunning -ExePath $script:TargetInstall.Exe)) {
        Write-Warn ("{0} started during this run — re-run activate after quitting it." -f $script:Target.Name)
    }

    Write-Section 'Result'
    Write-Output ("  Policies written : {0} / {1}" -f $applied, $script:Policies.Count)
    $localStateState = if ($localStateCaptured) { 'written' } else { "$script:Yellow" + 'skipped' + "$script:Reset" }
    Write-Output ("  Prefs written    : {0} profile file(s), Local State {1}" -f $capturedFiles.Count, $localStateState)
    if ($inert -gt 0) { Write-Output ("  Inert this build : {0} {1}(written, ignored until Brave ships them){2}" -f $inert, $script:Dim, $script:Reset) }
    if ($failed -gt 0) { Write-Output ("  {0}Failed writes    : {1}{2}" -f $script:Red, $failed, $script:Reset) }
    if ($script:PrefWriteFailures -gt 0) { Write-Output ("  {0}Pref files failed: {1}{2}" -f $script:Red, $script:PrefWriteFailures, $script:Reset) }
    Write-Output ("  Receipt          : {0}" -f $script:ReceiptPath)
    Write-Output ''
    if ($failed -gt 0 -or $script:PrefWriteFailures -gt 0) {
        Write-Output ("  {0}{1}Incomplete.{2} Fix the errors above and re-run." -f $script:Red, $script:Bold, $script:Reset)
        Write-Output ("  {0}The receipt covers what did change; deactivate rolls it back.{1}" -f $script:Dim, $script:Reset)
        $script:ExitCode = 1
        return
    }
    Write-Output ("  {0}Restart {1}{2} — all policies are dynamic_refresh:false." -f $script:Bold, $script:Target.Name, $script:Reset)
    Write-Output ("  {0}gpupdate /force shortens the <=15-minute policy reload, but the restart is still required.{1}" -f $script:Dim, $script:Reset)
    Write-Output '  Verify at brave://policy'
}

# ── DEACTIVATE ───────────────────────────────────────────────────────────────

function Invoke-Deactivate {
    Write-Section 'Brave Origin — deactivating'
    Write-Info ("Target : {0} ({1})" -f $script:Target.Name, $script:Target.Id)

    # Before the receipt check, not after: %ProgramData%\brave-to-origin is
    # ACL'd to administrators, so an unelevated run cannot see the receipt at
    # all and would be told its rollback is gone rather than that it needs
    # elevation.
    if (-not $DryRun) { Assert-Elevated }

    if (-not (Test-Path -LiteralPath $script:ReceiptPath -PathType Leaf)) {
        if (-not $User -and -not (Test-Elevated)) {
            Stop-WithError ("Cannot read {0}: receipts there are readable by administrators only.`r`n    Re-run from an elevated session before concluding there is no receipt." -f $script:ReceiptPath)
        }
        Stop-WithError ("No receipt at {0}.`r`n    Without it this script cannot tell its own policy values from those written`r`n    by an MDM or Group Policy, and it will not guess. If you applied these by`r`n    hand, remove them by hand." -f $script:ReceiptPath)
    }
    $receipt = $null
    try {
        $receipt = Read-JsonRecord -Path $script:ReceiptPath
    } catch {
        Stop-WithError ("{0} Refusing to guess, and leaving it in place." -f $_.Exception.Message)
    }
    $complaint = Test-ReceiptShape -Receipt $receipt
    if ($complaint) {
        # Never deleted: the values it describes are still applied, and this
        # file is the only record of what they were.
        Stop-WithError ("Receipt at {0} is unusable ({1}). Refusing to guess, and leaving it in place." -f $script:ReceiptPath, $complaint)
    }
    $recordedKey = [string](Get-Prop -Object $receipt -Name 'policy_key')
    if ($recordedKey -ne $script:PolicyKeyPath) {
        Stop-WithError ("Receipt {0} records {1}, but this run targets {2}. Refusing to act on a receipt for a different key." -f $script:ReceiptPath, $recordedKey, $script:PolicyKeyPath)
    }

    if (-not $DryRun) {
        Assert-BraveClosed
    } else {
        Write-Warn 'Dry run — nothing will be written.'
    }

    Write-Info ("Receipt: {0}" -f $script:ReceiptPath)
    Write-Info ("Policy : {0}" -f $recordedKey)
    $state = [string](Get-Prop -Object $receipt -Name 'state')
    if ($state -and $state -ne 'complete') {
        Write-Warn ("That receipt is {0}: an activate run was cut short. Rolling back what it recorded." -f $state)
    }

    # Restore prefs FIRST. If anything below fails, the user-visible browser
    # settings are already back rather than stranded.
    Write-Section 'Restoring prefs'
    if ($DryRun) {
        Write-Skip 'would restore the prefs recorded in the receipt'
    } else {
        foreach ($fileProperty in (Get-Prop -Object $receipt -Name 'prefs_prior').PSObject.Properties) {
            Restore-PrefFile -Path $fileProperty.Name -Records $fileProperty.Value
        }
        if ($script:PrefRestoreFailures -gt 0) { Write-Fail ("{0} pref restore(s) failed" -f $script:PrefRestoreFailures) }
    }

    Write-Section 'Removing policies'
    $policyFailed = 0
    $removed = 0
    $restored = 0
    $outcome = ''

    $refcount = $null
    try {
        $refcount = Read-JsonRecord -Path $script:RefcountPath
    } catch {
        Stop-WithError ("{0} Refusing to act on it." -f $_.Exception.Message)
    }
    $priorSource = $null
    $release = $true
    if ($null -ne $refcount) {
        $recorded = Get-Prop -Object $refcount -Name 'prior'
        if (-not (Test-JsonObject $recorded) -or -not (Test-JsonArrayProperty -Object $refcount -Name 'channels')) {
            Stop-WithError ("{0} is malformed. Refusing to act on it." -f $script:RefcountPath)
        }
        $channels = @(Get-Prop -Object $refcount -Name 'channels')
        $remaining = @($channels | Where-Object { $_ -ne $script:Target.Id })
        if ($remaining.Count -gt 0) {
            $release = $false
            $outcome = ("left in place — still active for {0}" -f ($remaining -join ', '))
            if ($DryRun) {
                Write-Skip ("would leave {0}: {1} still active" -f $script:PolicyKeyPath, ($remaining -join ', '))
            } else {
                Write-Info ("{0} still active — leaving {1} in place." -f ($remaining -join ', '), $script:PolicyKeyPath)
                $updated = [ordered]@{
                    policy_key = $script:PolicyKeyPath
                    prior      = (ConvertTo-PriorTable -JsonObject $recorded)
                    channels   = @($remaining)
                    updated_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
                }
                try {
                    Write-JsonRecord -Path $script:RefcountPath -Object $updated
                } catch {
                    Write-Fail ("Could not update {0}; {1} left as it is." -f $script:RefcountPath, $script:PolicyKeyPath)
                    $policyFailed++
                    $outcome = 'left in place (the policy-key record could not be updated)'
                }
            }
        } else {
            $priorSource = ConvertTo-PriorTable -JsonObject $recorded
        }
    } else {
        # The refcount is the handle, and it is gone. The receipt carries its
        # own copy of the prior, so a lost record no longer means a lost prior
        # — but it does mean no other channel's claim can be seen from here.
        Write-Warn ("No policy-key record at {0}. Restoring from this receipt's own copy of the priors; another channel may still want these values." -f $script:RefcountPath)
        $priorSource = ConvertTo-PriorTable -JsonObject (Get-Prop -Object $receipt -Name 'policies_prior')
    }

    if ($release) {
        foreach ($policy in $script:Policies) {
            if (-not $priorSource.Contains($policy.Key)) {
                # No prior recorded means activate refused to touch it, so
                # there is nothing of ours here to take back.
                Write-Skip ("{0} — not recorded by activate, left as it is" -f $policy.Key)
                continue
            }
            $prior = $priorSource[$policy.Key]
            $type = [string]$prior['type']
            if ($DryRun) {
                # Counted, or the summary reads "0 removed, 0 restored" directly
                # under a list of the actions it just planned.
                if ($type -eq 'absent') {
                    Write-Skip ("would remove {0}" -f $policy.Key)
                    $removed++
                } elseif ($script:RestorableKinds -contains $type) {
                    Write-Skip ("would restore {0} = {1} (REG_{2})" -f $policy.Key, $prior['value'], $type.ToUpper())
                    $restored++
                } else {
                    Write-Skip ("would refuse {0}: recorded prior is a {1}" -f $policy.Key, $type)
                }
                continue
            }
            if ($type -eq 'absent') {
                if (Remove-PolicyValueVerified -KeyPath $script:PolicyKeyPath -Name $policy.Key) {
                    Write-Ok ("removed {0}" -f $policy.Key)
                    $removed++
                } else {
                    Write-Fail ("could not remove {0}" -f $policy.Key)
                    $policyFailed++
                }
            } elseif ($script:RestorableKinds -contains $type) {
                if (Restore-PolicyValue -KeyPath $script:PolicyKeyPath -Name $policy.Key -Prior $prior) {
                    Write-Ok ("restored {0} = {1} {2}(pre-existing REG_{3}){4}" -f $policy.Key, $prior['value'], $script:Dim, $type.ToUpper(), $script:Reset)
                    $restored++
                } else {
                    Write-Fail ("could not restore {0} = {1} (REG_{2})" -f $policy.Key, $prior['value'], $type.ToUpper())
                    $policyFailed++
                }
            } else {
                # No substitute value gets written here: putting a REG_BINARY
                # back as a DWord destroys it, and reporting success hides that.
                Write-Fail ("{0} — recorded prior is a {1}; refusing to substitute a value. Left as it is." -f $policy.Key, $type)
                $policyFailed++
            }
        }
        $outcome = ("{0} removed, {1} restored to prior values" -f $removed, $restored)
        if (-not $DryRun -and $policyFailed -eq 0) {
            $subKeys = @(Get-PolicySubKeyNames -KeyPath $script:PolicyKeyPath)
            $reserved = @($subKeys | Where-Object { $script:ReservedSubKeys -contains $_ })
            if ($subKeys.Count -gt 0) {
                Write-Info ("Policy key kept: it still holds subkey(s) {0}{1}" -f ($subKeys -join ', '), $(if ($reserved.Count -gt 0) { ' — reserved, never touched here' } else { '' }))
            } elseif (Remove-PolicyKeyIfEmpty -KeyPath $script:PolicyKeyPath) {
                Write-Ok ("policy key removed (no values or subkeys left): {0}" -f $script:PolicyKeyPath)
            }
            Remove-Item -LiteralPath $script:RefcountPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Outside the block above on purpose: an already-removed value is not a
    # reason to keep a receipt forever, and a skipped pref restore IS one.
    if (-not $DryRun) {
        if ($policyFailed -eq 0 -and $script:PrefRestoreFailures -eq 0) {
            Remove-Item -LiteralPath $script:ReceiptPath -Force -ErrorAction SilentlyContinue
            Write-Ok 'receipt cleared'
        } else {
            Write-Warn ("Receipt kept at {0}: {1} policy and {2} pref restore(s) failed." -f $script:ReceiptPath, $policyFailed, $script:PrefRestoreFailures)
        }
    }

    # Other receipts this run did not touch: the other hive for this channel,
    # and any other channel.
    $otherHive = if ($User) { 'hklm' } else { 'hkcu' }
    $otherHivePath = Get-ReceiptPath -ChannelId $script:Target.Id -Hive $otherHive
    if (Test-Path -LiteralPath $otherHivePath -PathType Leaf) {
        Write-Warn ("Still active in the other hive: {0} (re-run with the matching -User)" -f $otherHivePath)
    } elseif (-not $User) {
        # %LOCALAPPDATA% is this account's. Another signed-in user's HKCU
        # receipt sits in their profile and is not readable from here, so the
        # absence above is an answer about one account, not about the machine.
        Write-Warn ("Per-user scope checked for {0} only; another account's HKCU receipt lives in their profile and could not be checked." -f $env:USERNAME)
    }
    $otherChannels = @()
    foreach ($channelInfo in $script:Channels) {
        if ($channelInfo.Id -eq $script:Target.Id) { continue }
        if (Test-ChannelHasReceipt -ChannelId $channelInfo.Id) { $otherChannels += $channelInfo.Id }
    }
    if ($otherChannels.Count -gt 0) {
        Write-Warn ("Still active on other channels (re-run with -Channel): {0}" -f ($otherChannels -join ' '))
    }

    Write-Section 'Result'
    if ($DryRun) {
        Write-Output ("  Policy key       : would be {0}" -f $outcome)
    } else {
        Write-Output ("  Policy key       : {0}" -f $outcome)
    }
    if ($policyFailed -gt 0 -or $script:PrefRestoreFailures -gt 0) {
        Write-Output ("  {0}Failures{1}         : {2} polic(y/ies), {3} pref file(s) — receipt kept" -f $script:Red, $script:Reset, $policyFailed, $script:PrefRestoreFailures)
    }
    Write-Output ("  {0}Restart {1}.{2}" -f $script:Bold, $script:Target.Name, $script:Reset)
    if ($policyFailed -gt 0 -or $script:PrefRestoreFailures -gt 0) { $script:ExitCode = 1 }
}

# ── STATUS ───────────────────────────────────────────────────────────────────

function Get-PolicyDisplay {
    # What one hive holds for one value, rendered for the table.
    param([string]$KeyPath, [string]$Name)
    $raw = Get-PolicyValueRaw -KeyPath $KeyPath -Name $Name
    if ($null -eq $raw) { return '(unset)' }
    if ($raw.Type -ne 'DWord') { return ("(REG_{0})" -f $raw.Type.ToUpper()) }
    if ([int]$raw.Value -eq 1) { return 'true' }
    if ([int]$raw.Value -eq 0) { return 'false' }
    return ("({0})" -f $raw.Value)
}

function Invoke-Status {
    Write-Section 'Brave Origin — status'
    $version = Get-BraveVersion -ChannelInfo $script:Target -Install $script:TargetInstall
    Write-Info ("Target : {0} ({1}) {2}" -f $script:Target.Name, $script:Target.Id, $version)
    if ($version -ne $script:ValidatedAgainst) {
        Write-Warn ("Policy set last verified against {0}; this is {1}. Re-check for new Origin policies." -f $script:ValidatedAgainst, $version)
    }
    if ($null -ne $script:TargetInstall) {
        Write-Info ("Install: {0} {1}({2}){3}" -f $script:TargetInstall.Exe, $script:Dim, $(if ($script:TargetInstall.Machine) { 'machine-wide' } else { 'per-user' }), $script:Reset)
    }
    $override = Get-UserDataDirOverride
    if ($override) {
        Write-Warn ("UserDataDir policy relocates every channel's profile to {0}" -f $override)
    }
    Write-Info ("Profile: {0}" -f $script:UserDataDir)

    Initialize-SupportedKeys -Install $script:TargetInstall

    # Every receipt for this channel, in both hives. One missing from this list
    # is a set of policy values nothing can roll back.
    $foundReceipt = $false
    $otherScopeReceipt = ''
    foreach ($hive in @('hklm', 'hkcu')) {
        $path = Get-ReceiptPath -ChannelId $script:Target.Id -Hive $hive
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $foundReceipt = $true
            if ($hive -ne $script:Hive.ToLower()) { $otherScopeReceipt = $path }
            $record = Read-JsonRecord -Path $path
            $state = [string](Get-Prop -Object $record -Name 'state')
            Write-Info ("Receipt: {0} {1}({2} scope · {3}){4}" -f $path, $script:Dim, [string](Get-Prop -Object $record -Name 'scope'), $state, $script:Reset)
        } catch {
            Write-Fail ("Receipt: {0} — unreadable ({1})" -f $path, $_.Exception.Message)
        }
    }
    if ($otherScopeReceipt) {
        $otherFlag = if ($User) { 'without -User' } else { 'with -User' }
        Write-Warn ("The other scope is still active: {0} — re-run deactivate {1} to roll it back." -f $otherScopeReceipt, $otherFlag)
    }
    if (-not $foundReceipt) {
        if (-not $User -and -not (Test-Elevated)) {
            Write-Warn ("Receipts under {0} are readable by administrators only; re-run elevated to see them." -f $script:ReceiptDirMachine)
        } else {
            Write-Warn 'No receipt — deactivate will refuse to run until activate creates one.'
        }
    }
    if (-not $User) {
        # The per-user receipt directory is under %LOCALAPPDATA%, which is this
        # account's alone. A machine-scope run cannot read another signed-in
        # user's HKCU receipt, so "clear" here is a claim about one account.
        Write-Warn ("Per-user scope checked for {0} only; another account's HKCU receipt lives in their own profile and could not be checked." -f $env:USERNAME)
    }

    Write-Section ("Policies — {0} {1}(shared by every channel; HKLM wins over HKCU){2}" -f $script:PolicyKeyPath, $script:Dim, $script:Reset)
    try {
        $refcount = Read-JsonRecord -Path $script:RefcountPath
        if ($null -ne $refcount) {
            $channels = @(Get-Prop -Object $refcount -Name 'channels')
            Write-Info ("Activated for: {0} {1}(the values go back only when the last one deactivates){2}" -f ($channels -join ', '), $script:Dim, $script:Reset)
        } elseif (Test-PolicyKeyExists -KeyPath $script:PolicyKeyPath) {
            Write-Warn ("No policy-key record at {0}: nothing here says which channels asked for these values." -f $script:RefcountPath)
        }
    } catch {
        Write-Fail ("Policy-key record at {0} is unreadable ({1})" -f $script:RefcountPath, $_.Exception.Message)
    }

    $active = 0; $missing = 0; $inert = 0
    Write-Output ("  {0,-30} {1,-6} {2,-9} {3,-9} {4}" -f 'KEY', 'WANT', 'HKLM', 'HKCU', 'EFFECT')
    foreach ($policy in $script:Policies) {
        $want = $policy.Value.ToString().ToLower()
        $machine = Get-PolicyDisplay -KeyPath $script:PolicyKeyPathMachine -Name $policy.Key
        $user = Get-PolicyDisplay -KeyPath $script:PolicyKeyPathUser -Name $policy.Key
        # HKLM wins, so the effective value is HKLM's unless it has none.
        $effective = if ($machine -ne '(unset)') { $machine } else { $user }
        if (-not (Test-KeySupported -Key $policy.Key)) {
            $effect = 'inert (not in this build)'; $colour = $script:Dim; $inert++
        } elseif ($effective -eq $want) {
            $effect = 'enforced'; $colour = $script:Green; $active++
        } else {
            $effect = 'not applied'; $colour = $script:Red; $missing++
        }
        Write-Output ("  {0}{1,-30} {2,-6} {3,-9} {4,-9} {5}{6}" -f $colour, $policy.Key, $want, $machine, $user, $effect, $script:Reset)
    }
    Write-Output ("  {0}enforced {1} · not applied {2} · inert {3}{4}" -f $script:Dim, $active, $missing, $inert, $script:Reset)

    foreach ($keyPath in @($script:PolicyKeyPathMachine, $script:PolicyKeyPathUser)) {
        $subKeys = @(Get-PolicySubKeyNames -KeyPath $keyPath)
        $reserved = @($subKeys | Where-Object { $script:ReservedSubKeys -contains $_ })
        if ($reserved.Count -gt 0) {
            Write-Info ("{0} holds {1} {2}(reserved — never written or removed here){3}" -f $keyPath, ($reserved -join ', '), $script:Dim, $script:Reset)
        }
    }

    Write-Section 'Profile prefs'
    $files = @(Get-ProfilePrefFiles)
    foreach ($pref in $script:ProfilePrefs) {
        $want = Get-PrefLiteral -Value $pref.Value
        $hits = @()
        $good = ($files.Count -gt 0)
        foreach ($file in $files) {
            $got = Get-PrefCurrentValue -Path $file -Name $pref.Name
            if ($got -ne $want) { $good = $false }
            $hits += ("{0}={1}" -f (Split-Path -Leaf (Split-Path -Parent $file)), $got)
        }
        $mark = if ($good) { '+' } else { '-' }
        $detail = if ($hits.Count -gt 0) { $hits -join ', ' } else { 'no profiles found' }
        Write-Output ("  [{0}] {1} (want {2}) :: {3}" -f $mark, $pref.Name, $want, $detail)
    }

    Write-Section 'Local State'
    foreach ($pref in $script:LocalStatePrefs) {
        $want = Get-PrefLiteral -Value $pref.Value
        if (-not (Test-Path -LiteralPath $script:LocalStatePath -PathType Leaf)) {
            Write-Output ("  [-] {0} :: Local State not found" -f $pref.Name)
            continue
        }
        $got = Get-PrefCurrentValue -Path $script:LocalStatePath -Name $pref.Name
        $mark = if ($got -eq $want) { '+' } else { '-' }
        Write-Output ("  [{0}] {1} (want {2}) :: {3}" -f $mark, $pref.Name, $want, $got)
    }

    Write-Section 'Environment'
    Write-Output ("  Policy key     : {0} {1}(one key for every channel; Recommended and 3rdparty untouched){2}" -f $script:PolicyKeyPath, $script:Dim, $script:Reset)
    Write-Output ("  Elevated       : {0} {1}(HKLM needs it; -User does not){2}" -f $(if (Test-Elevated) { 'yes' } else { 'no' }), $script:Dim, $script:Reset)
    $running = 'unknown (not installed)'
    if ($null -ne $script:TargetInstall) {
        $running = if (Test-BraveRunning -ExePath $script:TargetInstall.Exe) { 'yes' } else { 'no' }
    }
    Write-Output ("  {0} running : {1}" -f $script:Target.Name, $running)
    Write-Output ''
    Write-Output ("  {0}This reads the registry and files, not the browser. brave://policy is authoritative.{1}" -f $script:Dim, $script:Reset)
}

# The commands print, so they cannot also return an exit code: a PowerShell
# function hands its caller every uncaptured value, printed lines included.
switch ($Command) {
    'activate' { Invoke-Activate }
    'deactivate' { Invoke-Deactivate }
    'status' { Invoke-Status }
}
exit $script:ExitCode
