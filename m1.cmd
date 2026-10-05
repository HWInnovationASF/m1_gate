@echo off
REM m1 for Windows — เรียก install.ps1 (ต้อง Run as administrator สำหรับ install/update)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
