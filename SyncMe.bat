@echo off
setlocal EnableExtensions
title SyncMe - © 2026 Bradford Lotriet
cd /d "%~dp0"

if not exist "Logs" mkdir "Logs"
if not exist "Reports" mkdir "Reports"

echo.
echo  ============================================================
echo   SyncMe
echo   Copyright (c) 2026 Bradford Lotriet
echo   brad@web-zilla.co.za
echo   Free to use — keep this credit. See LICENSE.txt
echo  ============================================================
echo.
echo   Open the SyncMe User Guide now? [Y/N]
set /p OPENGUIDE=  
if /i "%OPENGUIDE%"=="Y" (
  if exist "%~dp0UserGuide.html" (
    start "" "%~dp0UserGuide.html"
    echo   User Guide opened in your browser.
  ) else (
    echo   UserGuide.html not found in this folder.
  )
  echo.
)

echo   Starting the SyncMe console in your browser...
echo   Keep this window open while you use SyncMe.
echo   Close this window to stop SyncMe.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SyncMe-Host.ps1" -Port 17845 -OpenView auto
set EXITCODE=%ERRORLEVEL%
echo.
echo   SyncMe stopped.
pause
exit /b %EXITCODE%
