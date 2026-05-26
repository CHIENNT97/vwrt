@echo off
title VWRT Dashboard 1-Click Installer
echo ===================================================
echo   VWRT Dashboard 1-Click Installer for QModem
echo ===================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
echo ===================================================
pause
