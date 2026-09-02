@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-package.ps1"
exit /b %errorlevel%
