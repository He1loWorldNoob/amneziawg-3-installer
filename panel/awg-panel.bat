@echo off
rem AmneziaWG control panel - double-click to run.
rem
rem ASCII only, on purpose: cmd.exe parses .bat files in the OEM codepage,
rem so any non-ASCII byte here breaks the parser. All Russian text lives
rem in awg-panel.ps1, which PowerShell reads as UTF-8.

chcp 65001 >nul
title AmneziaWG - panel

set "SCRIPT=%~dp0awg-panel.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo [ERROR] awg-panel.ps1 not found next to this file.
    echo Keep both files in the same folder.
    echo.
    pause
    exit /b 1
)

rem Prefer PowerShell 7, fall back to the built-in one.
where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)

set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
