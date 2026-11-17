' Launch the FeiYin sync server without a console window.
' Used by the FeiYinSync scheduled task.
Option Explicit
Dim sh, fso, here, logDir
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

logDir = here & "\logs"
If Not fso.FolderExists(logDir) Then fso.CreateFolder(logDir)

sh.Run "cmd /c """ & here & "\start-server.cmd"" >> """ & logDir & "\server.log"" 2>&1", 0, False
