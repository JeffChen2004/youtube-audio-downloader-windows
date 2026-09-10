@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0YoutubeAudioDownloader.ps1"
if errorlevel 1 (
  echo.
  echo Launcher failed. Review the error above.
  pause
)
