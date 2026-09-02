@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Open Bongo Wardrobe.ps1"
if errorlevel 1 pause
