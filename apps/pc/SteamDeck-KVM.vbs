' Launcher for SteamDeck-KVM: starts the app window with no console window.
' Kept in plain ASCII on purpose: the classic VBScript engine misparses a
' UTF-8 BOM as a syntax error at line 1 (confirmed 2026-09-08 via cscript),
' and without a BOM the file would be read as the system codepage instead -
' either way Cyrillic here is a liability, not a convenience.
'
' Argument /after-update is passed by the app itself after it replaced its own
' files: the new instance then waits for the old one to release the
' single-instance lock instead of showing the old window and quitting.

Option Explicit

Dim shell, fso, powershellExe, scriptPath, extra

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

powershellExe = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
scriptPath = fso.GetParentFolderName(WScript.ScriptFullName) & "\SteamDeck-KVM.ps1"

If Not fso.FileExists(powershellExe) Then
    MsgBox "PowerShell not found:" & vbCrLf & powershellExe, 48, "SteamDeck-KVM"
    WScript.Quit 1
End If
If Not fso.FileExists(scriptPath) Then
    MsgBox "Application file not found:" & vbCrLf & scriptPath, 48, "SteamDeck-KVM"
    WScript.Quit 1
End If

extra = ""
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "/after-update" Then extra = " -AfterUpdate"
End If

shell.Run """" & powershellExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """" & extra, 0, False
