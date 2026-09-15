// Shared by both Coordinator installers. The caller declares CoordinatorPortsPage.
function IsValidTcpPort(const Value: String): Boolean;
var
  Text: String;
  I, Number: Integer;
begin
  Result := False;
  Text := Trim(Value);
  if Text = '' then Exit;
  for I := 1 to Length(Text) do
    if (Text[I] < '0') or (Text[I] > '9') then Exit;
  Number := StrToIntDef(Text, -1);
  Result := (Number >= 1024) and (Number <= 65535);
end;

function InitialCoordinatorPort(const ParameterName, ValueName, DefaultValue: String): String;
var
  StoredValue: String;
begin
  Result := Trim(ExpandConstant('{param:' + ParameterName + '|}'));
  if Result <> '' then Exit;
  if RegQueryStringValue(HKLM64, 'Software\GPUmates\Coordinator', ValueName, StoredValue) then
    Result := Trim(StoredValue);
  if Result = '' then Result := DefaultValue;
end;

procedure CreateCoordinatorPortsPage(AfterID: Integer);
begin
  CoordinatorPortsPage := CreateInputQueryPage(
    AfterID,
    'Main PC TCP ports',
    'Choose ports that are free on this computer',
    'Use three different ports from 1024 to 65535. If another app uses a port, choose another number. Sharing in the Control Center applies Windows Firewall rules to the selected chat and dashboard ports for the client IPs you allow.'
  );
  CoordinatorPortsPage.Add('Chat and inference API port:', False);
  CoordinatorPortsPage.Add('Read-only dashboard port:', False);
  CoordinatorPortsPage.Add('Control Center port (this PC only):', False);
  CoordinatorPortsPage.Values[0] := InitialCoordinatorPort('ROUTERPORT', 'RouterPort', '8080');
  CoordinatorPortsPage.Values[1] := InitialCoordinatorPort('DASHBOARDPORT', 'DashboardPort', '8090');
  CoordinatorPortsPage.Values[2] := InitialCoordinatorPort('CONTROLPORT', 'ControlPort', '8091');
end;

function ValidateCoordinatorPorts(var ErrorText: String): Boolean;
var
  I, RouterPort, DashboardPort, ControlPort: Integer;
begin
  Result := False;
  ErrorText := '';
  for I := 0 to 2 do
    if not IsValidTcpPort(CoordinatorPortsPage.Values[I]) then
    begin
      ErrorText := 'Each Coordinator TCP port must be a whole number from 1024 to 65535.';
      Exit;
    end;
  RouterPort := StrToInt(Trim(CoordinatorPortsPage.Values[0]));
  DashboardPort := StrToInt(Trim(CoordinatorPortsPage.Values[1]));
  ControlPort := StrToInt(Trim(CoordinatorPortsPage.Values[2]));
  if (RouterPort = DashboardPort) or (RouterPort = ControlPort) or (DashboardPort = ControlPort) then
  begin
    ErrorText := 'Chat, dashboard, and Control Center must use three different TCP ports.';
    Exit;
  end;
  Result := True;
end;

function GetRouterPort(Param: String): String;
begin
  Result := Trim(CoordinatorPortsPage.Values[0]);
end;

function GetCoordinatorDashboardPort(Param: String): String;
begin
  Result := Trim(CoordinatorPortsPage.Values[1]);
end;

function GetControlPort(Param: String): String;
begin
  Result := Trim(CoordinatorPortsPage.Values[2]);
end;

function CoordinatorPortArguments: String;
begin
  Result := ' -RouterPort ' + GetRouterPort('') +
    ' -DashboardPort ' + GetCoordinatorDashboardPort('') +
    ' -ControlPort ' + GetControlPort('');
end;
