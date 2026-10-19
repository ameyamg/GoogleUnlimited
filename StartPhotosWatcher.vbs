' =====================================================================
' Portable Silent Launcher for WatchAndUpload.ps1 (Legacy Fallback)
' Automatically discovers script path and launches hidden in background
' NOTE: In modern Windows environments with Attack Surface Reduction (ASR)
' rules enabled, invoke GoogleUnlimited.bat silent or PowerShell Start-Process
' directly to launch without triggering script-host security policies.
' =====================================================================
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Find current folder dynamically
currentFolder = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = currentFolder & "\WatchAndUpload.ps1"

If Not fso.FileExists(ps1Path) Then
    MsgBox "Could not find WatchAndUpload.ps1 in: " & vbCrLf & currentFolder, vbCritical, "Error"
    WScript.Quit 1
End If

' Set working directory to script location
WshShell.CurrentDirectory = currentFolder

' Use pwsh.exe if available with full path, otherwise fallback to powershell.exe
psExe = "powershell.exe"
pwshPath = WshShell.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7\pwsh.exe")
If fso.FileExists(pwshPath) Then
    psExe = """" & pwshPath & """"
End If

' Check if watcher is already running
checkCmd = psExe & " -NoProfile -ExecutionPolicy Bypass -File """ & ps1Path & """ -CheckRunning"
retCode = WshShell.Run(checkCmd, 0, True)
If retCode = 0 Then
    ' Watcher is already running; exit safely without duplicate process
    WScript.Quit 0
End If

command = psExe & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """"
WshShell.Run command, 0, False

