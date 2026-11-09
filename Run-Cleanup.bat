@echo off
chcp 65001 >nul 2>&1
title Conversation Purge
setlocal

rem 依次尝试：py 启动器 -> python -> 托管 Python 最新版本目录
set "PY="
where py >nul 2>&1 && set "PY=py"
if not defined PY (
    where python >nul 2>&1 && set "PY=python"
)
if not defined PY call :findpy
if not defined PY (
    echo.
    echo [Error] Python not found. Install Python 3.9+ and retry.
    echo.
    pause
    exit /b 1
)

set PYTHONIOENCODING=utf-8
"%PY%" "%~dp0scripts\cleanup.py"

if errorlevel 1 (
    echo.
    echo [Run failed] Script exited with an error.
)

echo.
pause
exit /b 0

:findpy
set "BASE=%USERPROFILE%\.workbuddy\binaries\python\versions"
if not exist "%BASE%" exit /b 0
for /f "delims=" %%i in ('dir /b /ad /o-n "%BASE%"') do (
    if not defined PY if exist "%BASE%\%%i\python.exe" set "PY=%BASE%\%%i\python.exe"
)
exit /b 0
