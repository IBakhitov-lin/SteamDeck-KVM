; SteamDeck-KVM — установщик для Windows (Inno Setup 6).
; Собирается только private_tools/scripts/build_release_script.py, который передаёт:
;   /DAppVersion=1.2.3  /DSourceDir=<папка приложения>  /DOutputDir=<dist>
;
; Установка для текущего пользователя, без прав администратора: программа — в
; %LOCALAPPDATA%\Programs\SteamDeck-KVM, ярлыки — в меню «Пуск» и на рабочем столе.
; Тот же установщик обновляет программу: приложение запускает его с /VERYSILENT.
; Ключ /NOLAUNCH не запускает приложение после установки — для проверок сборки.

#ifndef AppVersion
  #error AppVersion is required
#endif

[Setup]
AppId={{6F3B8B0E-6C1D-4E4B-9C55-2E8A6B1C7D42}
AppName=SteamDeck-KVM
AppVersion={#AppVersion}
AppVerName=SteamDeck-KVM {#AppVersion}
AppPublisher=SteamDeck-KVM
AppPublisherURL=https://github.com/IBakhitov-lin/SteamDeck-KVM
AppSupportURL=https://github.com/IBakhitov-lin/SteamDeck-KVM/issues
AppUpdatesURL=https://github.com/IBakhitov-lin/SteamDeck-KVM/releases/latest
DefaultDirName={localappdata}\Programs\SteamDeck-KVM
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=SteamDeck-KVM-{#AppVersion}-windows-x64-setup
SetupIconFile={#SourceDir}\SteamDeck-KVM.ico
UninstallDisplayIcon={app}\SteamDeck-KVM.ico
UninstallDisplayName=SteamDeck-KVM
LicenseFile={#SourceDir}\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
en.AppTitle=Shared keyboard and mouse
ru.AppTitle=Общая клавиатура и мышь
en.Launch=Start SteamDeck-KVM
ru.Launch=Запустить SteamDeck-KVM
en.DesktopIcon=Create a desktop shortcut
ru.DesktopIcon=Создать ярлык на рабочем столе
en.KeepData=Remove pairing with the Steam Deck and settings too?%n%nChoose No to keep them for a later reinstall.
ru.KeepData=Удалить заодно знакомство со Steam Deck и настройки?%n%nНет — сохранить их на случай повторной установки.

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{userprograms}\{cm:AppTitle}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\SteamDeck-KVM.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\SteamDeck-KVM.ico"
Name: "{userdesktop}\{cm:AppTitle}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\SteamDeck-KVM.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\SteamDeck-KVM.ico"; Tasks: desktopicon

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\SteamDeck-KVM.vbs"" /after-update"; Description: "{cm:Launch}"; Flags: nowait postinstall; Check: ShouldLaunch

[Code]
function ShouldLaunch: Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/NOLAUNCH') = 0 then
      Result := False;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  DataDir := ExpandConstant('{localappdata}\SteamDeck-KVM');
  if not DirExists(DataDir) then
    Exit;
  { A silent uninstall keeps user data: nobody was asked. }
  if UninstallSilent then
    Exit;
  if MsgBox(CustomMessage('KeepData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(DataDir, True, True, True);
end;
