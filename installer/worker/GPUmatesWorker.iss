#define AppVersion "0.1.1"
#define ProjectRoot "..\.."

[Setup]
AppId={{2E94DD0C-C7F2-44C8-B59D-D55799DB7A61}
AppName=GPUmates Worker
AppVersion={#AppVersion}
AppVerName=GPUmates Worker {#AppVersion}
AppPublisher=GPUmates local project
AppCopyright=GPUmates contributors and third-party licensors
VersionInfoCompany=GPUmates
VersionInfoDescription=GPUmates LAN GPU worker installer
VersionInfoProductName=GPUmates Worker
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion=0.1.1.0
DefaultDirName={autopf}\GPUmates\Worker
DefaultGroupName=GPUmates Worker
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
WizardStyle=modern
DisableWelcomePage=no
InfoBeforeFile=SAFETY.txt
OutputDir={#ProjectRoot}\dist\installer
OutputBaseFilename=GPUmates-Worker-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
SetupLogging=yes
Uninstallable=yes
UninstallDisplayName=GPUmates Worker
UninstallDisplayIcon={app}\runtime\ggml-rpc-server.exe
CloseApplications=yes
RestartApplications=no
RestartIfNeededByRun=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Dirs]
Name: "{commonappdata}\GPUmates\Worker"
Name: "{commonappdata}\GPUmates\Worker\Logs"

[Files]
Source: "{#ProjectRoot}\runtime\ggml-rpc-server.exe"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\runtime\ggml*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\runtime\cublas*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\runtime\cudart*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\runtime\libomp*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Start-Worker.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Configure-WorkerFirewall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\GPUmates.Telemetry.psm1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Start-TelemetryAgent.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Configure-MetricsFirewall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Set-WorkerConfiguration.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Start-WorkerFromConfig.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Start-TelemetryFromConfig.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Start-WorkerStack.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Clear-WorkerAgentKey.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Show-WorkerStatus.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Set-WorkerCache.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Install-Worker.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Uninstall-Worker.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Detect-WorkerIP.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\Test-WorkerInstallReady.ps1"; Flags: dontcopy
Source: "README-INSTALLED.txt"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion
Source: "SAFETY.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\GPUmates Worker\Start GPUmates Worker"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Start-WorkerStack.ps1"""; WorkingDir: "{app}"; Comment: "Start the visible GPU RPC and telemetry windows"
Name: "{autoprograms}\GPUmates Worker\GPUmates Worker Status"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File ""{app}\scripts\Show-WorkerStatus.ps1"""; WorkingDir: "{app}"
Name: "{autoprograms}\GPUmates Worker\Open GPU Dashboard"; Filename: "{code:GetDashboardUrl}"
Name: "{autoprograms}\GPUmates Worker\GPUmates Worker Cache Settings"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\scripts\Set-WorkerCache.ps1"""; WorkingDir: "{app}"; Comment: "Enable, disable, inspect, or clear the persistent worker tensor cache"
Name: "{autoprograms}\GPUmates Worker\Forget saved AgentKey"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File ""{app}\scripts\Clear-WorkerAgentKey.ps1"" -Confirm:$false"; WorkingDir: "{app}"
Name: "{autoprograms}\GPUmates Worker\Readme and safety"; Filename: "{app}\README.txt"
Name: "{autodesktop}\Start GPUmates Worker"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Start-WorkerStack.ps1"""; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Start-WorkerStack.ps1"""; Description: "Start GPUmates Worker now"; Flags: postinstall runasoriginaluser skipifsilent nowait

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Uninstall-Worker.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "GPUmatesWorkerCleanup"

[UninstallDelete]
Type: filesandordirs; Name: "{commonappdata}\GPUmates\Worker"

[Registry]
Root: HKLM; Subkey: "Software\GPUmates\Worker"; ValueType: string; ValueName: "DashboardPort"; ValueData: "{code:GetDashboardPort}"; Flags: uninsdeletevalue
Root: HKLM; Subkey: "Software\GPUmates\Worker"; ValueType: dword; ValueName: "CacheEnabled"; ValueData: "{code:GetCacheEnabledRegistryValue}"; Flags: uninsdeletevalue uninsdeletekeyifempty

[Code]
var
  NetworkPage: TInputQueryWizardPage;
  CachePage: TInputOptionWizardPage;

function IsExistingWorkerInstall: Boolean;
var
  UninstallKey: String;
begin
  UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{2E94DD0C-C7F2-44C8-B59D-D55799DB7A61}_is1';
  Result := RegKeyExists(HKLM64, UninstallKey) or
            RegKeyExists(HKLM32, UninstallKey) or
            RegKeyExists(HKCU, UninstallKey);
end;

function ReadStoredCacheEnabled: Boolean;
var
  StoredValue: Cardinal;
begin
  if RegQueryDWordValue(HKLM64, 'Software\GPUmates\Worker', 'CacheEnabled', StoredValue) then
    Result := StoredValue <> 0
  else
    Result := not IsExistingWorkerInstall;
end;

function GetCacheParameter: String;
begin
  Result := Trim(ExpandConstant('{param:CACHE|}'));
end;

function GetInitialCacheEnabled: Boolean;
var
  CacheParam: String;
begin
  CacheParam := GetCacheParameter;
  if CacheParam = '0' then
    Result := False
  else if CacheParam = '1' then
    Result := True
  else
    Result := ReadStoredCacheEnabled;
end;

function IsCacheEnabled: Boolean;
begin
  if CachePage <> nil then
    Result := CachePage.Values[0]
  else
    Result := ReadStoredCacheEnabled;
end;

function GetCacheEnabledRegistryValue(Param: String): String;
begin
  if IsCacheEnabled then
    Result := '1'
  else
    Result := '0';
end;

function InitializeSetup: Boolean;
var
  CacheParam: String;
begin
  Result := False;
  CacheParam := GetCacheParameter;
  if (CacheParam <> '') and (CacheParam <> '0') and (CacheParam <> '1') then
  begin
    MsgBox('CACHE must be 1 (enabled) or 0 (disabled).', mbError, MB_OK);
    Exit;
  end;
  Result := True;
end;

function DetectWorkerIP: String;
var
  PowerShellExe: String;
  ScriptPath: String;
  OutputPath: String;
  Params: String;
  DetectedText: AnsiString;
  ResultCode: Integer;
begin
  Result := '';
  try
    ExtractTemporaryFile('Detect-WorkerIP.ps1');
    PowerShellExe := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    ScriptPath := ExpandConstant('{tmp}\Detect-WorkerIP.ps1');
    OutputPath := ExpandConstant('{tmp}\gpumates-detected-ip.txt');
    Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '" -OutputPath "' + OutputPath + '"';
    if Exec(PowerShellExe, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and
       (ResultCode = 0) and LoadStringFromFile(OutputPath, DetectedText) then
      Result := Trim(String(DetectedText));
    DeleteFile(OutputPath);
  except
    Result := '';
  end;
end;

procedure InitializeWizard;
var
  DashboardPort: String;
begin
  NetworkPage := CreateInputQueryPage(
    wpSelectDir,
    'Private LAN configuration',
    'Choose the coordinator and this worker address',
    'Use fixed RFC1918 IPv4 addresses. Setup will verify that the worker address belongs to this PC and will permit only the coordinator through Windows Firewall.'
  );
  NetworkPage.Add('Worker name:', False);
  NetworkPage.Values[0] := GetEnv('COMPUTERNAME');
  NetworkPage.Add('Coordinator / PC1 IPv4:', False);
  NetworkPage.Values[1] := '172.25.50.14';
  NetworkPage.Add('This worker PC IPv4:', False);
  NetworkPage.Values[2] := DetectWorkerIP;
  NetworkPage.Add('Main PC dashboard port:', False);
  DashboardPort := Trim(ExpandConstant('{param:DASHBOARDPORT|}'));
  if DashboardPort = '' then
    RegQueryStringValue(HKLM64, 'Software\GPUmates\Worker', 'DashboardPort', DashboardPort);
  if DashboardPort = '' then DashboardPort := '8090';
  NetworkPage.Values[3] := DashboardPort;

  CachePage := CreateInputOptionPage(
    NetworkPage.ID,
    'Faster repeat model loads',
    'Keep remotely loaded model tensors on this Worker',
    'Recommended only on a trusted PC you own. The first load still uses the network; later loads can reuse raw tensor data that persists on this PC and uses disk space. Disabling caching does not delete existing tensor files; use Start Menu > GPUmates Worker > GPUmates Worker Cache Settings > Clear cache to remove them.',
    False,
    False
  );
  CachePage.Add('Enable persistent worker tensor cache (recommended)');
  CachePage.Values[0] := GetInitialCacheEnabled;
end;

function IsPrivateIPv4(const Value: String): Boolean;
var
  Text: String;
  Part: String;
  PartIndex: Integer;
  I: Integer;
  Number: Integer;
  A, B, C, D: Integer;
begin
  Result := False;
  Text := Trim(Value) + '.';
  Part := '';
  PartIndex := 0;
  A := -1;
  B := -1;
  C := -1;
  D := -1;

  for I := 1 to Length(Text) do
  begin
    if Text[I] = '.' then
    begin
      if (Part = '') or (PartIndex > 3) then
        Exit;
      Number := StrToIntDef(Part, -1);
      case PartIndex of
        0: A := Number;
        1: B := Number;
        2: C := Number;
        3: D := Number;
      end;
      Part := '';
      PartIndex := PartIndex + 1;
    end
    else
    begin
      if (Text[I] < '0') or (Text[I] > '9') then
        Exit;
      Part := Part + Text[I];
    end;
  end;

  if PartIndex <> 4 then
    Exit;
  if (A < 0) or (A > 255) or (B < 0) or (B > 255) or
     (C < 0) or (C > 255) or (D < 0) or (D > 255) then
    Exit;
  Result := (A = 10) or ((A = 172) and (B >= 16) and (B <= 31)) or
            ((A = 192) and (B = 168));
end;

function IsValidNodeName(const Value: String): Boolean;
var
  I: Integer;
  Allowed: String;
begin
  Result := False;
  if (Length(Trim(Value)) < 1) or (Length(Trim(Value)) > 64) then
    Exit;
  Allowed := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-';
  for I := 1 to Length(Value) do
    if Pos(Value[I], Allowed) = 0 then
      Exit;
  Result := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID <> NetworkPage.ID then
    Exit;

  if (StrToIntDef(Trim(NetworkPage.Values[3]), -1) < 1024) or
     (StrToIntDef(Trim(NetworkPage.Values[3]), -1) > 65535) then
  begin
    MsgBox('Main PC dashboard port must be a whole number from 1024 to 65535.', mbError, MB_OK);
    Result := False;
    Exit;
  end;

  if not IsValidNodeName(NetworkPage.Values[0]) then
  begin
    MsgBox('Worker name may contain only letters, numbers, spaces, dots, underscores, and hyphens.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if not IsPrivateIPv4(NetworkPage.Values[1]) then
  begin
    MsgBox('Coordinator IP must be a private IPv4 address such as 172.25.50.14.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if not IsPrivateIPv4(NetworkPage.Values[2]) then
  begin
    MsgBox('Worker IP must be a private IPv4 address assigned to this PC.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if CompareText(Trim(NetworkPage.Values[1]), Trim(NetworkPage.Values[2])) = 0 then
  begin
    MsgBox('Coordinator and worker IPs must be different.', mbError, MB_OK);
    Result := False;
  end;
end;

function GetCoordinatorIP(Param: String): String;
begin
  Result := Trim(NetworkPage.Values[1]);
end;

function GetWorkerIP(Param: String): String;
begin
  Result := Trim(NetworkPage.Values[2]);
end;

function GetNodeName(Param: String): String;
begin
  Result := Trim(NetworkPage.Values[0]);
end;

function GetDashboardPort(Param: String): String;
begin
  Result := IntToStr(StrToIntDef(Trim(NetworkPage.Values[3]), -1));
end;

function GetDashboardUrl(Param: String): String;
begin
  Result := 'http://' + GetCoordinatorIP('') + ':' + GetDashboardPort('');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  PowerShellExe: String;
  ScriptPath: String;
  ErrorPath: String;
  Params: String;
  ErrorText: AnsiString;
  ResultCode: Integer;
begin
  Result := '';
  if (StrToIntDef(GetDashboardPort(''), -1) < 1024) or
     (StrToIntDef(GetDashboardPort(''), -1) > 65535) then
  begin
    Result := 'Main PC dashboard port must be a whole number from 1024 to 65535.';
    Exit;
  end;
  if WizardSilent and (GetCacheParameter = '') then
  begin
    Result := 'Silent Worker setup requires /CACHE=1 or /CACHE=0.';
    Exit;
  end;
  ExtractTemporaryFile('Test-WorkerInstallReady.ps1');
  PowerShellExe := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant('{tmp}\Test-WorkerInstallReady.ps1');
  ErrorPath := ExpandConstant('{tmp}\gpumates-preflight-error.txt');
  DeleteFile(ErrorPath);
  Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath +
    '" -WorkerIP "' + GetWorkerIP('') + '" -ErrorPath "' + ErrorPath + '"';

  if (not Exec(PowerShellExe, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode)) or
     (ResultCode <> 0) then
  begin
    if LoadStringFromFile(ErrorPath, ErrorText) then
      Result := 'GPUmates pre-install check failed: ' + Trim(String(ErrorText))
    else
      Result := 'GPUmates pre-install check failed. Close old worker windows and verify the NVIDIA driver, worker IP, free ports, and Microsoft Visual C++ v14 x64 runtime.';
  end;
  DeleteFile(ErrorPath);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  PowerShellExe: String;
  InstallScript: String;
  Params: String;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then
    Exit;

  PowerShellExe := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  InstallScript := ExpandConstant('{app}\scripts\Install-Worker.ps1');
  Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + InstallScript +
    '" -CoordinatorIP "' + GetCoordinatorIP('') +
    '" -WorkerIP "' + GetWorkerIP('') +
    '" -NodeName "' + GetNodeName('') + '"';
  if IsCacheEnabled then
    Params := Params + ' -EnableCache';

  Log('Configuring GPUmates Worker with restricted firewall rules.');
  if (not Exec(PowerShellExe, Params, ExpandConstant('{app}'), SW_HIDE,
      ewWaitUntilTerminated, ResultCode)) or (ResultCode <> 0) then
  begin
    RaiseException(
      'GPUmates Worker configuration failed. Check ' +
      ExpandConstant('{commonappdata}\GPUmates\Worker\Logs\install.log') +
      ' and verify the selected worker IP and NVIDIA driver.'
    );
  end;
end;
