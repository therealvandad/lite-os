@echo off
rem ===========================================================================
rem  Lite OS launcher
rem  Double-click to open the Lite OS menu. Asks for administrator rights (UAC)
rem  by itself, then runs LiteOS.ps1 with Windows PowerShell 5.1.
rem  Any arguments are passed through, for example:
rem    Start-LiteOS.cmd -Level Balanced -Silent
rem    Start-LiteOS.cmd -DryRun
rem ===========================================================================
setlocal EnableExtensions DisableDelayedExpansion
title Lite OS

rem --- Work from the folder this file is in (also when started elevated). ---
cd /d "%~dp0"

set "LITEOS_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "LITEOS_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%LITEOS_PS%" (
    echo [Lite OS] Windows PowerShell 5.1 was not found:
    echo           %LITEOS_PS%
    pause
    exit /b 1
)

if not exist "%~dp0LiteOS.ps1" (
    echo [Lite OS] LiteOS.ps1 was not found next to this launcher.
    echo           Extract the whole Lite OS zip first, then run Start-LiteOS.cmd again.
    pause
    exit /b 1
)

rem --- Arguments. The elevated copy gets a marker as first argument. ---
set "LITEOS_ARGS=%*"
set "LITEOS_ELEVATED="
if /i not "%~1"=="--liteos-elevated" goto :check_admin
set "LITEOS_ELEVATED=1"
set "LITEOS_ARGS=%LITEOS_ARGS:*--liteos-elevated=%"

:check_admin
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if not errorlevel 1 goto :run

if defined LITEOS_ELEVATED (
    echo [Lite OS] Could not get administrator rights.
    echo           Right-click Start-LiteOS.cmd and choose "Run as administrator".
    pause
    exit /b 1
)

echo [Lite OS] Asking for administrator rights...
set "LITEOS_SELF=%~f0"
rem Elevate cmd.exe itself with /s /c ""<this file>" <args>": starting the .cmd directly goes
rem through "cmd.exe /C "%1" %*", which breaks on folders with & or spaces plus quoted arguments.
rem [char]34 is a double quote (keeps this line free of nested quotes).
"%LITEOS_PS%" -NoProfile -ExecutionPolicy Bypass -Command "$q = [string][char]34; $a = '--liteos-elevated ' + [string]$env:LITEOS_ARGS; $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'; $line = '/s /c ' + $q + $q + $env:LITEOS_SELF + $q + ' ' + $a + $q; try { Start-Process -FilePath $cmd -ArgumentList $line -Verb RunAs -ErrorAction Stop; exit 0 } catch { Write-Host ('[Lite OS] Elevation was cancelled or failed: ' + $_.Exception.Message); exit 1 }"
if errorlevel 1 (
    echo [Lite OS] Lite OS needs administrator rights to change Windows settings.
    pause
    exit /b 1
)
exit /b 0

:run
echo.
"%LITEOS_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0LiteOS.ps1" %LITEOS_ARGS%
set "LITEOS_RC=%errorlevel%"
echo.
if "%LITEOS_RC%"=="0" (
    echo [Lite OS] Finished.
) else (
    echo [Lite OS] Finished with exit code %LITEOS_RC%. Logs: %ProgramData%\LiteOS\logs
)
pause
endlocal & exit /b %LITEOS_RC%
