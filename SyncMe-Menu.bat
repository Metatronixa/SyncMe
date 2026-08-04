@echo off
setlocal EnableExtensions
title SyncMe - (c) 2026 Bradford Lotriet
cd /d "%~dp0"

if not exist "Logs" mkdir "Logs"

echo.
echo  ============================================================
echo   SyncMe - Management console
echo   Copyright (c) 2026 Bradford Lotriet
echo   brad@web-zilla.co.za
echo  ============================================================
echo.
echo   Opening SyncMe management console...
echo   Keep this window open. Close it to stop SyncMe.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SyncMe-Host.ps1" -Port 17845 -OpenView console
pause
exit /b %ERRORLEVEL%
