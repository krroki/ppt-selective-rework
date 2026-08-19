[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$results = [System.Collections.Generic.List[object]]::new()

function Add-EnvironmentResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Detail,
        [bool]$Required = $true
    )

    $results.Add([pscustomobject]@{
        Required = $Required
        Check = $Name
        Passed = $Passed
        Detail = $Detail
    })
}

$isWindowsPlatform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
Add-EnvironmentResult -Name 'Windows' -Passed $isWindowsPlatform -Detail ([System.Environment]::OSVersion.VersionString)

$powerShellVersion = $PSVersionTable.PSVersion
$powerShellReady = $powerShellVersion.Major -gt 5 -or ($powerShellVersion.Major -eq 5 -and $powerShellVersion.Minor -ge 1)
Add-EnvironmentResult -Name 'PowerShell 5.1+' -Passed $powerShellReady -Detail $powerShellVersion.ToString()

$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCommand) {
    Add-EnvironmentResult -Name 'Node.js 20+' -Passed $false -Detail 'node command was not found.'
} else {
    $nodeVersionText = (& $nodeCommand.Source --version).Trim()
    $nodeMajor = [int]($nodeVersionText.TrimStart('v').Split('.')[0])
    Add-EnvironmentResult -Name 'Node.js 20+' -Passed ($nodeMajor -ge 20) -Detail $nodeVersionText
}

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) {
    Add-EnvironmentResult -Name 'Git' -Passed $false -Detail 'git command was not found.'
} else {
    Add-EnvironmentResult -Name 'Git' -Passed $true -Detail ((& $gitCommand.Source --version).Trim())
}

$drawingReady = $true
$drawingDetail = 'System.Drawing is available.'
try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    $drawingReady = $false
    $drawingDetail = $_.Exception.Message
}
Add-EnvironmentResult -Name 'System.Drawing' -Passed $drawingReady -Detail $drawingDetail

$requiredPaths = @(
    'AGENTS.md',
    'README.md',
    'app\server.mjs',
    'scripts\new-job.ps1',
    'scripts\open-review.ps1',
    'templates\WORKFLOW.md'
)
$missingPaths = @($requiredPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Leaf) })
Add-EnvironmentResult -Name 'Pipeline files' -Passed ($missingPaths.Count -eq 0) -Detail $(
    if ($missingPaths.Count -eq 0) { $repoRoot } else { 'Missing: ' + ($missingPaths -join ', ') }
)

$results | Format-Table Required, Check, Passed, Detail -AutoSize

$failedRequired = @($results | Where-Object { $_.Required -and -not $_.Passed })
if ($failedRequired.Count -gt 0) {
    throw "Required environment checks failed: $($failedRequired.Check -join ', ')"
}

Write-Host 'Environment check passed. This PC can run the same Local Project.' -ForegroundColor Green
