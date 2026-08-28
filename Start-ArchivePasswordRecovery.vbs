Option Explicit

Dim fso, shell, appRoot, powershellExe, appScript, command, errorNumber
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

appRoot = fso.GetParentFolderName(WScript.ScriptFullName)
powershellExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
appScript = fso.BuildPath(appRoot, "src\ArchivePasswordRecovery.ps1")

If Not fso.FileExists(powershellExe) Or Not fso.FileExists(appScript) Then
    ShowStartupFailure "Startup files are incomplete; the GUI cannot be opened."
    WScript.Quit 1
End If

command = QuoteArgument(powershellExe) & " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & QuoteArgument(appScript)
On Error Resume Next
Err.Clear
shell.Run command, 0, False
errorNumber = Err.Number
On Error GoTo 0

If errorNumber <> 0 Then
    ShowStartupFailure "The local PowerShell GUI could not be started."
    WScript.Quit 1
End If

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

Sub ShowStartupFailure(detail)
    MsgBox "Program startup failed." & vbCrLf & detail, vbCritical + vbOKOnly, "Archive Password Recovery"
End Sub
