@echo off
setlocal
set "APP_ROOT=%~dp0"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "APP_SCRIPT=%APP_ROOT%src\ArchivePasswordRecovery.ps1"
set "APP_ICON=%APP_ROOT%assets\ArchivePasswordRecovery_Primary.ico"
set "APP_LINK=%TEMP%\ArchivePasswordRecovery.lnk"

if exist "%APP_LINK%" del /f /q "%APP_LINK%" >nul 2>&1
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$shell = New-Object -ComObject WScript.Shell; $link = $shell.CreateShortcut($env:APP_LINK); $link.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File ' + [char]34 + $env:APP_SCRIPT + [char]34; $link.WorkingDirectory = $env:APP_ROOT; $link.IconLocation = $env:APP_ICON + ',0'; $link.Save()"
if not exist "%APP_LINK%" (
    "%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%APP_SCRIPT%"
    exit /b
)
start "" "%APP_LINK%"
