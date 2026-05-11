@echo off
REM =============================================================================
REM  Interior Design Accelerator - one-click deploy launcher
REM
REM  Why this exists:
REM   * Visual Studio's "Developer PowerShell" dies when VS reloads or restarts.
REM   * This .cmd opens an INDEPENDENT pwsh window (`start pwsh -NoExit ...`)
REM     that survives VS restarts and pauses at the end so you can read errors.
REM
REM  Usage:
REM   * Double-click this file in Explorer, OR
REM   * Run from any shell:  Deploy.cmd
REM
REM  The new window will:
REM   1. cd into the repo
REM   2. Run deploy.ps1 with safe non-interactive defaults
REM   3. Stay open at the end so you can read the summary or errors
REM =============================================================================

setlocal
set "REPO=%~dp0"
if "%REPO:~-1%"=="\" set "REPO=%REPO:~0,-1%"

echo Launching deploy.ps1 in a NEW independent window...
echo Repo:  %REPO%
echo.

start "Interior Design Accelerator Deploy" pwsh.exe -NoExit -NoLogo -ExecutionPolicy Bypass -Command ^
  "Set-Location '%REPO%'; ^
   try { ^
     & '%REPO%\infra\scripts\deploy.ps1' -Yes -SkipCleanupPrompt -SkipUpgrades ^
   } catch { ^
     Write-Host ''; ^
     Write-Host '====================================================================' -ForegroundColor Red; ^
     Write-Host ('  SCRIPT THREW: ' + $_.Exception.Message) -ForegroundColor Red; ^
     Write-Host '====================================================================' -ForegroundColor Red; ^
   } ^
   Write-Host ''; ^
   Write-Host '--- deploy.ps1 finished. Window stays open. Press Ctrl-D or type exit to close. ---' -ForegroundColor Yellow"

echo.
echo A new window has been launched. You can close THIS window now.
echo The deployment continues independently in the new window.
endlocal
