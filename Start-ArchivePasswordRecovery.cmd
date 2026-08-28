@echo off
setlocal
set "APP_ROOT=%~dp0"
set "WSCRIPT_EXE=%SystemRoot%\System32\wscript.exe"

"%WSCRIPT_EXE%" //B //NoLogo "%APP_ROOT%Start-ArchivePasswordRecovery.vbs"
exit /b %ERRORLEVEL%
