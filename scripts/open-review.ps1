[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobRoot,
    [ValidateRange(1024, 65535)][int]$Port = 4173,
    [switch]$NoBrowser,
    [ValidateRange(0, 3600)][int]$AutoStopSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$serverPath = Join-Path $repoRoot 'app\server.mjs'
$jobRootFull = [System.IO.Path]::GetFullPath($JobRoot)
$projectPath = Join-Path $jobRootFull 'project.json'
$stateDir = Join-Path $jobRootFull '_state'
$url = "http://127.0.0.1:$Port"
$serverProcess = $null
$shutdownToken = [guid]::NewGuid().ToString('N')

if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "아직 인입되지 않은 작업입니다: $jobRootFull"
}
[void][System.IO.Directory]::CreateDirectory($stateDir)

try {
    $existing = Invoke-RestMethod -Method Get -Uri "$url/api/bootstrap" -TimeoutSec 1
    $expectedJobId = Split-Path -Leaf $jobRootFull
    if ($existing.project.jobId -ne $expectedJobId) {
        throw "포트 $Port 에 다른 검수 작업이 실행 중입니다. 해당 창을 먼저 종료하세요."
    }
    Write-Host '이미 이 작업의 검수 서버가 실행 중입니다.' -ForegroundColor Yellow
    if (-not $NoBrowser) { Start-Process $url }
    return
} catch {
    if ($_.Exception.Message -like '*다른 검수 작업*') { throw }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdoutPath = Join-Path $stateDir "review-server-$timestamp.stdout.log"
$stderrPath = Join-Path $stateDir "review-server-$timestamp.stderr.log"
$previousToken = $env:PPT_REVIEW_SHUTDOWN_TOKEN
$previousOwner = $env:PPT_REVIEW_OWNER_PID

try {
    $env:PPT_REVIEW_SHUTDOWN_TOKEN = $shutdownToken
    $env:PPT_REVIEW_OWNER_PID = [string]$PID
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    $serverArgs = @(
        ('"{0}"' -f $serverPath),
        '--job', ('"{0}"' -f $jobRootFull),
        '--port', [string]$Port
    )
    $serverProcess = Start-Process -FilePath $nodePath -ArgumentList $serverArgs -WorkingDirectory $repoRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    Write-Host ("검수 서버 시작 PID {0}" -f $serverProcess.Id) -ForegroundColor DarkGray
} finally {
    $env:PPT_REVIEW_SHUTDOWN_TOKEN = $previousToken
    $env:PPT_REVIEW_OWNER_PID = $previousOwner
}

try {
    $deadline = (Get-Date).AddSeconds(10)
    $ready = $false
    do {
        if ($serverProcess.HasExited) {
            $errorText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $stderrPath } else { '' }
            throw "검수 서버가 시작 중 종료됐습니다. $errorText"
        }
        try {
            $bootstrap = Invoke-RestMethod -Method Get -Uri "$url/api/bootstrap" -TimeoutSec 1
            $ready = $bootstrap.project.jobId -eq (Split-Path -Leaf $jobRootFull)
        } catch {
            $ready = $false
            Start-Sleep -Milliseconds 150
        }
    } while (-not $ready -and (Get-Date) -lt $deadline)
    if (-not $ready) { throw '10초 안에 검수 화면을 열지 못했습니다.' }

    if (-not $NoBrowser) { Start-Process $url }
    Write-Host ''
    Write-Host '검수 화면이 열렸습니다.' -ForegroundColor Green
    Write-Host '브라우저에서 작업한 내용은 즉시 저장됩니다.'
    if ($AutoStopSeconds -gt 0) {
        Start-Sleep -Seconds $AutoStopSeconds
    } else {
        [void](Read-Host '검수를 마치고 서버를 종료하려면 여기서 Enter')
    }
} finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        try {
            Invoke-RestMethod -Method Post -Uri "$url/api/_shutdown" -Headers @{ 'x-shutdown-token' = $shutdownToken } -ContentType 'application/json' -Body '{}' -TimeoutSec 3 | Out-Null
        } catch {
            Write-Warning '정상 종료 요청에 실패해 소유한 서버 PID만 정리합니다.'
        }
        if (-not $serverProcess.WaitForExit(5000)) {
            Stop-Process -Id $serverProcess.Id -ErrorAction Stop
            $serverProcess.WaitForExit(5000) | Out-Null
        }
    }
    if ($null -ne $serverProcess) {
        Write-Host ("검수 서버 종료 PID {0}, StillRunning={1}" -f $serverProcess.Id, (-not $serverProcess.HasExited)) -ForegroundColor DarkGray
    }
}
