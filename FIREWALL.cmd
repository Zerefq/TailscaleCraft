@echo off
cd /d "%~dp0"
echo Run this file as administrator to allow Minecraft ports on Tailscale.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\manage.ps1" -Action Firewall
pause
