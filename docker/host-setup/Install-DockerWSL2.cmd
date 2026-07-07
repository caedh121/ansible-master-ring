@echo off
rem host-setup\Install-DockerWSL2.cmd - wrapper for Install-DockerWSL2.ps1.
rem
rem PowerShell scripts (.ps1) are blocked by default on Windows client
rem editions (ExecutionPolicy=Restricted). A .cmd wrapper bypasses the
rem policy for this process only, so the first run works from a fresh,
rem elevated shell without any Set-ExecutionPolicy dance.
rem
rem Must still be run as Administrator (the .ps1 has #Requires
rem -RunAsAdministrator). All args are passed through.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DockerWSL2.ps1" %*
