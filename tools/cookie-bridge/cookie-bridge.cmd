@echo off
setlocal
set "BRIDGE_EXE=%~dp0dist\cookie-bridge.exe"
if not exist "%BRIDGE_EXE%" (
  echo Cookie Bridge has not been built. Run build.ps1 first. 1>&2
  exit /b 10
)
"%BRIDGE_EXE%" %*
exit /b %ERRORLEVEL%
