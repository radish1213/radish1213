@echo off
REM Double-click to run the cleanup script as administrator.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File \"%~dp0PC-Cleanup.ps1\"')"
