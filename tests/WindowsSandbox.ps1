# Builds a sandboxed copy of origin.ps1 that runs off Windows.
#
# origin.ps1 talks to the registry through eleven single-purpose functions and
# assigns its path roots one per line. This rewrites exactly those, and nothing
# else: the registry becomes a JSON file, the roots move into a temp directory,
# and every line of policy, receipt and rollback logic under test is the shipped
# line. Same discipline as tests/sandbox.sh for bash — no test hooks in the
# production script.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-WindowsSandbox {
    param([string]$Root)

    $repo = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $src = Join-Path $repo 'origin.ps1'
    $text = Get-Content -Raw $src

    $reg      = Join-Path $Root 'registry.json'
    $progData = Join-Path $Root 'ProgramData'
    $localApp = Join-Path $Root 'LocalAppData'
    $progFiles= Join-Path $Root 'ProgramFiles'
    foreach ($d in @($progData, $localApp, $progFiles)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    '{}' | Set-Content -LiteralPath $reg -NoNewline

    # A fake install for stable and beta: the version directory is what the
    # version lookup falls back to, and the probe file stands in for the DLL.
    foreach ($ch in @(@('Brave-Browser','1.94.117'), @('Brave-Browser-Beta','1.95.87'))) {
        $app = Join-Path $progFiles "BraveSoftware/$($ch[0])/Application"
        New-Item -ItemType Directory -Force -Path (Join-Path $app $ch[1]) | Out-Null
        'stub' | Set-Content -LiteralPath (Join-Path $app 'brave.exe') -NoNewline
        # The capability probe greps this for policy names; naming them all
        # makes every policy report as supported.
        $names = ([regex]::Matches($text, "'(Brave[A-Za-z]+|TorDisabled|EmailAliasesEnabled|PsstEnabled)'") |
                  ForEach-Object { $_.Groups[1].Value }) -join "`n"
        $names | Set-Content -LiteralPath (Join-Path $app "$($ch[1])/brave.dll")
    }

    $repl = [ordered]@{
        # Platform refusal.
        '^\$script:IsWindowsHost\s*=.*$'         = '$script:IsWindowsHost = $true'
        # Path roots, one assignment per line.
        "^\`$script:ReceiptDirMachine\s*=.*$"    = "`$script:ReceiptDirMachine = '$progData/brave-to-origin'"
        "^\`$script:ReceiptDirUser\s*=.*$"       = "`$script:ReceiptDirUser = '$localApp/brave-to-origin-user'"
        "^\`$script:ProfileRoot\s*=.*$"          = "`$script:ProfileRoot = '$localApp/BraveSoftware'"
        "^\`$script:ProgramFilesRoot\s*=.*$"     = "`$script:ProgramFilesRoot = '$progFiles'"
        "^\`$script:ProgramFilesX86Root\s*=.*$"  = "`$script:ProgramFilesX86Root = `$null"
        "^\`$script:LocalAppDataRoot\s*=.*$"     = "`$script:LocalAppDataRoot = '$localApp'"
    }
    foreach ($k in $repl.Keys) {
        $new = [regex]::Replace($text, $k, $repl[$k], 'Multiline')
        if ($new -eq $text) { throw "sandbox seam not found: $k" }
        $text = $new
    }

    # Replace the registry accessors wholesale. Each `function X {` sits on its
    # own line with its closing brace at column 0, which is what makes this a
    # seam rather than a guess.
    $fake = @'
function Get-FakeReg {
    $raw = Get-Content -Raw -LiteralPath $script:FakeRegPath
    $o = $raw | ConvertFrom-Json
    $h = @{}
    foreach ($p in $o.PSObject.Properties) {
        $vals = @{}
        foreach ($v in $p.Value.PSObject.Properties) {
            $vals[$v.Name] = @{ Type = $v.Value.Type; Value = $v.Value.Value }
        }
        $h[$p.Name] = $vals
    }
    return $h
}
function Set-FakeReg {
    param($Data)
    $o = [ordered]@{}
    foreach ($k in ($Data.Keys | Sort-Object)) {
        $vals = [ordered]@{}
        foreach ($n in ($Data[$k].Keys | Sort-Object)) {
            $vals[$n] = [ordered]@{ Type = $Data[$k][$n].Type; Value = $Data[$k][$n].Value }
        }
        $o[$k] = $vals
    }
    ($o | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $script:FakeRegPath -NoNewline
}
function Get-PolicyValueRaw {
    param([string]$Name, [string]$KeyPath = $script:PolicyKeyPath)
    $r = Get-FakeReg
    if (-not $r.ContainsKey($KeyPath)) { return $null }
    if (-not $r[$KeyPath].ContainsKey($Name)) { return $null }
    return @{ Type = $r[$KeyPath][$Name].Type; Value = $r[$KeyPath][$Name].Value }
}
function Set-PolicyValueRaw {
    param([string]$Name, $Value, [string]$Type = 'DWord', [string]$KeyPath = $script:PolicyKeyPath)
    $r = Get-FakeReg
    if (-not $r.ContainsKey($KeyPath)) { $r[$KeyPath] = @{} }
    $r[$KeyPath][$Name] = @{ Type = $Type; Value = $Value }
    Set-FakeReg $r
}
function Remove-PolicyValueRaw {
    param([string]$Name, [string]$KeyPath = $script:PolicyKeyPath)
    $r = Get-FakeReg
    if ($r.ContainsKey($KeyPath)) { $r[$KeyPath].Remove($Name); Set-FakeReg $r }
}
function Test-PolicyKeyExists {
    param([string]$KeyPath = $script:PolicyKeyPath)
    $r = Get-FakeReg
    return $r.ContainsKey($KeyPath)
}
function Get-PolicyValueNames {
    param([string]$KeyPath = $script:PolicyKeyPath)
    $r = Get-FakeReg
    if (-not $r.ContainsKey($KeyPath)) { return @() }
    return @($r[$KeyPath].Keys)
}
function Get-PolicySubKeyNames {
    param([string]$KeyPath = $script:PolicyKeyPath)
    $r = Get-FakeReg
    $out = @()
    foreach ($k in $r.Keys) {
        if ($k -like "$KeyPath\*") {
            $rest = $k.Substring($KeyPath.Length + 1)
            if ($rest -notmatch '\\') { $out += $rest }
        }
    }
    return @($out)
}
function Remove-PolicyKeyRaw {
    param([string]$KeyPath = $script:PolicyKeyPath)
    $r = Get-FakeReg
    if ($r.ContainsKey($KeyPath)) { $r.Remove($KeyPath); Set-FakeReg $r }
}
function Get-UpdaterVersion {
    param([string]$Guid, [string]$Hive)
    return $null
}
function Test-Elevated {
    return $true
}
function Test-BraveRunning {
    param([string]$ExePath)
    return [bool]$env:SBX_BRAVE_RUNNING
}
function Protect-ReceiptDirectory {
    param([string]$Path)
}
'@

    foreach ($fn in @('Get-PolicyValueRaw','Set-PolicyValueRaw','Remove-PolicyValueRaw',
                      'Test-PolicyKeyExists','Get-PolicyValueNames','Get-PolicySubKeyNames',
                      'Get-UpdaterVersion','Test-Elevated','Test-BraveRunning',
                      'Protect-ReceiptDirectory','Remove-PolicyKeyRaw')) {
        $pattern = "(?ms)^function\s+$fn\s*\{.*?^\}\r?\n"
        if ([regex]::IsMatch($text, $pattern)) {
            $text = [regex]::Replace($text, $pattern, '', 1)
        }
    }
    # Remove-PolicyKeyIfEmpty deletes the key with Remove-Item directly. Its
    # "only when empty" guard is logic under test, so only the deletion itself
    # is redirected into the fake, not the function around it.
    $text = $text -replace 'Remove-Item\s+-LiteralPath\s+\$KeyPath[^\r\n]*', 'Remove-PolicyKeyRaw -KeyPath $KeyPath'

    $header = "`$script:FakeRegPath = '$reg'`n$fake`n"
    # Insert after the param block and strict-mode lines so the fakes are
    # defined before anything calls them.
    $idx = $text.IndexOf("`$ErrorActionPreference")
    if ($idx -lt 0) { throw "could not find an insertion point" }
    $eol = $text.IndexOf("`n", $idx)
    $text = $text.Substring(0, $eol + 1) + $header + $text.Substring($eol + 1)

    $out = Join-Path $Root 'origin-sandboxed.ps1'
    Set-Content -LiteralPath $out -Value $text -NoNewline

    $errors = $null; $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($out, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        throw "sandboxed copy does not parse: $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))"
    }
    return [pscustomobject]@{
        Script = $out; Registry = $reg; ReceiptDir = (Join-Path $progData 'brave-to-origin')
        ProfileRoot = (Join-Path $localApp 'BraveSoftware'); Root = $Root
    }
}

function Get-FakeRegistry {
    param([string]$Path)
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Set-FakeRegistryValue {
    param([string]$Path, [string]$Key, [string]$Name, $Value, [string]$Type = 'DWord')
    $raw = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $h = @{}
    foreach ($p in $raw.PSObject.Properties) {
        $vals = @{}
        foreach ($v in $p.Value.PSObject.Properties) { $vals[$v.Name] = @{ Type = $v.Value.Type; Value = $v.Value.Value } }
        $h[$p.Name] = $vals
    }
    if (-not $h.ContainsKey($Key)) { $h[$Key] = @{} }
    $h[$Key][$Name] = @{ Type = $Type; Value = $Value }
    $o = [ordered]@{}
    foreach ($k in ($h.Keys | Sort-Object)) {
        $vals = [ordered]@{}
        foreach ($n in ($h[$k].Keys | Sort-Object)) { $vals[$n] = [ordered]@{ Type = $h[$k][$n].Type; Value = $h[$k][$n].Value } }
        $o[$k] = $vals
    }
    ($o | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -NoNewline
}

# Sandboxes install.ps1. Only the platform and elevation checks are rewritten;
# the checksum gate, the argument handling and the prompts are the shipped code.
function New-InstallerSandbox {
    param([string]$Root, [string]$ScanRoot)
    $repo = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $text = Get-Content -Raw (Join-Path $repo 'install.ps1')

    foreach ($pair in @(
        @('^\$IsWindowsHost\s*=.*$',       '$IsWindowsHost = $true'),
        @('^\$script:IsWindowsHost\s*=.*$', '$script:IsWindowsHost = $true')
    )) {
        $text = [regex]::Replace($text, $pair[0], $pair[1], 'Multiline')
    }
    $text = [regex]::Replace($text, "(?ms)^function\s+Test-Elevated\s*\{.*?^\}\r?\n",
                             "function Test-Elevated {`n    return `$true`n}`n", 1)
    # Point the install scan at the sandbox, so the installer finds the same
    # fake Brave the origin.ps1 sandbox created.
    if ($ScanRoot) {
        $text = $text.Replace('@{ Root = $env:ProgramFiles; Machine = $true }',
                              ("@{{ Root = '{0}'; Machine = `$true }}" -f $ScanRoot))
        $text = $text.Replace('@{ Root = ${env:ProgramFiles(x86)}; Machine = $true }',
                              '@{ Root = $null; Machine = $true }')
        $text = $text.Replace('@{ Root = $env:LOCALAPPDATA; Machine = $false }',
                              '@{ Root = $null; Machine = $false }')
    }
    $out = Join-Path $Root 'install-sandboxed.ps1'
    Set-Content -LiteralPath $out -Value $text -NoNewline
    $errors = $null; $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($out, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw "installer sandbox does not parse: $($errors[0].Message)" }
    return $out
}
