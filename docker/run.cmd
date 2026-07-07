@echo off
rem docker\run.cmd - wrapper that invokes run.ps1 with -ExecutionPolicy Bypass
rem for the current process only, so users don't need to configure the
rem system's PowerShell execution policy before the first run.
rem
rem %~dp0 = drive + path of THIS .cmd (with trailing backslash), so run.ps1
rem always resolves next to us regardless of the caller's cwd.
rem %*    = pass all args through to the .ps1 (e.g. --rebuild).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
