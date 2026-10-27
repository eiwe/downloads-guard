@echo off
rem Set VS Code's claudeCode.claudeProcessWrapper to this file. The extension passes the
rem bundled claude binary as the first argument; it runs only outside protected folders.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0downloads-guard.ps1" wrap-exec %*
exit /b %ERRORLEVEL%
