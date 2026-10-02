; Установщик ZapretLauncher (Inno Setup 6).
; Собирается скриптом tool/build_installer.ps1: он передаёт версию и папку сборки.
;
; Тихое обновление из лаунчера:
;   ZapretLauncher-Setup-X.Y.Z.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /UPDATE=1 [/MINIMIZED=1]
; Установщик дождётся, пока лаунчер закроется, поставит новую версию и запустит её.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
; Компилятор 32-битный: для него System32 — это SysWOW64 с 32-битными DLL. Настоящая папка — Sysnative.
#if DirExists(GetEnv("SystemRoot") + "\Sysnative")
  #define SysDir GetEnv("SystemRoot") + "\Sysnative"
#else
  #define SysDir GetEnv("SystemRoot") + "\System32"
#endif
#define AppExe "ZapretLauncher.exe"
#define AppMutex "Local\ZapretLauncher.SingleInstance"

[Setup]
AppId={{51A32EC2-1820-4A11-9CF2-EF452633E21C}
AppName=ZapretLauncher
AppVersion={#AppVersion}
AppVerName=ZapretLauncher {#AppVersion}
AppPublisher=NotCode
AppPublisherURL=https://github.com/notcodeone/zapret-launcher
AppSupportURL=https://github.com/notcodeone/zapret-launcher/issues
AppUpdatesURL=https://github.com/notcodeone/zapret-launcher/releases
DefaultDirName={autopf}\ZapretLauncher
DefaultGroupName=ZapretLauncher
DisableProgramGroupPage=yes
DisableWelcomePage=no
; Лаунчеру нужны права администратора: WinDivert и службы Windows.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\dist
OutputBaseFilename=ZapretLauncher-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName=ZapretLauncher
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Закрытие лаунчера ждём сами (см. InitializeSetup): он прячется в трей, а не закрывается.
CloseApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoCompany=NotCode
VersionInfoDescription=ZapretLauncher Setup

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Значок на рабочем столе"; GroupDescription: "Значки:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Среда выполнения Visual C++ рядом с программой — без неё Flutter-приложение не запустится
; на чистой Windows. Берём с машины сборки; распространять эти файлы разрешено.
Source: "{#SysDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SysDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SysDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\ZapretLauncher"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\ZapretLauncher"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; Обычная установка — предложить запустить.
Filename: "{app}\{#AppExe}"; Description: "Запустить ZapretLauncher"; Flags: nowait postinstall skipifsilent
; Обновление из лаунчера — запустить новую версию сразу.
Filename: "{app}\{#AppExe}"; Parameters: "{code:RelaunchArgs}"; Flags: nowait; Check: IsUpdate

[UninstallRun]
; Задача автозапуска указывала бы на удалённый файл.
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ZapretLauncher /F"; Flags: runhidden; RunOnceId: "DeleteAutostartTask"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
function IsUpdate: Boolean;
begin
  Result := ExpandConstant('{param:UPDATE|0}') = '1';
end;

function RelaunchArgs(Param: String): String;
begin
  if ExpandConstant('{param:MINIMIZED|0}') = '1' then
    Result := '--minimized'
  else
    Result := '';
end;

{ Ждёт, пока лаунчер закроется; True — закрылся. }
function WaitForLauncher(Seconds: Integer): Boolean;
var
  I: Integer;
begin
  I := 0;
  while CheckForMutexes('{#AppMutex}') and (I < Seconds * 5) do
  begin
    Sleep(200);
    I := I + 1;
  end;
  Result := not CheckForMutexes('{#AppMutex}');
end;

function InitializeSetup: Boolean;
begin
  Result := True;
  { При обновлении лаунчер закрывается сам сразу после запуска установщика. }
  if WaitForLauncher(20) then Exit;
  if WizardSilent then
  begin
    Result := False;
    Exit;
  end;
  while CheckForMutexes('{#AppMutex}') do
  begin
    if MsgBox('ZapretLauncher запущен. Закройте его: правой кнопкой по значку в трее → «Выход».' + #13#10 + #13#10 +
              'Zapret при этом продолжит работать.', mbInformation, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

procedure RunHidden(const FileName, Params: String);
var
  Code: Integer;
begin
  Exec(FileName, Params, '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep <> usUninstall then Exit;
  { Лаунчер мог остаться в трее. }
  RunHidden(ExpandConstant('{sys}\taskkill.exe'), '/IM {#AppExe} /F');
  if UninstallSilent then Exit;
  if MsgBox('Удалить заодно и zapret?' + #13#10 + #13#10 +
            'Служба zapret остановится и удалится, zapret, скачанный лаунчером, и настройки лаунчера ' +
            'будут удалены. Если zapret нужен без лаунчера — нажмите «Нет».',
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) <> IDYES then Exit;
  RunHidden(ExpandConstant('{sys}\sc.exe'), 'stop zapret');
  RunHidden(ExpandConstant('{sys}\sc.exe'), 'delete zapret');
  RunHidden(ExpandConstant('{sys}\taskkill.exe'), '/IM winws.exe /F');
  RunHidden(ExpandConstant('{sys}\sc.exe'), 'stop WinDivert');
  RunHidden(ExpandConstant('{sys}\sc.exe'), 'delete WinDivert');
  DelTree(ExpandConstant('{commonappdata}\ZapretLauncher'), True, True, True);
  DelTree(ExpandConstant('{userappdata}\ZapretLauncher'), True, True, True);
end;
