@echo off
setlocal

for %%I in ("%~dp0..") do set "PROJECT_ROOT=%%~fI"
set "DOWNLOAD_SCRIPT=%~dp0download-model-resources.ps1"

if not exist "%DOWNLOAD_SCRIPT%" (
    echo [ERROR] Download script was not found:
    echo         %DOWNLOAD_SCRIPT%
    set "DOWNLOAD_EXIT_CODE=1"
    goto :finish
)

cd /d "%PROJECT_ROOT%"
echo [download] Restoring ModelService resources...
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%DOWNLOAD_SCRIPT%" %*
set "DOWNLOAD_EXIT_CODE=%ERRORLEVEL%"

echo.
if "%DOWNLOAD_EXIT_CODE%"=="0" (
    echo [OK] ModelService resources are ready.
) else (
    echo [ERROR] Resource download failed with exit code %DOWNLOAD_EXIT_CODE%.
    echo         Read the PowerShell error above for the required action.
)

:finish
if not defined GALREVIEW_NO_PAUSE (
    echo.
    pause
)

endlocal & exit /b %DOWNLOAD_EXIT_CODE%
