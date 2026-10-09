@echo off
rem ===========================================================================
rem  Lite OS Builder launcher
rem  Double-click to open the Lite OS Builder: it downloads the official
rem  Windows 11 ISO from Microsoft (or uses yours) and builds a bootable
rem  Lite OS ISO on this PC. It asks for administrator rights (UAC) by itself,
rem  because building mounts and services a Windows image. The PowerShell
rem  window with the log stays minimized on the taskbar - keep it open.
rem
rem  Uses your official Windows from Microsoft; activate with your own license.
rem  Lite OS never ships Windows files, product keys or activators.
rem
rem  Optional arguments are passed to LiteOS-Builder.ps1, for example:
rem    LiteOS-Builder.cmd -IsoPath "D:\ISO\Win11_25H2_English_x64.iso"
rem    LiteOS-Builder.cmd -Mode Core -OutputFolder "D:\Builds"
rem ===========================================================================
setlocal EnableExtensions DisableDelayedExpansion
title Lite OS Builder

rem --- Work from the folder this file is in. ---
cd /d "%~dp0"

set "LITEOS_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "LITEOS_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%LITEOS_PS%" goto :no_powershell

set "LITEOS_GUI=%~dp0LiteOS-Builder.ps1"
if not exist "%LITEOS_GUI%" goto :incomplete
if not exist "%~dp0builder\Build-LiteOS.ps1" goto :incomplete
if not exist "%~dp0builder\Get-WindowsIso.ps1" goto :incomplete

set "LITEOS_ARGS=%*"

rem --- Already elevated? fltmc only works for administrators. ---
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if not errorlevel 1 goto :run

echo [Lite OS] Asking for administrator rights...
rem Start the GUI elevated in one step: Windows PowerShell 5.1, STA (needed by WPF), minimized log
rem window. [char]34 is a double quote, so this line needs no nested quotes. The script path and
rem the arguments are read from environment variables, so special characters in the folder name
rem are never parsed again by cmd.
"%LITEOS_PS%" -NoProfile -ExecutionPolicy Bypass -Command "$q = [string][char]34; $a = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Minimized -File ' + $q + $env:LITEOS_GUI + $q + ' ' + [string]$env:LITEOS_ARGS; try { Start-Process -FilePath $env:LITEOS_PS -ArgumentList $a -Verb RunAs -ErrorAction Stop; exit 0 } catch { Write-Host ('[Lite OS] Elevation was cancelled or failed: ' + $_.Exception.Message); exit 1 }"
if errorlevel 1 goto :no_admin
exit /b 0

:run
rem Elevated already: start the GUI with a minimized log window and close this one.
start "Lite OS Builder" /min "%LITEOS_PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%LITEOS_GUI%" %LITEOS_ARGS%
if errorlevel 1 goto :start_failed
exit /b 0

:no_powershell
echo [Lite OS] Windows PowerShell 5.1 was not found:
echo           %LITEOS_PS%
pause
exit /b 1

:incomplete
echo [Lite OS] Some Lite OS files are missing next to this launcher
echo           - LiteOS-Builder.ps1, builder\Build-LiteOS.ps1, builder\Get-WindowsIso.ps1 -
echo           Extract the whole Lite OS zip first, then run LiteOS-Builder.cmd again.
pause
exit /b 1

:no_admin
echo [Lite OS] The Lite OS Builder needs administrator rights to mount and service
echo           the Windows image. Run LiteOS-Builder.cmd again and choose "Yes".
pause
exit /b 1

:start_failed
echo [Lite OS] Could not start Windows PowerShell for the Lite OS Builder.
pause
exit /b 1
