#define AppVersion "0.3.1"
#define ProjectRoot "..\.."

[Setup]
AppId={{7C45B8B6-583E-4E0B-8E3E-E6686F72614F}
AppName=GPUmates
AppVersion={#AppVersion}
AppVerName=GPUmates {#AppVersion}
AppPublisher=GPUmates local project
AppCopyright=GPUmates contributors and third-party licensors
VersionInfoCompany=GPUmates
VersionInfoDescription=GPUmates unified Coordinator and GPU Worker setup
VersionInfoProductName=GPUmates Setup
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion=0.3.1.0
DefaultDirName={code:GetDefaultDirName}
UsePreviousAppDir=no
DefaultGroupName=GPUmates
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
WizardStyle=modern
DisableWelcomePage=no
InfoBeforeFile=SAFETY.txt
OutputDir={#ProjectRoot}\dist\installer
OutputBaseFilename=GPUmates-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
SetupLogging=yes
Uninstallable=yes
UninstallDisplayName=GPUmates
CloseApplications=yes
RestartApplications=no
RestartIfNeededByRun=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce

[Dirs]
Name: "{commonappdata}\GPUmates\Worker"; Check: IsWorker
Name: "{commonappdata}\GPUmates\Worker\Logs"; Check: IsWorker

[Files]
; Shared CUDA/ggml runtime is stored once in the unified payload.
Source: "{#ProjectRoot}\runtime\ggml*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\runtime\cublas*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\runtime\cudart*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\runtime\libomp*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\GPUmates.Telemetry.psm1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Uninstall-GPUmatesRole.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\installer\worker\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "SAFETY.txt"; DestDir: "{app}"; Flags: ignoreversion

; Coordinator role.
Source: "{#ProjectRoot}\dist\coordinator\GPUmates-Coordinator.exe"; DestDir: "{app}"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\runtime\llama-server.exe"; DestDir: "{app}\runtime"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\runtime\llama*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\runtime\mtmd.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Start-GPUmatesControlCenter.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Start-ModelRouter.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Start-ModelRouterFromControl.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Prepare-GPUmatesChatUi.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Start-GPUmatesDashboard.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Configure-CoordinatorFirewall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Configure-DashboardFirewall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Register-WorkerOnCoordinator.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Apply-CoordinatorSharing.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Uninstall-Coordinator.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Install-Coordinator.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsCoordinator
Source: "{#ProjectRoot}\scripts\Test-CoordinatorInstallReady.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\config\telemetry-nodes.json"; DestDir: "{app}\config"; Flags: ignoreversion onlyifdoesntexist; Check: IsCoordinator
Source: "{#ProjectRoot}\config\gpumates-models.ini"; DestDir: "{app}\config"; Flags: ignoreversion onlyifdoesntexist; Check: IsCoordinator
Source: "{#ProjectRoot}\dashboard\static\*"; DestDir: "{app}\dashboard\static"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsCoordinator
Source: "{#ProjectRoot}\coordinator\static\*"; DestDir: "{app}\coordinator\static"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsCoordinator
Source: "{#ProjectRoot}\chat\static\*"; DestDir: "{app}\chat\static"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsCoordinator
Source: "{#ProjectRoot}\installer\coordinator\README-INSTALLED.txt"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion; Check: IsCoordinator
Source: "ROLE-COORDINATOR.txt"; DestDir: "{app}"; DestName: "install-role.txt"; Flags: ignoreversion; Check: IsCoordinator

; Worker role.
Source: "{#ProjectRoot}\runtime\ggml-rpc-server.exe"; DestDir: "{app}\runtime"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Start-Worker.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Configure-WorkerFirewall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Start-TelemetryAgent.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Configure-MetricsFirewall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Set-WorkerConfiguration.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Start-WorkerFromConfig.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Start-TelemetryFromConfig.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Start-WorkerStack.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Clear-WorkerAgentKey.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Show-WorkerStatus.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Set-WorkerCache.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Install-Worker.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Uninstall-Worker.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion; Check: IsWorker
Source: "{#ProjectRoot}\scripts\Detect-WorkerIP.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\Test-WorkerInstallReady.ps1"; Flags: dontcopy
Source: "README-WORKER.txt"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion; Check: IsWorker
Source: "ROLE-WORKER.txt"; DestDir: "{app}"; DestName: "install-role.txt"; Flags: ignoreversion; Check: IsWorker

[Icons]
Name: "{autoprograms}\GPUmates Coordinator\GPUmates Coordinator"; Filename: "{app}\GPUmates-Coordinator.exe"; WorkingDir: "{app}"; Comment: "Open the local PC1 GPU cluster Control Center"; Check: IsCoordinator
Name: "{autoprograms}\GPUmates Coordinator\Readme and safety"; Filename: "{app}\README.txt"; Check: IsCoordinator
Name: "{autodesktop}\GPUmates Coordinator"; Filename: "{app}\GPUmates-Coordinator.exe"; WorkingDir: "{app}"; Tasks: desktopicon; Check: IsCoordinator
Name: "{autoprograms}\GPUmates Worker\Start GPUmates Worker"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Start-WorkerStack.ps1"""; WorkingDir: "{app}"; Check: IsWorker
Name: "{autoprograms}\GPUmates Worker\GPUmates Worker Status"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File ""{app}\scripts\Show-WorkerStatus.ps1"""; WorkingDir: "{app}"; Check: IsWorker
Name: "{autoprograms}\GPUmates Worker\Open GPU Dashboard"; Filename: "{code:GetDashboardUrl}"; Check: IsWorker
Name: "{autoprograms}\GPUmates Worker\GPUmates Worker Cache Settings"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\scripts\Set-WorkerCache.ps1"""; WorkingDir: "{app}"; Comment: "Enable, disable, inspect, or clear the persistent worker tensor cache"; Check: IsWorker
Name: "{autoprograms}\GPUmates Worker\Forget saved AgentKey"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File ""{app}\scripts\Clear-WorkerAgentKey.ps1"" -Confirm:$false"; WorkingDir: "{app}"; Check: IsWorker
Name: "{autoprograms}\GPUmates Worker\Readme and safety"; Filename: "{app}\README.txt"; Check: IsWorker
Name: "{autodesktop}\Start GPUmates Worker"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Start-WorkerStack.ps1"""; WorkingDir: "{app}"; Tasks: desktopicon; Check: IsWorker

[Run]
Filename: "{app}\GPUmates-Coordinator.exe"; Description: "Open GPUmates Coordinator now"; Flags: postinstall runasoriginaluser skipifsilent nowait; Check: IsCoordinator
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Start-WorkerStack.ps1"""; Description: "Start GPUmates Worker now"; Flags: postinstall runasoriginaluser skipifsilent nowait; Check: IsWorker

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Uninstall-GPUmatesRole.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "GPUmatesUnifiedCleanup"

[Registry]
Root: HKLM; Subkey: "Software\GPUmates\Unified"; ValueType: string; ValueName: "InstallRole"; ValueData: "{code:GetSelectedRole}"; Flags: uninsdeletevalue
Root: HKLM; Subkey: "Software\GPUmates\Unified"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKLM; Subkey: "Software\GPUmates\Unified"; ValueType: string; ValueName: "NodeName"; ValueData: "{code:GetNodeName}"; Flags: uninsdeletevalue
Root: HKLM; Subkey: "Software\GPUmates\Unified"; ValueType: string; ValueName: "CoordinatorIP"; ValueData: "{code:GetCoordinatorIP}"; Flags: uninsdeletevalue
Root: HKLM; Subkey: "Software\GPUmates\Unified"; ValueType: string; ValueName: "WorkerIP"; ValueData: "{code:GetWorkerIP}"; Flags: uninsdeletevalue; Check: IsWorker
Root: HKLM; Subkey: "Software\GPUmates\Worker"; ValueType: dword; ValueName: "CacheEnabled"; ValueData: "{code:GetCacheEnabledRegistryValue}"; Flags: uninsdeletevalue uninsdeletekeyifempty; Check: IsWorker

[Code]
var
  RolePage: TInputOptionWizardPage;
  CoordinatorPage: TInputQueryWizardPage;
  WorkerPage: TInputQueryWizardPage;
  CachePage: TInputOptionWizardPage;

function IsExistingWorkerInstall: Boolean;
var
  InstalledRole: String;
begin
  Result := False;
  if RegQueryStringValue(HKLM64, 'Software\GPUmates\Unified', 'InstallRole', InstalledRole) then
    Result := CompareText(Trim(InstalledRole), 'worker') = 0;
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

function NormalizeRole(const Value: String): String;
begin
  Result := Lowercase(Trim(Value));
  if (Result <> 'coordinator') and (Result <> 'worker') then
    Result := '';
end;

function GetRoleParameter: String;
begin
  Result := NormalizeRole(ExpandConstant('{param:ROLE|}'));
end;

function ReadInstalledRole: String;
var
  Value: String;
begin
  Result := '';
  if RegQueryStringValue(HKLM64, 'Software\GPUmates\Unified', 'InstallRole', Value) then
    Result := NormalizeRole(Value);
end;

function ReadStoredSetting(const ValueName: String): String;
var
  Value: String;
begin
  Result := '';
  if RegQueryStringValue(HKLM64, 'Software\GPUmates\Unified', ValueName, Value) then
    Result := Trim(Value);
end;

function SelectedRole: String;
begin
  if RolePage <> nil then
  begin
    if RolePage.SelectedValueIndex = 1 then
      Result := 'worker'
    else
      Result := 'coordinator';
  end
  else
  begin
    Result := GetRoleParameter;
    if Result = '' then
      Result := ReadInstalledRole;
    if Result = '' then
      Result := 'coordinator';
  end;
end;

function GetSelectedRole(Param: String): String;
begin
  Result := SelectedRole;
end;

function IsCoordinator: Boolean;
begin
  Result := SelectedRole = 'coordinator';
end;

function IsWorker: Boolean;
begin
  Result := SelectedRole = 'worker';
end;

function RoleDefaultDirectory(const Role: String): String;
begin
  if Role = 'worker' then
    Result := ExpandConstant('{autopf}\GPUmates\Worker')
  else
    Result := ExpandConstant('{autopf}\GPUmates\Coordinator');
end;

function GetDefaultDirName(Param: String): String;
var
  ExistingPath: String;
begin
  if RegQueryStringValue(HKLM64, 'Software\GPUmates\Unified', 'InstallPath', ExistingPath) and
     (ReadInstalledRole = SelectedRole) then
    Result := ExistingPath
  else
    Result := RoleDefaultDirectory(SelectedRole);
end;

function LegacyKeyExists(const ProductId: String): Boolean;
var
  Key: String;
begin
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + ProductId;
  Result := RegKeyExists(HKLM64, Key) or RegKeyExists(HKLM32, Key) or RegKeyExists(HKCU, Key);
end;

function InitializeSetup: Boolean;
var
  SuppliedRole, InstalledRole, CacheParam: String;
begin
  Result := False;
  CacheParam := GetCacheParameter;
  if (CacheParam <> '') and (CacheParam <> '0') and (CacheParam <> '1') then
  begin
    MsgBox('CACHE must be 1 (enabled) or 0 (disabled).', mbError, MB_OK);
    Exit;
  end;
  SuppliedRole := Lowercase(Trim(ExpandConstant('{param:ROLE|}')));
  if (SuppliedRole <> '') and (NormalizeRole(SuppliedRole) = '') then
  begin
    MsgBox('ROLE must be coordinator or worker.', mbError, MB_OK);
    Exit;
  end;
  InstalledRole := ReadInstalledRole;
  if (SuppliedRole <> '') and (InstalledRole <> '') and
     (NormalizeRole(SuppliedRole) <> InstalledRole) then
  begin
    MsgBox('GPUmates is already installed as ' + InstalledRole +
      '. Uninstall it before changing this PC''s role.', mbError, MB_OK);
    Exit;
  end;
  if LegacyKeyExists('{2E94DD0C-C7F2-44C8-B59D-D55799DB7A61}_is1') or
     LegacyKeyExists('{B02F5DF2-444F-47E0-8EEE-1D6A8864C125}_is1') then
  begin
    MsgBox('An older standalone GPUmates Worker or Coordinator is installed. Uninstall it first, then run this unified Setup again. Existing role data is retained for migration.', mbError, MB_OK);
    Exit;
  end;
  Result := True;
end;

function DetectPrivateIP: String;
var
  PowerShellExe, ScriptPath, OutputPath, Params: String;
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
  RoleParam, InstalledRole, NodeParam, CoordinatorParam, WorkerParam: String;
begin
  RolePage := CreateInputOptionPage(
    wpInfoBefore,
    'Choose this computer''s role',
    'Install exactly one GPUmates role',
    'Choose Main PC only on the computer that stores GGUF models. Every additional NVIDIA GPU computer uses Worker.',
    True,
    False
  );
  RolePage.Add('Main PC / Coordinator - model library, inference, Control Center, and dashboard');
  RolePage.Add('GPU Worker - contribute this PC''s NVIDIA GPU to the Main PC');

  RoleParam := GetRoleParameter;
  InstalledRole := ReadInstalledRole;
  if InstalledRole <> '' then
    RoleParam := InstalledRole;
  if RoleParam = 'worker' then
    RolePage.SelectedValueIndex := 1
  else
    RolePage.SelectedValueIndex := 0;

  CoordinatorPage := CreateInputQueryPage(
    RolePage.ID,
    'Main PC network identity',
    'Confirm the Coordinator name and private IPv4 address',
    'Use a DHCP-reserved or static RFC1918 address. Setup creates a local-only seed; workers are added later in the Control Center.'
  );
  CoordinatorPage.Add('Coordinator name:', False);
  CoordinatorPage.Add('This Main PC IPv4:', False);

  WorkerPage := CreateInputQueryPage(
    CoordinatorPage.ID,
    'Worker private LAN configuration',
    'Choose the Main PC and this worker address',
    'Use fixed RFC1918 IPv4 addresses. Setup will permit only the Main PC through Windows Firewall.'
  );
  WorkerPage.Add('Worker name:', False);
  WorkerPage.Add('Coordinator / Main PC IPv4:', False);
  WorkerPage.Add('This worker PC IPv4:', False);

  NodeParam := Trim(ExpandConstant('{param:NODENAME|}'));
  if NodeParam = '' then
    NodeParam := ReadStoredSetting('NodeName');
  if NodeParam = '' then
    NodeParam := GetEnv('COMPUTERNAME');
  CoordinatorPage.Values[0] := NodeParam;
  WorkerPage.Values[0] := NodeParam;
  CoordinatorParam := Trim(ExpandConstant('{param:COORDINATORIP|}'));
  if CoordinatorParam = '' then
    CoordinatorParam := ReadStoredSetting('CoordinatorIP');
  CoordinatorPage.Values[1] := CoordinatorParam;
  WorkerPage.Values[1] := CoordinatorParam;
  WorkerParam := Trim(ExpandConstant('{param:WORKERIP|}'));
  if WorkerParam = '' then
    WorkerParam := ReadStoredSetting('WorkerIP');
  WorkerPage.Values[2] := WorkerParam;

  CachePage := CreateInputOptionPage(
    WorkerPage.ID,
    'Faster repeat model loads',
    'Keep remotely loaded model tensors on this Worker',
    'Recommended only on a trusted PC you own. The first load still uses the network; later loads can reuse raw tensor data that persists on this PC and uses disk space. Disabling caching does not delete existing tensor files; use Start Menu > GPUmates Worker > GPUmates Worker Cache Settings > Clear cache to remove them.',
    False,
    False
  );
  CachePage.Add('Enable persistent worker tensor cache (recommended)');
  CachePage.Values[0] := GetInitialCacheEnabled;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := ((PageID = CoordinatorPage.ID) and IsWorker) or
            ((PageID = WorkerPage.ID) and IsCoordinator) or
            ((PageID = CachePage.ID) and IsCoordinator);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = CoordinatorPage.ID) and (Trim(CoordinatorPage.Values[1]) = '') then
    CoordinatorPage.Values[1] := DetectPrivateIP;
  if (CurPageID = WorkerPage.ID) and (Trim(WorkerPage.Values[2]) = '') then
    WorkerPage.Values[2] := DetectPrivateIP;
end;

function IsPrivateIPv4(const Value: String): Boolean;
var
  Text, Part: String;
  PartIndex, I, Number, A, B, C, D: Integer;
begin
  Result := False;
  Text := Trim(Value) + '.';
  Part := '';
  PartIndex := 0;
  A := -1; B := -1; C := -1; D := -1;
  for I := 1 to Length(Text) do
  begin
    if Text[I] = '.' then
    begin
      if (Part = '') or (PartIndex > 3) then Exit;
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
      if (Text[I] < '0') or (Text[I] > '9') then Exit;
      Part := Part + Text[I];
    end;
  end;
  if (PartIndex <> 4) or (A < 0) or (A > 255) or (B < 0) or (B > 255) or
     (C < 0) or (C > 255) or (D < 0) or (D > 255) then Exit;
  Result := (A = 10) or ((A = 172) and (B >= 16) and (B <= 31)) or
            ((A = 192) and (B = 168));
end;

function IsValidNodeName(const Value: String): Boolean;
var
  I: Integer;
  Allowed: String;
begin
  Result := False;
  if (Length(Trim(Value)) < 1) or (Length(Trim(Value)) > 64) then Exit;
  Allowed := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-';
  for I := 1 to Length(Value) do
    if Pos(Value[I], Allowed) = 0 then Exit;
  Result := True;
end;

function ValidateCurrentRole(var ErrorText: String): Boolean;
var
  InstalledRole: String;
begin
  Result := False;
  ErrorText := '';
  InstalledRole := ReadInstalledRole;
  if (InstalledRole <> '') and (InstalledRole <> SelectedRole) then
  begin
    ErrorText := 'GPUmates is already installed as ' + InstalledRole + '. Uninstall it before changing this PC''s role.';
    Exit;
  end;
  if IsCoordinator then
  begin
    if not IsValidNodeName(CoordinatorPage.Values[0]) then
      ErrorText := 'Coordinator name may contain only letters, numbers, spaces, dots, underscores, and hyphens.'
    else if not IsPrivateIPv4(CoordinatorPage.Values[1]) then
      ErrorText := 'Main PC IP must be one private IPv4 address.';
  end
  else
  begin
    if not IsValidNodeName(WorkerPage.Values[0]) then
      ErrorText := 'Worker name may contain only letters, numbers, spaces, dots, underscores, and hyphens.'
    else if not IsPrivateIPv4(WorkerPage.Values[1]) then
      ErrorText := 'Coordinator IP must be one private IPv4 address.'
    else if not IsPrivateIPv4(WorkerPage.Values[2]) then
      ErrorText := 'Worker IP must be one private IPv4 address assigned to this PC.'
    else if CompareText(Trim(WorkerPage.Values[1]), Trim(WorkerPage.Values[2])) = 0 then
      ErrorText := 'Coordinator and worker IPs must be different.';
  end;
  Result := ErrorText = '';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ErrorText, InstalledPath, InstalledRole: String;
begin
  Result := True;
  if CurPageID = RolePage.ID then
  begin
    InstalledRole := ReadInstalledRole;
    if (InstalledRole <> '') and (InstalledRole <> SelectedRole) then
    begin
      MsgBox('GPUmates is already installed as ' + InstalledRole +
        '. Uninstall it before changing this PC''s role.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if RegQueryStringValue(HKLM64, 'Software\GPUmates\Unified', 'InstallPath', InstalledPath) and
       (ReadInstalledRole = SelectedRole) then
      WizardForm.DirEdit.Text := InstalledPath
    else
      WizardForm.DirEdit.Text := RoleDefaultDirectory(SelectedRole);
    Exit;
  end;
  if (CurPageID = CoordinatorPage.ID) or (CurPageID = WorkerPage.ID) then
  begin
    if not ValidateCurrentRole(ErrorText) then
    begin
      MsgBox(ErrorText, mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function GetCoordinatorIP(Param: String): String;
begin
  if IsCoordinator then
    Result := Trim(CoordinatorPage.Values[1])
  else
    Result := Trim(WorkerPage.Values[1]);
end;

function GetWorkerIP(Param: String): String;
begin
  Result := Trim(WorkerPage.Values[2]);
end;

function GetNodeName(Param: String): String;
begin
  if IsCoordinator then
    Result := Trim(CoordinatorPage.Values[0])
  else
    Result := Trim(WorkerPage.Values[0]);
end;

function GetDashboardUrl(Param: String): String;
begin
  Result := 'http://' + Trim(WorkerPage.Values[1]) + ':8090';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  PowerShellExe, ScriptPath, ErrorPath, Params, ErrorText, ValidationError: String;
  LoadedError: AnsiString;
  ResultCode: Integer;
begin
  Result := '';
  if WizardSilent and (Trim(ExpandConstant('{param:ROLE|}')) = '') then
  begin
    Result := 'Silent setup requires /ROLE=coordinator or /ROLE=worker.';
    Exit;
  end;
  if IsWorker and WizardSilent and (GetCacheParameter = '') then
  begin
    Result := 'Silent Worker setup requires /CACHE=1 or /CACHE=0.';
    Exit;
  end;
  if IsWorker and WizardSilent and
     ((Trim(ExpandConstant('{param:COORDINATORIP|}')) = '') or
      (Trim(ExpandConstant('{param:WORKERIP|}')) = '') or
      (Trim(ExpandConstant('{param:NODENAME|}')) = '')) then
  begin
    Result := 'Silent Worker setup requires /COORDINATORIP, /WORKERIP, and /NODENAME.';
    Exit;
  end;
  if IsCoordinator and (Trim(CoordinatorPage.Values[1]) = '') then
    CoordinatorPage.Values[1] := DetectPrivateIP;
  if not ValidateCurrentRole(ValidationError) then
  begin
    Result := ValidationError;
    Exit;
  end;

  PowerShellExe := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ErrorPath := ExpandConstant('{tmp}\gpumates-preflight-error.txt');
  DeleteFile(ErrorPath);
  if IsCoordinator then
  begin
    ExtractTemporaryFile('Test-CoordinatorInstallReady.ps1');
    ScriptPath := ExpandConstant('{tmp}\Test-CoordinatorInstallReady.ps1');
    Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath +
      '" -CoordinatorIP "' + GetCoordinatorIP('') + '" -ErrorPath "' + ErrorPath + '"';
  end
  else
  begin
    ExtractTemporaryFile('Test-WorkerInstallReady.ps1');
    ScriptPath := ExpandConstant('{tmp}\Test-WorkerInstallReady.ps1');
    Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath +
      '" -WorkerIP "' + GetWorkerIP('') + '" -ErrorPath "' + ErrorPath + '"';
  end;

  if (not Exec(PowerShellExe, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode)) or
     (ResultCode <> 0) then
  begin
    if LoadStringFromFile(ErrorPath, LoadedError) then
      ErrorText := Trim(String(LoadedError))
    else
      ErrorText := 'Verify the selected IP, free ports, NVIDIA driver, usable GPU, and Microsoft Visual C++ v14 x64 runtime.';
    Result := 'GPUmates pre-install check failed: ' + ErrorText;
  end;
  DeleteFile(ErrorPath);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  PowerShellExe, ScriptPath, Params: String;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  PowerShellExe := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  if IsCoordinator then
  begin
    ScriptPath := ExpandConstant('{app}\scripts\Install-Coordinator.ps1');
    Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath +
      '" -CoordinatorIP "' + GetCoordinatorIP('') +
      '" -NodeName "' + GetNodeName('') +
      '" -InstallRoot "' + ExpandConstant('{app}') + '"';
  end
  else
  begin
    ScriptPath := ExpandConstant('{app}\scripts\Install-Worker.ps1');
    Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath +
      '" -CoordinatorIP "' + GetCoordinatorIP('') +
      '" -WorkerIP "' + GetWorkerIP('') +
      '" -NodeName "' + GetNodeName('') + '"';
    if IsCacheEnabled then
      Params := Params + ' -EnableCache';
  end;
  if (not Exec(PowerShellExe, Params, ExpandConstant('{app}'), SW_HIDE,
      ewWaitUntilTerminated, ResultCode)) or (ResultCode <> 0) then
    RaiseException('GPUmates ' + SelectedRole + ' configuration failed. Review Setup logging and verify the selected network identity.');
end;
