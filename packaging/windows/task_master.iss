; Compile through scripts/package-windows.ps1 with Inno Setup 6.3 or newer.
#ifndef PayloadDirectory
  #error PayloadDirectory is required
#endif
#ifndef PackageVersion
  #error PackageVersion is required
#endif

[Setup]
AppId=dev.task_master.desktop
AppName=task_master
AppVersion={#PackageVersion}
AppPublisher=task_master
DefaultDirName={commonpf}\task_master
DisableDirPage=yes
DisableProgramGroupPage=yes
UsePreviousAppDir=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputBaseFilename=task_master-{#PackageVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\task_master.exe
CloseApplications=yes
RestartApplications=no
Uninstallable=yes
SetupLogging=yes

[Files]
; The existing sensor installer stages and protects its service directory,
; verifies the official PawnIO driver, and starts the service. Keep these
; payloads temporary so upgrades do not overwrite a running sensor service.
Source: "{#PayloadDirectory}\install-sensors.ps1"; DestDir: "{tmp}\task_master"; Flags: dontcopy
Source: "{#PayloadDirectory}\sensors\*"; DestDir: "{tmp}\task_master\sensors"; Flags: dontcopy recursesubdirs createallsubdirs
Source: "{#PayloadDirectory}\task_master.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDirectory}\task_master-collector.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDirectory}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDirectory}\install-windows.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDirectory}\install-sensors.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDirectory}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{commonprograms}\task_master"; Filename: "{app}\task_master.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\task_master.exe"; Description: "Launch task_master"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
function PowerShellQuote(Value: String): String;
begin
  StringChangeEx(Value, '''', '''''', True);
  Result := '''' + Value + '''';
end;

function RunSensors(ScriptPath, Arguments, LogName: String): Boolean;
var
  ResultCode: Integer;
  LogPath, Command, Output: String;
  LogText: AnsiString;
begin
  LogPath := ExpandConstant('{tmp}\') + LogName;
  Command := '$ErrorActionPreference = ''Stop''; $PSDefaultParameterValues = @{''Out-File:Encoding''=''utf8''}; try { & ' +
    PowerShellQuote(ScriptPath) + ' ' + Arguments +
    ' *> ' + PowerShellQuote(LogPath) + '; exit 0 } catch { $_ | Out-File -Append ' +
    PowerShellQuote(LogPath) + '; exit 1 }';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + Command + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := Result and (ResultCode = 0);
  if LoadStringFromFile(LogPath, LogText) then begin
    Output := Utf8Decode(LogText);
    Log(Output);
    if not Result then
      SuppressibleMsgBox('task_master sensor installation/removal failed:' + #13#10 + Output,
        mbError, MB_OK, IDOK);
  end else if not Result then
    SuppressibleMsgBox('Could not run the task_master sensor installer. Error code: ' +
      IntToStr(ResultCode), mbError, MB_OK, IDOK);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  ExtractTemporaryFiles('{tmp}\task_master\*');
  if not RunSensors(ExpandConstant('{tmp}\task_master\install-sensors.ps1'),
      '-SourceDirectory ' + PowerShellQuote(ExpandConstant('{tmp}\task_master\sensors')),
      'task_master-sensors-install.log') then
    Result := 'task_master requires its sensor service. Resolve the reported error and retry setup.';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    // Stop/delete the service before Inno removes its installer and the desktop.
    // The shared PawnIO driver and each user's preferences/history are retained.
    if not RunSensors(ExpandConstant('{app}\install-sensors.ps1'), '-Remove',
        'task_master-sensors-remove.log') then
      Abort;
  end;
end;
