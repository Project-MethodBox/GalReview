@echo off
setlocal

for %%I in ("%~dp0.") do set "PROJECT_ROOT=%%~fI"
set "STOP_SCRIPT=%PROJECT_ROOT%\scripts\stop-project.ps1"

if not exist "%STOP_SCRIPT%" (
    echo [ERROR] Stop script was not found: "%STOP_SCRIPT%"
    exit /b 1
)

rem Leave the project directory before stopping anything. A cmd process whose
rem current directory is inside the project can prevent the folder from moving
rem or being deleted.
cd /d "%TEMP%"

set "STOP_ARGUMENTS="
if /I "%~1"=="--dry-run" set "STOP_ARGUMENTS=-WhatIf"
if /I "%~1"=="--include-editors" set "STOP_ARGUMENTS=-IncludeEditors"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%STOP_SCRIPT%" -ProjectRoot "%PROJECT_ROOT%" %STOP_ARGUMENTS%
set "STOP_EXIT_CODE=%ERRORLEVEL%"

if not "%STOP_EXIT_CODE%"=="0" (
    echo.
    echo The project was not fully released. Review the messages above.
)

endlocal & exit /b %STOP_EXIT_CODE%
