' Launcher for SteamDeck-KVM: starts the tray icon with no console window.
' Kept in plain ASCII on purpose: the classic VBScript engine misparses a
' UTF-8 BOM as a syntax error at line 1 (confirmed 2026-09-08 via cscript),
' and without a BOM the file would be read as the system codepage instead —
' either way Cyrillic here is a liability, not a convenience.

Option Explicit

Dim shell, fso, powershellExe, scriptPath

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

shell.Run """" & powershellExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, False
