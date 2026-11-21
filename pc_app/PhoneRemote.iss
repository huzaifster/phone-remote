; Inno Setup script for Phone Remote (PC app).
; Build it with build_installer.bat. It packs dist\PhoneRemote.exe into ONE setup file:
;   installer_output\PhoneRemote-Setup.exe
; Change MyAppVersion when you release an update (installing over an old version upgrades it).

#define MyAppName "Phone Remote"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Phone Remote"
#define MyAppExe "PhoneRemote.exe"

[Setup]
AppId={{FECF3E93-64AF-46EA-9997-BAE9E2F57074}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
OutputDir=installer_output
OutputBaseFilename=PhoneRemote-Setup
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\{#MyAppExe}
UninstallDisplayName={#MyAppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Tasks]
Name: "startup"; Description: "Start Phone Remote when Windows starts (recommended, so your phone can always reach this PC)"
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "dist\{#MyAppExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; Tasks: desktopicon

[Registry]
; Same entry the tray menu's "Start with Windows" switch uses
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "PhoneRemote"; ValueData: """{app}\{#MyAppExe}"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
; Let the phone reach this PC through Windows Firewall (home/work networks only, not public Wi-Fi)
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Phone Remote"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Phone Remote"" dir=in action=allow program=""{app}\{#MyAppExe}"" enable=yes profile=private,domain"; Flags: runhidden
Filename: "{app}\{#MyAppExe}"; Description: "Launch Phone Remote now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Phone Remote"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[Code]
procedure CloseRunningApp();
var
  ResultCode: Integer;
begin
  { The app lives in the tray with no window, so stop it directly }
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im PhoneRemote.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    CloseRunningApp();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    CloseRunningApp();
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'PhoneRemote');
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{%USERPROFILE}\.phone_remote');
    if DirExists(DataDir) and (not UninstallSilent()) then
      if MsgBox('Also delete the paired phones and security keys stored on this PC?' + #13#10 + #13#10 +
                'Choose No to keep them (recommended if you may reinstall later).',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir, True, True, True);
  end;
end;
