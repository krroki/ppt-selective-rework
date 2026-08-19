[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobRoot,
    [int]$Port = 4174,
    [string]$ExistingUrl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$jobRootFull = [System.IO.Path]::GetFullPath($JobRoot)
$decisionsPath = Join-Path $jobRootFull '02_triage\decisions.json'
$projectPath = Join-Path $jobRootFull 'project.json'
$stateDir = Join-Path $jobRootFull '_state'

if (-not (Test-Path -LiteralPath $decisionsPath -PathType Leaf)) {
    throw "Missing decisions file: $decisionsPath"
}
if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
    throw "Missing state directory: $stateDir"
}

$backupPath = Join-Path $stateDir ("qa-decisions-backup-{0}.json" -f $PID)
$stdoutPath = Join-Path $stateDir ("qa-server-{0}.out.log" -f $PID)
$stderrPath = Join-Path $stateDir ("qa-server-{0}.err.log" -f $PID)
$shutdownToken = [Guid]::NewGuid().ToString('N')
$server = $null
$beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $decisionsPath).Hash

Copy-Item -LiteralPath $decisionsPath -Destination $backupPath
$ownsServer = -not $ExistingUrl
if ($ownsServer) {
    $env:PPT_REVIEW_SHUTDOWN_TOKEN = $shutdownToken
}

try {
    if ($ownsServer) {
        $server = Start-Process -FilePath 'node' `
            -ArgumentList @('app/server.mjs', '--job', $jobRootFull, '--port', [string]$Port) `
            -WorkingDirectory $repoRoot `
            -WindowStyle Hidden `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        Write-Output ("StartedResidentPID={0} CreatedAt={1:o} ParentPID={2} Purpose=temporary-human-override-integration-test ReuseUntil=test-complete ShutdownTrigger=authenticated-api" -f $server.Id, $server.StartTime, $PID)
        $baseUrl = "http://127.0.0.1:$Port"
    } else {
        $baseUrl = $ExistingUrl.TrimEnd('/')
        Write-Output ("PreservedExistingServer={0} Purpose=legacy-runtime-compatibility-test" -f $baseUrl)
    }
    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            Invoke-RestMethod -Uri "$baseUrl/api/bootstrap" -TimeoutSec 1 | Out-Null
            $ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $ready) {
        throw "Temporary review server did not become ready on port $Port"
    }

    $patchBody = @{ status = 'keep'; reason = 'QA_PRESERVE_HUMAN_OVERRIDE' } | ConvertTo-Json
    Invoke-RestMethod -Method Patch -Uri "$baseUrl/api/slides/13" -ContentType 'application/json' -Body $patchBody | Out-Null

    $project = Get-Content -Raw -Encoding UTF8 -LiteralPath $projectPath | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'ingest-job.ps1') -JobRoot $jobRootFull -DisplayName ([string]$project.displayName) | Out-Null

    $state = Invoke-RestMethod -Uri "$baseUrl/api/bootstrap"
    $slide = $state.slides | Where-Object slide -eq 13
    Write-Output ("PreservationCheck slide={0} status={1} source={2} reason={3}" -f $slide.slide, $slide.status, $slide.source, $slide.reason)
    if ($slide.status -ne 'keep' -or $slide.source -ne 'human' -or $slide.reason -ne 'QA_PRESERVE_HUMAN_OVERRIDE') {
        throw 'Human override was not preserved by re-ingest'
    }
} finally {
    if ($null -ne $server) {
        try {
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/_shutdown" `
                -Headers @{ 'x-shutdown-token' = $shutdownToken } `
                -ContentType 'application/json' `
                -Body '{}' `
                -TimeoutSec 2 | Out-Null
        } catch {
            Write-Warning "Authenticated server shutdown request failed: $($_.Exception.Message)"
        }

        [void]$server.WaitForExit(5000)
        if (-not $server.HasExited) {
            Stop-Process -Id $server.Id
            [void]$server.WaitForExit(3000)
        }
        Write-Output ("TerminatedResidentPID={0} StillRunning={1}" -f $server.Id, [int](-not $server.HasExited))
    }

    if ($ownsServer) {
        $env:PPT_REVIEW_SHUTDOWN_TOKEN = $null
    }

    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        Copy-Item -LiteralPath $backupPath -Destination $decisionsPath -Force
        $afterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $decisionsPath).Hash
        Write-Output ("StateRestored={0}" -f ($afterHash -eq $beforeHash))
    }

    foreach ($temporaryPath in @($backupPath, $stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}
