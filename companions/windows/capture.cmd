@echo off
setlocal
pushd "%~dp0..\.."
where node >nul 2>nul
if errorlevel 1 (
  echo Install Node.js, then run this file again.
  pause
  exit /b 1
)
if not exist node_modules call npm ci
if errorlevel 1 goto failed
call npm run build
if errorlevel 1 goto failed
where cargo >nul 2>nul
if not errorlevel 1 (
  if not exist native\windows-capture\target\release\mcp-window-capture.exe call npm run build:capture
)
call npm run capture:windows
if errorlevel 1 goto failed
popd
exit /b 0
:failed
echo Capture setup or execution failed. See the message above.
popd
pause
exit /b 1
