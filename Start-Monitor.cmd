@echo off
rem Starts the monitor without changing the system execution policy.
rem Arguments are passed through, e.g. Start-Monitor.cmd -NoBrowser -Port 9000
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-OpencodeSessions.ps1" %*
if errorlevel 1 pause
