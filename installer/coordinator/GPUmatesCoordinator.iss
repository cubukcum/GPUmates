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
