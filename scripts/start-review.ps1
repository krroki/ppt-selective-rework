[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobRoot,
    [ValidateRange(1024, 65535)][int]$Port = 4173
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$serverPath = Join-Path $repoRoot 'app\server.mjs'
$jobRootFull = [System.IO.Path]::GetFullPath($JobRoot)

if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
    throw "Review server not found: $serverPath"
}
if (-not (Test-Path -LiteralPath (Join-Path $jobRootFull 'project.json') -PathType Leaf)) {
    throw "The job has not been ingested: $jobRootFull"
}

& node $serverPath --job $jobRootFull --port $Port
exit $LASTEXITCODE
