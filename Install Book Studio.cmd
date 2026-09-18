@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-BookStudio.ps1"
if errorlevel 1 (
  echo.
  echo Book Studio shortcut installation failed. Review the message above.
  pause
  exit /b 1
)
echo.
echo Book Studio shortcuts are ready on the desktop.
pause
