@echo off
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dist\windows\rebuild.ps1" %*
exit /b %errorlevel%
