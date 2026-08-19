[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourcePptx,
    [string]$SourcePngZip,
    [Parameter(Mandatory = $true)][string]$JobsRoot,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]+$')][string]$JobId,
    [Parameter(Mandatory = $true)][string]$DisplayName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePptxFull = [System.IO.Path]::GetFullPath($SourcePptx)
$jobsRootFull = [System.IO.Path]::GetFullPath($JobsRoot)
$portableJobsRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'jobs'))
$jobRoot = [System.IO.Path]::GetFullPath((Join-Path $jobsRootFull $JobId))

if (-not (Test-Path -LiteralPath $sourcePptxFull -PathType Leaf)) {
    throw "PPTX source not found: $sourcePptxFull"
}
if ([System.IO.Path]::GetExtension($sourcePptxFull) -ne '.pptx') {
    throw 'SourcePptx must be a .pptx file.'
}
if (-not $jobsRootFull.Equals($portableJobsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "JobsRoot must be the Local Project jobs folder so the whole pipeline remains portable: $portableJobsRoot"
}
if (-not $jobRoot.StartsWith($jobsRootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Job path escaped the jobs root.'
}
if (Test-Path -LiteralPath $jobRoot) {
    throw "Job already exists: $jobRoot"
}

$inputDir = Join-Path $jobRoot '00_input'
New-Item -ItemType Directory -Path $inputDir -Force | Out-Null
Copy-Item -LiteralPath $sourcePptxFull -Destination (Join-Path $inputDir 'original.pptx')

if ($SourcePngZip) {
    $sourcePngZipFull = [System.IO.Path]::GetFullPath($SourcePngZip)
    if (-not (Test-Path -LiteralPath $sourcePngZipFull -PathType Leaf)) {
        throw "PNG ZIP source not found: $sourcePngZipFull"
    }
    Copy-Item -LiteralPath $sourcePngZipFull -Destination (Join-Path $inputDir 'reference-png.zip')
}

Copy-Item -LiteralPath (Join-Path $repoRoot 'templates\WORKFLOW.md') -Destination (Join-Path $jobRoot 'WORKFLOW.md')
Copy-Item -LiteralPath (Join-Path $repoRoot 'templates\review-launcher.cmd') -Destination (Join-Path $jobRoot '검수화면_열기.cmd')

& (Join-Path $PSScriptRoot 'ingest-job.ps1') -JobRoot $jobRoot -DisplayName $DisplayName

Write-Output $jobRoot
