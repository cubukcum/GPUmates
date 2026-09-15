#define AppVersion "0.1.0"
#define ProjectRoot "..\.."

[Setup]
AppId={{B02F5DF2-444F-47E0-8EEE-1D6A8864C125}
AppName=GPUmates Coordinator
AppVersion={#AppVersion}
AppVerName=GPUmates Coordinator {#AppVersion}
AppPublisher=GPUmates local project
AppCopyright=GPUmates contributors and third-party licensors
VersionInfoCompany=GPUmates
VersionInfoDescription=GPUmates PC1 coordinator and local Control Center
VersionInfoProductName=GPUmates Coordinator
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion=0.1.0.0
DefaultDirName={autopf}\GPUmates\Coordinator
DefaultGroupName=GPUmates Coordinator
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
WizardStyle=modern
DisableWelcomePage=no
InfoBeforeFile=SAFETY.txt
OutputDir={#ProjectRoot}\dist\installer
OutputBaseFilename=GPUmates-Coordinator-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
SetupLogging=yes
Uninstallable=yes
UninstallDisplayName=GPUmates Coordinator
UninstallDisplayIcon={app}\GPUmates-Coordinator.exe
CloseApplications=yes
RestartApplications=no
RestartIfNeededByRun=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce

[Files]
Source: "{#ProjectRoot}\dist\coordinator\GPUmates-Coordinator.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectRoot}\runtime\llama-server.exe"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\runtime\*.dll"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\GPUmates.Telemetry.psm1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\GPUmates.Network.psm1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Install-Coordinator.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Test-CoordinatorInstallReady.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\Detect-WorkerIP.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\Start-GPUmatesControlCenter.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Start-ModelRouter.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Start-ModelRouterFromControl.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Prepare-GPUmatesChatUi.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Start-GPUmatesDashboard.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Configure-CoordinatorFirewall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Configure-DashboardFirewall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Register-WorkerOnCoordinator.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Apply-CoordinatorSharing.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\Uninstall-Coordinator.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\config\telemetry-nodes.json"; DestDir: "{app}\config"; Flags: ignoreversion onlyifdoesntexist
Source: "{#ProjectRoot}\config\gpumates-models.ini"; DestDir: "{app}\config"; Flags: ignoreversion onlyifdoesntexist
Source: "{#ProjectRoot}\dashboard\static\*"; DestDir: "{app}\dashboard\static"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#ProjectRoot}\coordinator\static\*"; DestDir: "{app}\coordinator\static"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#ProjectRoot}\chat\static\*"; DestDir: "{app}\chat\static"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "README-INSTALLED.txt"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion
Source: "SAFETY.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectRoot}\installer\worker\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\GPUmates Coordinator\GPUmates Coordinator"; Filename: "{app}\GPUmates-Coordinator.exe"; WorkingDir: "{app}"; Comment: "Open the local PC1 GPU cluster Control Center"
Name: "{autoprograms}\GPUmates Coordinator\Readme and safety"; Filename: "{app}\README.txt"
Name: "{autodesktop}\GPUmates Coordinator"; Filename: "{app}\GPUmates-Coordinator.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\GPUmates-Coordinator.exe"; Description: "Open GPUmates Coordinator now"; Flags: postinstall runasoriginaluser skipifsilent nowait

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Uninstall-Coordinator.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "GPUmatesCoordinatorCleanup"

[Registry]
Root: HKLM; Subkey: "Software\GPUmates\Coordinator"; ValueType: string; ValueName: "NodeName"; ValueData: "{code:GetNodeName}"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKLM; Subkey: "Software\GPUmates\Coordinator"; ValueType: string; ValueName: "CoordinatorIP"; ValueData: "{code:GetCoordinatorIP}"; Flags: uninsdeletevalue
Root: HKLM; Subkey: "Software\GPUmates\Coordinator"; ValueType: string; ValueName: "RouterPort"; ValueData: "{code:GetRouterPort}"; Flags: uninsdeletevalue
Root: HKLM; Subkey: "Software\GPUmates\Coordinator"; ValueType: string; ValueName: "DashboardPort"; ValueData: "{code:GetCoordinatorDashboardPort}"; Flags: uninsdeletevalue
Root: HKLM; Subkey: "Software\GPUmates\Coordinator"; ValueType: string; ValueName: "ControlPort"; ValueData: "{code:GetControlPort}"; Flags: uninsdeletevalue

[Code]
var
  CoordinatorPage: TInputQueryWizardPage;
  CoordinatorPortsPage: TInputQueryWizardPage;

#include "CoordinatorPorts.iss"

function ReadCoordinatorSetting(const ValueName: String): String;
var
  StoredValue: String;
begin
  Result := '';
  if RegQueryStringValue(HKLM64, 'Software\GPUmates\Coordinator', ValueName, StoredValue) then
    Result := Trim(StoredValue);
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
  NodeParam, CoordinatorParam: String;
begin
  CoordinatorPage := CreateInputQueryPage(
    wpInfoBefore,
    'Main PC network identity',
    'Confirm the Coordinator name and private IPv4 address',
    'Use a DHCP-reserved or static RFC1918 address. Workers and sharing clients are added later in the Control Center.'
  );
  CoordinatorPage.Add('Coordinator name:', False);
  CoordinatorPage.Add('This Main PC IPv4:', False);
  NodeParam := Trim(ExpandConstant('{param:NODENAME|}'));
  if NodeParam = '' then NodeParam := ReadCoordinatorSetting('NodeName');
  if NodeParam = '' then NodeParam := GetEnv('COMPUTERNAME');
  CoordinatorPage.Values[0] := NodeParam;
  CoordinatorParam := Trim(ExpandConstant('{param:COORDINATORIP|}'));
  if CoordinatorParam = '' then CoordinatorParam := ReadCoordinatorSetting('CoordinatorIP');
  CoordinatorPage.Values[1] := CoordinatorParam;
  CreateCoordinatorPortsPage(CoordinatorPage.ID);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = CoordinatorPage.ID) and (Trim(CoordinatorPage.Values[1]) = '') then
    CoordinatorPage.Values[1] := DetectPrivateIP;
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

function ValidateCoordinatorIdentity(var ErrorText: String): Boolean;
var
  I: Integer;
  NodeName, Allowed: String;
begin
  ErrorText := '';
  NodeName := Trim(CoordinatorPage.Values[0]);
  Allowed := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-';
  if (Length(NodeName) < 1) or (Length(NodeName) > 64) then
    ErrorText := 'Coordinator name must contain 1 to 64 characters.';
  for I := 1 to Length(NodeName) do
    if Pos(NodeName[I], Allowed) = 0 then
      ErrorText := 'Coordinator name may contain only letters, numbers, spaces, dots, underscores, and hyphens.';
  if (ErrorText = '') and not IsPrivateIPv4(CoordinatorPage.Values[1]) then
    ErrorText := 'Main PC IP must be one private IPv4 address.';
  Result := ErrorText = '';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ErrorText: String;
begin
  Result := True;
  if CurPageID = CoordinatorPage.ID then
    Result := ValidateCoordinatorIdentity(ErrorText)
  else if CurPageID = CoordinatorPortsPage.ID then
    Result := ValidateCoordinatorPorts(ErrorText);
  if not Result then MsgBox(ErrorText, mbError, MB_OK);
end;

function GetNodeName(Param: String): String;
begin
  Result := Trim(CoordinatorPage.Values[0]);
end;

function GetCoordinatorIP(Param: String): String;
begin
  Result := Trim(CoordinatorPage.Values[1]);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  PowerShellExe, ScriptPath, ErrorPath, Params, ValidationError: String;
  LoadedError: AnsiString;
  ResultCode: Integer;
begin
  Result := '';
  if Trim(CoordinatorPage.Values[1]) = '' then
    CoordinatorPage.Values[1] := DetectPrivateIP;
  if not ValidateCoordinatorIdentity(ValidationError) then
  begin
    Result := ValidationError;
    Exit;
  end;
  if not ValidateCoordinatorPorts(ValidationError) then
  begin
    Result := ValidationError;
    Exit;
  end;
  ExtractTemporaryFile('Test-CoordinatorInstallReady.ps1');
  PowerShellExe := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant('{tmp}\Test-CoordinatorInstallReady.ps1');
  ErrorPath := ExpandConstant('{tmp}\gpumates-preflight-error.txt');
  DeleteFile(ErrorPath);
  Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath +
    '" -CoordinatorIP "' + GetCoordinatorIP('') + '" -ErrorPath "' + ErrorPath +
    '" -InstallRoot "' + ExpandConstant('{app}') + '"' + CoordinatorPortArguments;
  if (not Exec(PowerShellExe, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode)) or
     (ResultCode <> 0) then
  begin
    if LoadStringFromFile(ErrorPath, LoadedError) then
      Result := 'GPUmates pre-install check failed: ' + Trim(String(LoadedError))
    else
      Result := 'GPUmates pre-install check failed. Verify the selected IP, free ports, NVIDIA driver, usable GPU, and Microsoft Visual C++ v14 x64 runtime.';
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
  ScriptPath := ExpandConstant('{app}\scripts\Install-Coordinator.ps1');
  Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath +
    '" -CoordinatorIP "' + GetCoordinatorIP('') +
    '" -NodeName "' + GetNodeName('') +
    '" -InstallRoot "' + ExpandConstant('{app}') + '"' + CoordinatorPortArguments;
  if (not Exec(PowerShellExe, Params, ExpandConstant('{app}'), SW_HIDE,
      ewWaitUntilTerminated, ResultCode)) or (ResultCode <> 0) then
    RaiseException('GPUmates Coordinator configuration failed. Review Setup logging and verify the selected network identity.');
end;
