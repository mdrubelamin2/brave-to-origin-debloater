# Windows ships PowerShell 5.1 and nothing newer. This suite runs on pwsh 7,
# which accepts syntax 5.1 rejects outright — a ternary or a `&&` chain parses
# clean here and dies on every real Windows box with a syntax error, before a
# single line executes. There is no 5.1 to test against on macOS, so this walks
# the parsed AST looking for constructs 5.1 does not have.
#
#   pwsh tests/Test-Ps51Compat.ps1
#
# Exits non-zero on the first file with a finding.
[CmdletBinding()]
param([string[]]$Path)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $Path -or $Path.Count -eq 0) {
    $root = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $Path = @("$root/origin.ps1", "$root/install.ps1")
}

$findings = @()

function Add-Finding {
    param($File, $Line, $What, $Fix)
    $script:findings += [pscustomobject]@{
        File = Split-Path $File -Leaf; Line = $Line; What = $What; Fix = $Fix
    }
}

foreach ($file in $Path) {
    if (-not (Test-Path $file)) { Write-Host "skip (missing): $file"; continue }

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $file, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Add-Finding $file $errors[0].Extent.StartLineNumber `
            "does not parse: $($errors[0].Message)" "fix the syntax error"
        continue
    }

    # AST node types that simply do not exist in 5.1.
    $byType = @{
        'TernaryExpressionAst'      = @('ternary ? :', 'use if/else')
        'PipelineChainAst'          = @('&& or || chain', 'use separate statements with if ($?)')
    }
    foreach ($typeName in $byType.Keys) {
        $hits = $ast.FindAll({
            param($n) $n.GetType().Name -eq $typeName }, $true)
        foreach ($h in $hits) {
            Add-Finding $file $h.Extent.StartLineNumber $byType[$typeName][0] $byType[$typeName][1]
        }
    }

    # Null-coalescing and null-conditional are tokens, not node types.
    foreach ($t in $tokens) {
        if ($t.Kind -in 'QuestionQuestion', 'QuestionQuestionEquals') {
            Add-Finding $file $t.Extent.StartLineNumber '?? null-coalescing' 'use if ($null -eq ...)'
        }
        if ($t.Kind -eq 'QuestionDot') {
            Add-Finding $file $t.Extent.StartLineNumber '?. null-conditional' 'guard with an if'
        }
    }

    # Parameters added after 5.1. Checked on the command that owns them, so an
    # unrelated -Depth on a 5.1-capable cmdlet is not flagged.
    $badParams = @{
        'ConvertFrom-Json' = @('AsHashtable', 'Depth', 'NoEnumerate')
        'ConvertTo-Json'   = @('AsArray', 'EscapeHandling')
        'ForEach-Object'   = @('Parallel', 'ThrottleLimit')
        'Get-Content'      = @('AsByteStream')
        'Set-Content'      = @('AsByteStream')
        'Test-Connection'  = @('TargetName')
        'Start-Process'    = @('Environment')
        'Get-Error'        = @()
    }
    $cmds = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if ($name -eq 'Get-Error') {
            Add-Finding $file $c.Extent.StartLineNumber 'Get-Error (7.0+)' 'use $Error[0]'
            continue
        }
        if (-not $badParams.ContainsKey($name)) { continue }
        foreach ($el in $c.CommandElements) {
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                foreach ($bad in $badParams[$name]) {
                    if ($el.ParameterName -like "$bad*") {
                        Add-Finding $file $el.Extent.StartLineNumber `
                            "$name -$($el.ParameterName) (7.x only)" 'rewrite for 5.1'
                    }
                }
            }
        }
    }

    # $IsWindows and friends are automatic variables in 6+ only. On 5.1 they are
    # undefined, so `if ($IsWindows)` is silently false under StrictMode-less
    # code and an error under Set-StrictMode. Assigning your own is fine.
    $assigned = @{}
    foreach ($a in $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $assigned[$a.Left.VariablePath.UserPath] = $true
        }
    }
    foreach ($v in $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $n = $v.VariablePath.UserPath
        if ($n -in 'IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR' -and -not $assigned[$n]) {
            Add-Finding $file $v.Extent.StartLineNumber `
                "`$$n is 6.0+ only and is not assigned here" 'test $env:OS or [Environment]::OSVersion'
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host "PowerShell 5.1 compatibility: clean ($($Path.Count) file(s))"
    exit 0
}
Write-Host "PowerShell 5.1 compatibility: $($findings.Count) finding(s)"
$findings | Sort-Object File, Line | Format-Table -AutoSize | Out-String | Write-Host
exit 1
