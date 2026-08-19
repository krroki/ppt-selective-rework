[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobRoot,
    [int]$Port = 4173,
    [string]$BrowserExecutable
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$jobRootFull = [System.IO.Path]::GetFullPath($JobRoot)
$reviewDir = Join-Path $jobRootFull '05_review'
$qaScript = Join-Path $PSScriptRoot 'qa-review-dashboard.py'
$serverScript = Join-Path $workspaceRoot 'app\server.mjs'
$nodePath = (Get-Command node -ErrorAction Stop).Source
$pythonPath = (Get-Command python -ErrorAction Stop).Source
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$serverStdout = Join-Path $reviewDir "server-$timestamp.stdout.log"
$serverStderr = Join-Path $reviewDir "server-$timestamp.stderr.log"
$qaStdout = Join-Path $reviewDir "qa-$timestamp.stdout.log"
$qaStderr = Join-Path $reviewDir "qa-$timestamp.stderr.log"
$reportPath = Join-Path $reviewDir 'dashboard-qa.json'
$shutdownToken = [guid]::NewGuid().ToString('N')
$serverProcess = $null
$qaProcess = $null

if ([string]::IsNullOrWhiteSpace($BrowserExecutable)) {
    $browserCandidates = [System.Collections.Generic.List[string]]::new()
    $programFiles = [System.Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [System.Environment]::GetFolderPath('ProgramFilesX86')
    foreach ($programRoot in @($programFiles, $programFilesX86)) {
        if ([string]::IsNullOrWhiteSpace($programRoot)) { continue }
        $browserCandidates.Add((Join-Path $programRoot 'Microsoft\Edge\Application\msedge.exe'))
        $browserCandidates.Add((Join-Path $programRoot 'Google\Chrome\Application\chrome.exe'))
    }
    $BrowserExecutable = $browserCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not (Test-Path -LiteralPath $BrowserExecutable -PathType Leaf)) {
    throw 'Browser executable not found. Install Edge/Chrome or pass -BrowserExecutable with its full path.'
}
if (-not (Test-Path -LiteralPath $reviewDir)) {
    New-Item -ItemType Directory -Path $reviewDir -Force | Out-Null
}

try {
    $previousToken = $env:PPT_REVIEW_SHUTDOWN_TOKEN
    $env:PPT_REVIEW_SHUTDOWN_TOKEN = $shutdownToken
    try {
        $serverArgs = @(
            ('"{0}"' -f $serverScript),
            '--job', ('"{0}"' -f $jobRootFull),
            '--port', [string]$Port
        )
        $serverProcess = Start-Process -FilePath $nodePath -ArgumentList $serverArgs -WorkingDirectory $workspaceRoot -WindowStyle Hidden -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr -PassThru
    } finally {
        $env:PPT_REVIEW_SHUTDOWN_TOKEN = $previousToken
    }
    Write-Output ("SERVER_STARTED pid={0}; role=ppt-review-server; lifecycle=resident; shutdownTrigger=authenticated-local-request" -f $serverProcess.Id)

    $deadline = (Get-Date).AddSeconds(10)
    $ready = $false
    do {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            try {
                $connect = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
                if ($connect.AsyncWaitHandle.WaitOne(250)) {
                    $client.EndConnect($connect)
                    $ready = $client.Connected
                }
            } finally { $client.Dispose() }
        } catch {
            $ready = $false
        }
        if (-not $ready) { Start-Sleep -Milliseconds 100 }
    } while (-not $ready -and (Get-Date) -lt $deadline)

    if (-not $ready) {
        throw "Review server did not listen on port $Port within 10 seconds."
    }

    $qaArgs = @(
        ('"{0}"' -f $qaScript),
        '--url', "http://127.0.0.1:$Port",
        '--job', ('"{0}"' -f $jobRootFull),
        '--browser-executable', ('"{0}"' -f $BrowserExecutable)
    )
    $qaProcess = Start-Process -FilePath $pythonPath -ArgumentList $qaArgs -WorkingDirectory $workspaceRoot -WindowStyle Hidden -RedirectStandardOutput $qaStdout -RedirectStandardError $qaStderr -PassThru -Wait
    Write-Output ("QA_PROCESS pid={0}; exitCode={1}; StillRunning={2}" -f $qaProcess.Id, $qaProcess.ExitCode, (-not $qaProcess.HasExited))

    if ($qaProcess.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $qaStderr) { Get-Content -LiteralPath $qaStderr -Encoding UTF8 }
        throw "Dashboard QA failed with exit code $($qaProcess.ExitCode)."
    }
} finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        try {
            $headers = @{ 'x-shutdown-token' = $shutdownToken }
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/_shutdown" -Headers $headers -ContentType 'application/json' -Body '{}' -TimeoutSec 3 | Out-Null
        } catch {
            Write-Warning "Graceful server shutdown request failed: $($_.Exception.Message)"
        }
        if (-not $serverProcess.WaitForExit(5000)) {
            Stop-Process -Id $serverProcess.Id -ErrorAction Stop
            $serverProcess.WaitForExit(5000) | Out-Null
        }
    }
    if ($null -ne $serverProcess) {
        Write-Output ("SERVER_TERMINATED pid={0}; StillRunning={1}" -f $serverProcess.Id, (-not $serverProcess.HasExited))
    }
}

$report = Get-Content -Raw -LiteralPath $reportPath -Encoding UTF8 | ConvertFrom-Json
Write-Output ("QA_REPORT passed={0}; trackedProcesses={1}" -f $report.passed, @($report.processes).Count)
foreach ($tracked in $report.processes) {
    $alive = $null -ne (Get-Process -Id $tracked.pid -ErrorAction SilentlyContinue)
    Write-Output ("PROCESS pid={0}; ppid={1}; name={2}; StillRunning={3}" -f $tracked.pid, $tracked.ppid, $tracked.name, $alive)
    if ($alive -and $tracked.pid -ne $PID) {
        throw "Tracked QA child PID $($tracked.pid) is still running."
    }
}

if (-not $report.passed) { throw 'Dashboard QA report did not pass.' }
Write-Output $reportPath
