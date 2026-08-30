# =============================================================================
# Brave to Origin - one-shot installer for Windows
# =============================================================================
#
#   irm https://raw.githubusercontent.com/mdrubelamin2/brave-to-origin/main/install.ps1 | iex
#
# Fetches origin.ps1 at a pinned tag, verifies its SHA-256, parses it, and runs
# it. Nothing is left behind: the script goes to a temp file and is deleted
# after. The receipt it writes lives outside all of this - %ProgramData% -
# so a later deactivate needs none of it.
#
# Non-interactive form, for scripts and CI. `iex` cannot take arguments, so the
# text has to become a scriptblock first:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mdrubelamin2/brave-to-origin/main/install.ps1))) -Action activate
#   & ([scriptblock]::Create((irm ...))) -Action status -Channel com.brave.Browser.beta
#
# ENV OVERRIDES (testing)
#   ORIGIN_REF     git ref to fetch instead of the pinned tag
#   ORIGIN_SHA256  expected checksum, or "skip" to bypass verification
#   ORIGIN_SOURCE  local file or URL to use instead of downloading
# =============================================================================

# No [CmdletBinding()] and no [ValidateSet] on $Action, deliberately. The
# documented entry point is `irm ... | iex`, which evaluates this text in the
# caller's own scope: PowerShell then tries to attach each attribute to a
# variable holding the parameter's default, and ValidateSet rejects the empty
# string before a single line of this script runs. The action is validated a
# few lines below instead, where a wrong value can produce a useful message.
param(
    [string]$Action,
    [string]$Channel,
    [switch]$User,
    [switch]$DryRun,
    [switch]$NoColor
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'


$Repo = 'mdrubelamin2/brave-to-origin'
# Pinned, not a moving branch: piping a URL to an elevated shell should not
# mean "whatever that branch says today". Bump both together at a release.
$PinnedRef = 'v1.2.3'
$PinnedSha256 = 'b07335a742d3e850fd6125895aab92daa4c192a1840aa163ade0b85794bf0b3e'

$Ref = if ($env:ORIGIN_REF) { $env:ORIGIN_REF } else { $PinnedRef }
$ExpectedSha = if ($env:ORIGIN_SHA256) { $env:ORIGIN_SHA256 } else { $PinnedSha256 }
$Source = if ($env:ORIGIN_SOURCE) { $env:ORIGIN_SOURCE } else { "https://raw.githubusercontent.com/$Repo/$Ref/origin.ps1" }

$CanColor = $false
if (-not $NoColor) {
    try { $CanColor = [bool]$Host.UI.SupportsVirtualTerminal } catch { $CanColor = $false }
}
$Red = ''; $Green = ''; $Yellow = ''; $Cyan = ''; $Dim = ''; $Bold = ''; $Reset = ''
if ($CanColor) {
    $e = [char]27
    $Red = "$e[0;31m"; $Green = "$e[0;32m"; $Yellow = "$e[1;33m"
    $Cyan = "$e[0;36m"; $Dim = "$e[2m"; $Bold = "$e[1m"; $Reset = "$e[0m"
}
function Write-Info { param([string]$Message) Write-Output ("{0}[*]{1} {2}" -f $Cyan, $Reset, $Message) }
function Write-Ok { param([string]$Message) Write-Output ("{0}[+]{1} {2}" -f $Green, $Reset, $Message) }
function Write-Warn { param([string]$Message) Write-Output ("{0}[!]{1} {2}" -f $Yellow, $Reset, $Message) }
function Complete-Run {
    # Both documented forms run this file as a scriptblock inside the user's own
    # session, so `exit` closes the window everything was printed into. Errors
    # and instructions are unreadable unless the run waits.
    #
    # IsInputRedirected, not UserInteractive: under `irm | iex` the pipeline is
    # internal to PowerShell and the console's own stdin is still a terminal, so
    # this pauses there. When stdin is piped from a file or a CI runner it is
    # redirected, and the run exits straight away rather than hanging forever.
    param([int]$Code)
    if (-not [Console]::IsInputRedirected) {
        try { Read-Host 'Press Enter to close' | Out-Null } catch { }
    }
    exit $Code
}
function Stop-WithError {
    param([string]$Message, [switch]$KeepOpen)
    [Console]::Error.WriteLine(("{0}[x]{1} {2}" -f $Red, $Reset, $Message))
    Complete-Run 1
}

# Validated here rather than with [ValidateSet] on the parameter - see the note
# above the param block for why that attribute cannot survive `iex`.
$ValidActions = @('activate', 'deactivate', 'status')
if ($Action -and $ValidActions -notcontains $Action) {
    Stop-WithError ("Unknown -Action '{0}'. Use one of: {1}" -f $Action, ($ValidActions -join ', '))
}

# $Ref, not 'main': printing a command that points at a moving branch undoes the
# pinning the line above it exists to provide.
$IrmCommand = "irm https://raw.githubusercontent.com/$Repo/$Ref/install.ps1 | iex"
$ArgCommand = "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/$Repo/$Ref/install.ps1)))"

# -- Guards -------------------------------------------------------------------
# The registry policy store is a Windows thing. macOS and Linux keep theirs in
# files, which install.sh and origin.sh handle.
$IsWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
if (-not $IsWindowsHost) {
    Stop-WithError "This installer supports Windows only. On macOS and Linux use:`r`n    curl -fsSL https://raw.githubusercontent.com/$Repo/main/install.sh | sudo bash"
}

# TLS 1.2 explicitly: Windows PowerShell 5.1 defaults to SSL3/TLS1.0 on stock
# Windows 10, and raw.githubusercontent.com has refused those for years - the
# failure is an opaque "underlying connection was closed".
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warn "Could not force TLS 1.2; the download may fail on stock Windows 10."
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Output ''
Write-Output ("{0}Brave to Origin{1} {2}- {3} @ {4}{5}" -f $Bold, $Reset, $Dim, $Repo, $Ref, $Reset)
Write-Output ''

# -- Which Brave is installed -------------------------------------------------
# Kept in step with origin.ps1's own table. Order matters: the first match is
# the default.
$Channels = @(
    @{ Id = 'com.brave.Browser'; Suffix = ''; Name = 'Brave (stable)'; Guid = '{AFE6A462-C574-4B8A-AF43-4CC60DF4563B}' }
    @{ Id = 'com.brave.Browser.beta'; Suffix = '-Beta'; Name = 'Brave Beta'; Guid = '{103BD053-949B-43A8-9120-2E424887DE11}' }
    @{ Id = 'com.brave.Browser.dev'; Suffix = '-Dev'; Name = 'Brave Dev'; Guid = '{CB2150F2-595F-4633-891A-E39720CE0531}' }
    @{ Id = 'com.brave.Browser.nightly'; Suffix = '-Nightly'; Name = 'Brave Nightly'; Guid = '{C6CB981E-DB30-4876-8639-109F8933582C}' }
)

function Find-Install {
    # Machine-wide first, per-user last. Same three roots origin.ps1 probes.
    param([hashtable]$ChannelInfo)
    $roots = @(
        @{ Root = $env:ProgramFiles; Machine = $true }
        @{ Root = ${env:ProgramFiles(x86)}; Machine = $true }
        @{ Root = $env:LOCALAPPDATA; Machine = $false }
    )
    foreach ($candidate in $roots) {
        if (-not $candidate.Root) { continue }
        $appDir = Join-Path $candidate.Root ('BraveSoftware\Brave-Browser' + $ChannelInfo.Suffix + '\Application')
        if (Test-Path -LiteralPath (Join-Path $appDir 'brave.exe') -PathType Leaf) {
            return @{ AppDir = $appDir; Machine = $candidate.Machine }
        }
    }
    return $null
}

function Get-InstalledVersion {
    # Same order origin.ps1 uses: the updater's own record, then the versioned
    # directory, then the exe's resources.
    param([hashtable]$ChannelInfo, [hashtable]$Install)
    $hive = if ($Install.Machine) { 'HKLM' } else { 'HKCU' }
    foreach ($root in @('SOFTWARE\WOW6432Node\BraveSoftware\Update\Clients', 'SOFTWARE\BraveSoftware\Update\Clients')) {
        $key = Get-Item -LiteralPath ("{0}:\{1}\{2}" -f $hive, $root, $ChannelInfo.Guid) -ErrorAction SilentlyContinue
        if ($null -eq $key) { continue }
        if (@($key.GetValueNames()) -notcontains 'pv') { continue }
        $pv = [string]$key.GetValue('pv')
        if ($pv) { return $pv }
    }
    $best = $null
    foreach ($dir in @(Get-ChildItem -LiteralPath $Install.AppDir -Directory -ErrorAction SilentlyContinue)) {
        $parsed = $null
        # [version], never a text sort: "1.94.117" sorts after "1.100.4".
        if ([System.Version]::TryParse($dir.Name, [ref]$parsed)) {
            if ($null -eq $best -or $parsed -gt $best) { $best = $parsed }
        }
    }
    if ($null -ne $best) { return $best.ToString() }
    try {
        $product = (Get-Item -LiteralPath (Join-Path $Install.AppDir 'brave.exe')).VersionInfo.ProductVersion
        if ($product) { return ([string]$product).Trim() }
    } catch {
        # An unreadable stub is not a reason to stop; the version is cosmetic here.
    }
    return 'unknown'
}

$Found = @()
foreach ($channelInfo in $Channels) {
    $install = Find-Install -ChannelInfo $channelInfo
    if ($null -ne $install) {
        $Found += @{ Info = $channelInfo; Install = $install }
    }
}
Write-Output ("{0}Installed:{1}" -f $Bold, $Reset)
if ($Found.Count -eq 0) {
    Write-Output ("  {0}none found under %ProgramFiles%, %ProgramFiles(x86)% or %LOCALAPPDATA%{1}" -f $Dim, $Reset)
} else {
    foreach ($entry in $Found) {
        $where = if ($entry.Install.Machine) { 'machine-wide' } else { 'per-user' }
        Write-Output ("  {0,-24} {1,-12} {2}{3}{4}" -f $entry.Info.Name, (Get-InstalledVersion -ChannelInfo $entry.Info -Install $entry.Install), $Dim, $where, $Reset)
    }
}
Write-Output ''

# -- Choose action and channel ------------------------------------------------
# Arguments win. Otherwise ask - and unlike the bash installer there is no
# consumed-stdin problem, because `iex` runs the text rather than piping it
# into the shell's own input.
function Read-Choice {
    param([string]$Prompt, [int]$Max)
    while ($true) {
        $reply = Read-Host -Prompt $Prompt
        $parsed = 0
        if ([int]::TryParse($reply, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $Max) { return $parsed }
        # Write-Host, not Write-Output: the success stream IS the return value,
        # so a retry message printed there is handed back alongside the number
        # and the caller's index arithmetic fails on an array.
        Write-Host ("  Enter a number between 1 and {0}." -f $Max)
    }
}

if (-not $Action) {
    Write-Output ("{0}What would you like to do?{1}" -f $Bold, $Reset)
    Write-Output '  1) activate    apply the Brave Origin policy set'
    Write-Output '  2) deactivate  undo it, using the receipt activate wrote'
    Write-Output '  3) status      report what is applied, change nothing'
    Write-Output ''
    $Action = @('activate', 'deactivate', 'status')[(Read-Choice -Prompt '  Choice [1-3]' -Max 3) - 1]
    Write-Output ''
}

# Only activate needs a browser. A receipt outlives the install it describes -
# origin.ps1 acts on one for an uninstalled channel on purpose - so refusing
# deactivate here would mean "reinstall Brave before you may roll policy back".
if ($Found.Count -eq 0) {
    if ($Action -eq 'activate') {
        Stop-WithError "No Brave install found under %ProgramFiles%, %ProgramFiles(x86)% or %LOCALAPPDATA%.`r`n    Install Brave from https://brave.com/download and re-run."
    }
    Write-Warn 'No Brave install found. Acting on the receipt alone.'
    Write-Output ''
}

# Left empty when nothing is installed: origin.ps1 then picks the channel that
# has a receipt, which is the only channel there is anything to act on.
if (-not $Channel -and $Found.Count -gt 0) {
    if ($Found.Count -eq 1) {
        $Channel = $Found[0].Info.Id
        Write-Info ("Targeting {0} {1}(the only install found){2}" -f $Found[0].Info.Name, $Dim, $Reset)
    } else {
        Write-Output ("{0}Which install?{1}" -f $Bold, $Reset)
        for ($i = 0; $i -lt $Found.Count; $i++) {
            Write-Output ("  {0}) {1}" -f ($i + 1), $Found[$i].Info.Name)
        }
        Write-Output ''
        $Channel = $Found[(Read-Choice -Prompt ("  Choice [1-{0}]" -f $Found.Count) -Max $Found.Count) - 1].Info.Id
        Write-Output ''
    }
}

$ChannelArg = ''
if ($Channel) { $ChannelArg = " -Channel $Channel" }

# Checked after the action is known: HKLM needs an elevated token, HKCU does
# not, `status` only reads, and origin.ps1 returns from a dry run before its own
# elevation check. Failing here beats failing halfway through origin.ps1 with
# policies already half-written.
if ($Action -ne 'status' -and -not $User -and -not $DryRun -and -not (Test-Elevated)) {
    Stop-WithError -KeepOpen -Message ("Writing HKLM\SOFTWARE\Policies\BraveSoftware\Brave needs an elevated session.`r`n    Close this window, start Windows Terminal or PowerShell with 'Run as`r`n    administrator', and re-run:`r`n      {0} -Action {1}{2}`r`n    Or write your own user's policy key instead, which needs no elevation:`r`n      {0} -Action {1}{2} -User" -f $ArgCommand, $Action, $ChannelArg)
}

# -- Fetch and verify ---------------------------------------------------------
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('brave-to-origin-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
$ScriptPath = Join-Path $TempDir 'origin.ps1'
$ExitCode = 0
try {
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        Write-Info ("Using local {0}" -f $Source)
        Copy-Item -LiteralPath $Source -Destination $ScriptPath
    } else {
        Write-Info ("Fetching origin.ps1 @ {0}" -f $Ref)
        # The progress bar makes Invoke-WebRequest an order of magnitude slower
        # in 5.1, and there is nothing to watch on a 90 KB file.
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Source -OutFile $ScriptPath -UseBasicParsing -ErrorAction Stop
        } catch {
            Stop-WithError ("Download failed: {0}`r`n    {1}" -f $Source, $_.Exception.Message)
        } finally {
            $ProgressPreference = $previousProgress
        }
    }

    $ActualSha = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash.ToLower()
    # Fails closed. Anything that is not 64 hex characters is not a checksum -
    # an unreplaced placeholder, an empty value, a truncated one - and running
    # unverified code fetched over the network because the release forgot to
    # substitute a variable is the bug the bash installer already shipped once.
    # Only a human typing ORIGIN_SHA256=skip may downgrade it to a warning.
    if ($env:ORIGIN_SHA256 -eq 'skip') {
        Write-Warn 'Checksum verification skipped: ORIGIN_SHA256=skip.'
        Write-Warn ("SHA-256 is {0}" -f $ActualSha)
    } elseif ($ExpectedSha -notmatch '^[0-9a-f]{64}$') {
        Stop-WithError ("Refusing to run unverified code.`r`n    The pinned checksum reads '{0}', which is not a 64-character SHA-256 - this`r`n    copy of install.ps1 was published without a checksum substituted into it.`r`n    The downloaded file hashes to {1}, but nothing here can say that is right.`r`n    Clone the repository and run origin.ps1 directly instead:`r`n      git clone https://github.com/{2}.git`r`n      .\brave-to-origin\origin.ps1 {3}" -f $ExpectedSha, $ActualSha, $Repo, $Action)
    } elseif ($ActualSha -ne $ExpectedSha.ToLower()) {
        Stop-WithError ("Checksum mismatch - refusing to run.`r`n    expected {0}`r`n    got      {1}`r`n    Either the release moved or the download was tampered with." -f $ExpectedSha.ToLower(), $ActualSha)
    } else {
        Write-Ok 'Checksum verified'
    }

    # origin.ps1 does its own preflight, so a corrupt-but-correctly-hashed file
    # still will not run: this only catches a truncated download that somehow
    # matched, and it costs nothing.
    $parseErrors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        Stop-WithError ("Downloaded script does not parse: {0}" -f $parseErrors[0].Message)
    }

    # -- Run it ---------------------------------------------------------------
    Write-Output ''
    # Tell origin.ps1 how the user invoked it, so anything it prints back - the
    # rollback command especially - is a command they can actually paste.
    $env:ORIGIN_INVOCATION = $ArgCommand
    $cliArgs = @($Action)
    if ($Channel) { $cliArgs += @('-Channel', $Channel) }
    if ($User) { $cliArgs += '-User' }
    if ($DryRun) { $cliArgs += '-DryRun' }
    if ($NoColor) { $cliArgs += '-NoColor' }
    # Out of process with an explicit bypass. `irm | iex` is exempt from the
    # execution policy because nothing is loaded from a file, but Restricted is
    # the shipping default on client Windows and it refuses a script FILE - so
    # dot-sourcing the temp copy dies with "running scripts is disabled on this
    # system" after the elevation prompt, the download and the hash check.
    # -File also makes $LASTEXITCODE origin.ps1's own exit code, not the last
    # command inside it.
    $psExe = (Get-Process -Id $PID).Path
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @cliArgs
    $ExitCode = $LASTEXITCODE
} finally {
    $env:ORIGIN_INVOCATION = $null
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($ExitCode -eq 0 -and $Action -eq 'activate') {
    $undoUser = if ($User) { ' -User' } else { '' }
    Write-Output ''
    Write-Output ("{0}To undo this later, without cloning anything:{1}" -f $Dim, $Reset)
    Write-Output ("  {0} -Action deactivate{1}{2}" -f $ArgCommand, $ChannelArg, $undoUser)
}
Complete-Run $ExitCode
