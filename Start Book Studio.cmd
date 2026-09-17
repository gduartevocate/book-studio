@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-BookStudioCompanion.ps1"
if errorlevel 1 (
  echo.
  echo Book Studio did not start. Review the message above.
  pause
)
