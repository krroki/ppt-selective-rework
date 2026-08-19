@echo off
setlocal
chcp 65001 >nul
title PPT 검수 화면
set "JOB_ROOT=%~dp0"
for %%I in ("%~dp0..\..") do set "PIPELINE_ROOT=%%~fI"
if not exist "%PIPELINE_ROOT%\scripts\open-review.ps1" (
  echo 같은 Local Project의 scripts\open-review.ps1을 찾지 못했습니다.
  echo jobs 폴더를 저장소와 분리하지 말고 저장소 전체를 함께 옮겨 주세요.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PIPELINE_ROOT%\scripts\open-review.ps1" -JobRoot "%JOB_ROOT%"
if errorlevel 1 pause
endlocal
