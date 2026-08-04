@echo off
setlocal EnableExtensions
title SyncMe Monitor
set "HERE=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%SyncMe-Monitor-Host.ps1" %*
