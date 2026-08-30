# Test suite for origin.ps1. Runs on macOS or Linux against a faked registry —
# see WindowsSandbox.ps1 for the seams it rewrites.
#
#   pwsh tests/Run-Tests.ps1
#   pwsh tests/Run-Tests.ps1 -Filter receipt
#
# Asserts on observable state — registry values, the receipt, the pref files,
# the exit code — never on log wording.
[CmdletBinding()]
param([string]$Filter)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSandbox.ps1')

$script:Pass = 0; $script:Fail = 0; $script:Failed = @()
$script:Msg = ''
$KEY = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$UKEY = 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave'

function Fail-Note { param([string]$Text) $script:Msg += "      $Text`n" }

function Assert-Equal {
    param($Actual, $Expected, [string]$What)
    if ("$Actual" -ne "$Expected") { Fail-Note "${What}: expected [$Expected], got [$Actual]"; return $false }
    return $true
}
function Assert-True { param($Cond, [string]$What) if (-not $Cond) { Fail-Note $What; return $false } return $true }

# --- sandbox helpers ---------------------------------------------------------
$script:S = $null
function Setup {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("bto-" + [guid]::NewGuid().ToString('N').Substring(0,10))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $script:S = New-WindowsSandbox -Root $root
    # Profile fixtures for both channels.
    foreach ($d in @('Brave-Browser', 'Brave-Browser-Beta')) {
        $p = Join-Path $script:S.ProfileRoot "$d/User Data/Default"
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        '{"brave":{"other":1},"zoom":2.0}' | Set-Content -LiteralPath (Join-Path $p 'Preferences') -NoNewline
        '{"user_experience_metrics":{"reporting_enabled":true}}' |
            Set-Content -LiteralPath (Join-Path $script:S.ProfileRoot "$d/User Data/Local State") -NoNewline
    }
}
function Teardown { if ($script:S) { Remove-Item -Recurse -Force $script:S.Root -EA SilentlyContinue } }

function Run-Origin {
    param([string[]]$Arguments)
    $out = & pwsh -NoProfile -File $script:S.Script @Arguments -NoColor 2>&1
    return [pscustomobject]@{ Output = ($out -join "`n"); Code = $LASTEXITCODE }
}
function Reg { param([string]$Key, [string]$Name)
    $r = Get-FakeRegistry -Path $script:S.Registry
    if (-not $r.PSObject.Properties[$Key]) { return '__nokey__' }
    $k = $r.$Key
    if (-not $k.PSObject.Properties[$Name]) { return '__absent__' }
    return "$($k.$Name.Type):$($k.$Name.Value)"
}
function RegKeyExists { param([string]$Key)
    $r = Get-FakeRegistry -Path $script:S.Registry
    return [bool]$r.PSObject.Properties[$Key]
}
function PrefsPath { param([string]$Dir = 'Brave-Browser')
    Join-Path $script:S.ProfileRoot "$Dir/User Data/Default/Preferences" }
function Receipts { @(Get-ChildItem -Path $script:S.ReceiptDir -Filter *.json -EA SilentlyContinue) }
function Hash { param([string]$P) if (Test-Path $P) { (Get-FileHash -Algorithm SHA256 $P).Hash } else { '__missing__' } }

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    if ($Filter -and $Name -notlike "*$Filter*") { return }
    $script:Msg = ''
    Setup
    $ok = $false
    try { $ok = & $Body } catch { Fail-Note "threw: $_" ; $ok = $false }
    if ($ok -and -not $script:Msg) {
        Write-Host "ok   $Name"; $script:Pass++
    } else {
        Write-Host "FAIL $Name"; Write-Host -NoNewline $script:Msg
        $script:Fail++; $script:Failed += $Name
    }
    Teardown
}

# --- tests -------------------------------------------------------------------

Test-Case 'activate writes every policy as REG_DWORD' {
    Run-Origin activate | Out-Null
    (Assert-Equal (Reg $KEY 'TorDisabled') 'DWord:1' 'TorDisabled') -and
    (Assert-Equal (Reg $KEY 'BraveP3AEnabled') 'DWord:0' 'BraveP3AEnabled') -and
    (Assert-Equal (Reg $KEY 'BraveVPNDisabled') 'DWord:1' 'BraveVPNDisabled (live on Windows)')
}

Test-Case 'roundtrip leaves registry and prefs exactly as found' {
    $before = Hash (PrefsPath)
    Run-Origin activate | Out-Null
    Run-Origin deactivate | Out-Null
    (Assert-True (-not (RegKeyExists $KEY)) 'policy key should be gone') -and
    (Assert-Equal (Hash (PrefsPath)) $before 'Preferences byte-identical')
}

# A prior of another type must come back as that type. Rebuilding every prior as
# a DWORD is data loss wearing the costume of a rollback.
Test-Case 'restores a REG_SZ prior with its type' {
    Set-FakeRegistryValue -Path $script:S.Registry -Key $KEY -Name 'TorDisabled' -Value 'yes' -Type 'String'
    Run-Origin activate | Out-Null
    if (-not (Assert-Equal (Reg $KEY 'TorDisabled') 'DWord:1' 'overwritten')) { return $false }
    Run-Origin deactivate | Out-Null
    Assert-Equal (Reg $KEY 'TorDisabled') 'String:yes' 'restored as REG_SZ'
}

# REG_BINARY cannot be faithfully round-tripped here, so it must be refused
# rather than overwritten with a substitute.
Test-Case 'refuses a REG_BINARY prior instead of overwriting it' {
    Set-FakeRegistryValue -Path $script:S.Registry -Key $KEY -Name 'TorDisabled' -Value @(1,2,3) -Type 'Binary'
    $r = Run-Origin activate
    (Assert-True ((Reg $KEY 'TorDisabled') -like 'Binary:*') 'binary prior left alone') -and
    (Assert-True ($r.Code -ne 0) 'exits non-zero when a value was refused')
}

# Values and subkeys we did not write are someone else's.
Test-Case 'leaves foreign values and the Recommended subkey alone' {
    Set-FakeRegistryValue -Path $script:S.Registry -Key $KEY -Name 'SomebodyElsesPolicy' -Value 1 -Type 'DWord'
    Set-FakeRegistryValue -Path $script:S.Registry -Key "$KEY\Recommended" -Name 'BraveP3AEnabled' -Value 1 -Type 'DWord'
    Run-Origin activate | Out-Null
    Run-Origin deactivate | Out-Null
    (Assert-Equal (Reg $KEY 'SomebodyElsesPolicy') 'DWord:1' 'foreign value kept') -and
    (Assert-Equal (Reg "$KEY\Recommended" 'BraveP3AEnabled') 'DWord:1' 'Recommended untouched') -and
    (Assert-True (RegKeyExists $KEY) 'key kept because it still holds a foreign value')
}

Test-Case 'repeated activate keeps the earliest prior' {
    Set-FakeRegistryValue -Path $script:S.Registry -Key $KEY -Name 'TorDisabled' -Value 'original' -Type 'String'
    Run-Origin activate | Out-Null
    Run-Origin activate | Out-Null
    Run-Origin deactivate | Out-Null
    Assert-Equal (Reg $KEY 'TorDisabled') 'String:original' 'earliest prior wins'
}

# The policy key is channel-independent on Windows, so deactivating one channel
# must not strip the values another channel still wants.
Test-Case 'refcount holds the values for another channel' {
    Run-Origin @('activate', '-Channel', 'com.brave.Browser') | Out-Null
    Run-Origin @('activate', '-Channel', 'com.brave.Browser.beta') | Out-Null
    Run-Origin @('deactivate', '-Channel', 'com.brave.Browser') | Out-Null
    if (-not (Assert-Equal (Reg $KEY 'TorDisabled') 'DWord:1' 'still enforced for beta')) { return $false }
    Run-Origin @('deactivate', '-Channel', 'com.brave.Browser.beta') | Out-Null
    Assert-True (-not (RegKeyExists $KEY)) 'last channel out removes the values'
}

Test-Case 'deactivate without a receipt refuses' {
    Run-Origin activate | Out-Null
    Receipts | Remove-Item -Force
    $r = Run-Origin deactivate
    (Assert-True ($r.Code -ne 0) 'exits non-zero') -and
    (Assert-Equal (Reg $KEY 'TorDisabled') 'DWord:1' 'values left alone')
}

Test-Case 'a malformed receipt is refused and kept' {
    Run-Origin activate | Out-Null
    $rec = (Receipts | Where-Object { $_.Name -notlike 'policy-key*' })[0]
    '{"plist": truncated' | Set-Content -LiteralPath $rec.FullName -NoNewline
    $r = Run-Origin deactivate
    (Assert-True ($r.Code -ne 0) 'exits non-zero') -and
    (Assert-True (Test-Path $rec.FullName) 'receipt kept') -and
    (Assert-Equal (Reg $KEY 'TorDisabled') 'DWord:1' 'values still applied')
}

Test-Case 'dry run writes nothing' {
    $before = Hash (PrefsPath)
    Run-Origin @('activate', '-DryRun') | Out-Null
    (Assert-True (-not (RegKeyExists $KEY)) 'no registry write') -and
    (Assert-Equal (@(Receipts).Count) 0 'no receipt') -and
    (Assert-Equal (Hash (PrefsPath)) $before 'prefs untouched')
}

Test-Case 'user hive is separate from machine hive' {
    Run-Origin @('activate', '-User') | Out-Null
    (Assert-Equal (Reg $UKEY 'TorDisabled') 'DWord:1' 'written to HKCU') -and
    (Assert-True (-not (RegKeyExists $KEY)) 'HKLM untouched')
}

Test-Case 'refuses to run while that Brave is running' {
    $env:SBX_BRAVE_RUNNING = '1'
    try { $r = Run-Origin activate } finally { Remove-Item Env:SBX_BRAVE_RUNNING }
    (Assert-True ($r.Code -ne 0) 'exits non-zero') -and
    (Assert-True (-not (RegKeyExists $KEY)) 'nothing written')
}

# PowerShell 5.1's ConvertFrom-Json collapses 2.0 to 2, and Chromium then
# discards the pref as the wrong type. The prefs are spliced as raw text to
# avoid exactly that.
Test-Case 'pref rewrite preserves number formatting elsewhere in the file' {
    Run-Origin activate | Out-Null
    $text = Get-Content -Raw (PrefsPath)
    Assert-True ($text -match '"zoom"\s*:\s*2\.0') 'zoom:2.0 must not become 2'
}

# Losing the refcount must not lose the prior: it is mirrored into the
# per-channel receipt precisely so a third party's value can still be restored.
Test-Case 'a lost refcount still restores a foreign prior' {
    Set-FakeRegistryValue -Path $script:S.Registry -Key $KEY -Name 'TorDisabled' -Value 'corp' -Type 'String'
    Run-Origin activate | Out-Null
    Receipts | Where-Object { $_.Name -like 'policy-key*' } | Remove-Item -Force
    Run-Origin deactivate | Out-Null
    Assert-Equal (Reg $KEY 'TorDisabled') 'String:corp' 'corp value restored, not deleted'
}

Test-Case 'status changes nothing' {
    Run-Origin activate | Out-Null
    $before = (Get-Content -Raw $script:S.Registry)
    $prefs = Hash (PrefsPath)
    Run-Origin status | Out-Null
    (Assert-Equal (Get-Content -Raw $script:S.Registry) $before 'registry unchanged') -and
    (Assert-Equal (Hash (PrefsPath)) $prefs 'prefs unchanged')
}

# The two hives have separate receipt directories, so a cross-scope check that
# scans only one of them can never fire. activate then activate -User then
# deactivate must not leave HKCU enforced and unmentioned.
Test-Case 'deactivating one hive does not silently strand the other' {
    Run-Origin activate | Out-Null
    Run-Origin @('activate', '-User') | Out-Null
    Run-Origin deactivate | Out-Null
    if (-not (Assert-Equal (Reg $UKEY 'TorDisabled') 'DWord:1' 'HKCU still enforced (expected)')) { return $false }
    # Something must still be able to roll HKCU back, and status must say so.
    # It is not enough for "HKCU" to appear in a table header: status must say
    # the other scope is still ACTIVE, and must not headline "No receipt".
    $st = Run-Origin status
    (Assert-True ($st.Output -match 'still active|other (hive|scope)|per-user scope') `
        'status must report the other hive as still active') -and
    (Assert-True ($st.Output -notmatch 'No receipt') 'must not claim there is no receipt') -and
    (Assert-True ((Run-Origin @('deactivate', '-User')).Code -eq 0) 'the user hive must still be rollbackable') -and
    (Assert-True (-not (RegKeyExists $UKEY)) 'HKCU cleaned up')
}

# A receipt record with a missing or non-numeric value must be reported, not
# thrown as a raw .NET FormatException mid-rollback.
Test-Case 'a bad prior record fails cleanly instead of throwing' {
    Set-FakeRegistryValue -Path $script:S.Registry -Key $KEY -Name 'TorDisabled' -Value 5 -Type 'DWord'
    Run-Origin activate | Out-Null
    $rec = (Receipts | Where-Object { $_.Name -notlike 'policy-key*' })[0]
    $text = Get-Content -Raw $rec.FullName
    $text = $text -replace '"value"\s*:\s*5', '"value": "not-a-number"'
    Set-Content -LiteralPath $rec.FullName -Value $text -NoNewline
    $r = Run-Origin deactivate
    (Assert-True ($r.Output -notmatch 'FormatException|Exception calling|at System\.') 'no raw .NET error') -and
    (Assert-True ($r.Code -ne 0) 'exits non-zero') -and
    (Assert-True (Test-Path $rec.FullName) 'receipt kept for recovery')
}

# The bash installer once shipped with its checksum gate silently disabled. The
# PowerShell one must refuse to run unverified code, not warn and continue.
Test-Case 'installer refuses an unpinned checksum instead of warning' {
    # Give it a findable install and a local source, so the only thing that can
    # stop it is the checksum gate itself.
    $inst = New-InstallerSandbox -Root $script:S.Root -ScanRoot (Join-Path $script:S.Root 'ProgramFiles')
    $env:ORIGIN_SOURCE = $script:S.Script
    try {
        $out = & pwsh -NoProfile -File $inst -Action status -Channel com.brave.Browser 2>&1
        $code = $LASTEXITCODE
    } finally { Remove-Item Env:ORIGIN_SOURCE -EA SilentlyContinue }
    $joined = ($out -join "`n")
    (Assert-True ($code -ne 0) 'must exit non-zero with an unsubstituted placeholder') -and
    (Assert-True ($joined -notmatch 'Environment') 'must not have run origin.ps1')
}

# The documented Windows path is `irm ... | iex`, which evaluates the script
# text in the CALLER's scope. A param block with [ValidateSet] then tries to
# attach that attribute to a variable holding the empty default, and the run
# dies before a single line executes. Invoking with -File never sees this, so
# every other installer test here misses it.
Test-Case 'installer survives being run through iex with no arguments' {
    $inst = New-InstallerSandbox -Root $script:S.Root -ScanRoot (Join-Path $script:S.Root 'ProgramFiles')
    $env:ORIGIN_SOURCE = $script:S.Script
    try {
        # Answers for the action and channel prompts, so the run does not block.
        $out = "3`n1`n" | & pwsh -NoProfile -Command "`$t = Get-Content -Raw '$inst'; `$t | Invoke-Expression" 2>&1
    } finally { Remove-Item Env:ORIGIN_SOURCE -EA SilentlyContinue }
    $joined = ($out -join "`n")
    (Assert-True ($joined -notmatch 'attribute cannot be added') 'param block must survive iex') -and
    (Assert-True ($joined -notmatch 'ValidateSetFailure') 'no ValidateSet failure') -and
    (Assert-True ($joined -match 'Brave to Origin') 'must reach the banner')
}

# --- summary -----------------------------------------------------------------
Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "$($script:Pass) passed"
    exit 0
}
Write-Host "$($script:Fail) failed, $($script:Pass) passed"
foreach ($n in $script:Failed) { Write-Host "  - $n" }
exit 1
