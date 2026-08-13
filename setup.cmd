@echo off
setlocal EnableExtensions
title Roblox MCP Setup

cd /d "%~dp0"
if errorlevel 1 (
    echo [ERROR] Could not open the Roblox MCP folder.
    pause
    exit /b 1
)

echo.
echo ========================================
echo          Roblox MCP Setup
echo ========================================
echo.
echo [1/2] Checking Node.js...

call :find_node
if not defined NODE_EXE goto install_node
call :node_is_supported
if not errorlevel 1 goto node_ready

echo The installed Node.js is older than version 18.

:install_node
echo Installing or updating to the current Node.js LTS release...
where winget.exe >nul 2>&1
if errorlevel 1 goto node_manual

winget upgrade --id OpenJS.NodeJS.LTS --exact --source winget --accept-package-agreements --accept-source-agreements
if errorlevel 1 winget install --id OpenJS.NodeJS.LTS --exact --source winget --accept-package-agreements --accept-source-agreements
if errorlevel 1 goto node_manual

set "PATH=%ProgramFiles%\nodejs;%LocalAppData%\Programs\nodejs;%PATH%"
call :find_node
if not defined NODE_EXE goto node_restart
call :node_is_supported
if errorlevel 1 goto node_restart

:node_ready
echo Node.js is ready:
"%NODE_EXE%" --version
if /I "%ROBLOX_MCP_SETUP_CHECK_ONLY%"=="1" exit /b 0
echo.
echo [2/2] Opening the guided Roblox MCP installer...
echo Keep this window open until the installer says it is complete.
echo.

"%NODE_EXE%" "%~dp0scripts\install-harnesses-web.mjs"
if errorlevel 1 (
    echo.
    echo [ERROR] Roblox MCP setup did not finish successfully.
    pause
    exit /b 1
)

echo.
echo Roblox MCP setup is complete.
pause
exit /b 0

:find_node
set "NODE_EXE="
for /f "delims=" %%N in ('where node.exe 2^>nul') do if not defined NODE_EXE set "NODE_EXE=%%N"
if not defined NODE_EXE if exist "%ProgramFiles%\nodejs\node.exe" set "NODE_EXE=%ProgramFiles%\nodejs\node.exe"
if not defined NODE_EXE if exist "%LocalAppData%\Programs\nodejs\node.exe" set "NODE_EXE=%LocalAppData%\Programs\nodejs\node.exe"
exit /b 0

:node_is_supported
if not defined NODE_EXE exit /b 1
"%NODE_EXE%" -e "process.exit(Number(process.versions.node.split('.')[0]) >= 18 ? 0 : 1)"
exit /b %errorlevel%

:node_restart
echo.
echo Node.js was installed, but Windows has not refreshed this terminal yet.
echo Close this window and double-click setup.cmd again.
pause
exit /b 1

:node_manual
echo.
echo [ERROR] Node.js could not be installed automatically.
echo Install Node.js 18 or newer from https://nodejs.org/ and run setup.cmd again.
pause
exit /b 1
