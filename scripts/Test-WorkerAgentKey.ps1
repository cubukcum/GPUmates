[CmdletBinding()]
param([switch]$FrameworkChild)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $FrameworkChild) {
    $WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $WindowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -FrameworkChild
    if ($LASTEXITCODE -ne 0) { throw 'Worker AgentKey tests failed.' }
    return
}

# Extract only the production credential function. No telemetry listener,
# installed configuration, real saved credential, or firewall is touched.
$SourcePath = Join-Path $PSScriptRoot 'Start-TelemetryFromConfig.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) { throw ($ParseErrors | Out-String) }
$CredentialFunction = @($Ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-WorkerAgentKey'
})
if ($CredentialFunction.Count -ne 1) { throw 'Production Get-WorkerAgentKey function was not found.' }
. ([scriptblock]::Create($CredentialFunction[0].Extent.Text))

function Assert-TestCondition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$script:PromptCalls = 0
$script:PromptKey = $null
$script:Messages = [Collections.Generic.List[string]]::new()
function Read-Host {
    param([Parameter(Position = 0)][string]$Prompt, [switch]$AsSecureString)
    $script:PromptCalls++
    if (-not $AsSecureString) { throw 'AgentKey prompts must hide the entered key.' }
    if ($null -eq $script:PromptKey) { throw 'Unexpected AgentKey prompt.' }
    ConvertTo-SecureString -String $script:PromptKey -AsPlainText -Force
}
function Write-Host {
    param([Parameter(Position = 0)][object]$Object, [object]$ForegroundColor)
    $script:Messages.Add([string]$Object)
}
function Write-Warning {
    param([Parameter(Position = 0)][string]$Message)
    $script:Messages.Add($Message)
}

function Reset-TestPrompt {
    param([AllowNull()][string]$Key)
    $script:PromptCalls = 0
    $script:PromptKey = $Key
    $script:Messages.Clear()
}

function Write-ProtectedTestText {
    param([string]$Path, [string]$Text)
    ConvertTo-SecureString -String $Text -AsPlainText -Force |
        ConvertFrom-SecureString | Set-Content -LiteralPath $Path -Encoding ASCII
}

function Assert-SavedCredential {
    param([string]$Path, [string]$CoordinatorIP, [string]$ExpectedKey)
    $Ciphertext = (Get-Content -LiteralPath $Path -Raw).Trim()
    Assert-TestCondition (-not $Ciphertext.Contains($ExpectedKey)) 'Saved credential must not contain the plaintext key.'
    $SecureValue = ConvertTo-SecureString -String $Ciphertext
    $Plaintext = [Net.NetworkCredential]::new('', $SecureValue).Password
    $Envelope = $Plaintext | ConvertFrom-Json
    Assert-TestCondition ($Envelope.schemaVersion -eq 1) 'Saved credential must include the envelope version.'
    Assert-TestCondition ($Envelope.coordinatorIP -ceq $CoordinatorIP) 'Saved credential must bind to the canonical coordinator IP.'
    Assert-TestCondition ($Envelope.agentKey -ceq $ExpectedKey) 'Saved credential must retain the entered key.'
}

function Assert-KeyRejected {
    param([scriptblock]$Action)
    try { & $Action | Out-Null }
    catch {
        Assert-TestCondition ($_.Exception.Message -like '*24*') 'Invalid keys must explain the minimum key length.'
        return
    }
    throw 'Expected a short AgentKey to be rejected.'
}

$TemporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath((Join-Path $TemporaryParent ('gpumates-worker-key-' + [Guid]::NewGuid().ToString('N'))))
if (-not $TestRoot.StartsWith($TemporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory must stay inside the temporary directory.'
}
$FirstCoordinator = [Net.IPAddress]::Parse('192.0.2.10')
$SecondCoordinator = [Net.IPAddress]::Parse('192.0.2.20')
$FirstKey = 'A' * 40
$SecondKey = 'B' * 40
$OverrideKey = 'C' * 40

try {
    New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
    $SecretPath = Join-Path $TestRoot 'fresh\agent-key.dpapi'
    Reset-TestPrompt -Key $FirstKey
    $ActualKey = Get-WorkerAgentKey -CoordinatorIP $FirstCoordinator -SecretPath $SecretPath
    Assert-TestCondition ($ActualKey -ceq $FirstKey -and $script:PromptCalls -eq 1) 'Fresh enrollment must prompt for an AgentKey.'
    Assert-SavedCredential -Path $SecretPath -CoordinatorIP $FirstCoordinator.ToString() -ExpectedKey $FirstKey
    $SavedCiphertext = Get-Content -LiteralPath $SecretPath -Raw
    Reset-TestPrompt -Key $null
    $ActualKey = Get-WorkerAgentKey -CoordinatorIP $FirstCoordinator -SecretPath $SecretPath
    Assert-TestCondition ($ActualKey -ceq $FirstKey -and $script:PromptCalls -eq 0) 'Restart or reinstall with the same coordinator must reuse the saved key.'
    Assert-TestCondition ((Get-Content -LiteralPath $SecretPath -Raw) -ceq $SavedCiphertext) 'Reusing a key must preserve the credential file.'
    Microsoft.PowerShell.Utility\Write-Host '[PASS] Fresh enrollment saves an encrypted coordinator-bound key; the same coordinator reuses it.'

    Reset-TestPrompt -Key $SecondKey
    $ActualKey = Get-WorkerAgentKey -CoordinatorIP $SecondCoordinator -SecretPath $SecretPath
    Assert-TestCondition ($ActualKey -ceq $SecondKey -and $script:PromptCalls -eq 1) 'Changing coordinator must prompt instead of reusing the previous group key.'
    Assert-TestCondition (($script:Messages -join ' ') -match '(coordinator|main PC)') 'Changing coordinator must explain why a key is required.'
    Assert-SavedCredential -Path $SecretPath -CoordinatorIP $SecondCoordinator.ToString() -ExpectedKey $SecondKey
    Reset-TestPrompt -Key $FirstKey
    $ActualKey = Get-WorkerAgentKey -CoordinatorIP $FirstCoordinator -SecretPath $SecretPath
    Assert-TestCondition ($ActualKey -ceq $FirstKey -and $script:PromptCalls -eq 1) 'Returning to the old coordinator must also prompt.'
    Microsoft.PowerShell.Utility\Write-Host '[PASS] Moving between coordinator groups always requests and saves the new group key.'

    $CanonicalPath = Join-Path $TestRoot 'canonical.dpapi'
    $CanonicalIP = [Net.IPAddress]::Parse('192.0.522')
    Reset-TestPrompt -Key $FirstKey
    Get-WorkerAgentKey -CoordinatorIP $CanonicalIP -SecretPath $CanonicalPath | Out-Null
    Assert-SavedCredential -Path $CanonicalPath -CoordinatorIP '192.0.2.10' -ExpectedKey $FirstKey
    Reset-TestPrompt -Key $null
    $ActualKey = Get-WorkerAgentKey -CoordinatorIP $FirstCoordinator -SecretPath $CanonicalPath
    Assert-TestCondition ($ActualKey -ceq $FirstKey -and $script:PromptCalls -eq 0) 'Equivalent canonical coordinator addresses must reuse the saved key.'

    # Version 0.3.3 stored the encrypted key directly, with no coordinator binding.
    $LegacyPath = Join-Path $TestRoot 'legacy.dpapi'
    Write-ProtectedTestText -Path $LegacyPath -Text $FirstKey
    Reset-TestPrompt -Key $SecondKey
    $ActualKey = Get-WorkerAgentKey -CoordinatorIP $SecondCoordinator -SecretPath $LegacyPath
    Assert-TestCondition ($ActualKey -ceq $SecondKey -and $script:PromptCalls -eq 1) 'The 0.3.3 unbound key must require re-enrollment.'
    Assert-TestCondition ($script:Messages.Count -gt 0) 'Legacy migration must explain why the saved key cannot be reused.'
    Assert-SavedCredential -Path $LegacyPath -CoordinatorIP $SecondCoordinator.ToString() -ExpectedKey $SecondKey
    Microsoft.PowerShell.Utility\Write-Host '[PASS] Legacy 0.3.3 credentials require re-enrollment, and coordinator addresses are canonicalized.'

    $InvalidPath = Join-Path $TestRoot 'invalid.dpapi'
    $InvalidEnvelopes = @(
        'not JSON', 'null', '[]', '{}',
        (@{ schemaVersion = 2; coordinatorIP = '192.0.2.10'; agentKey = $FirstKey } | ConvertTo-Json -Compress),
        (@{ schemaVersion = 1; agentKey = $FirstKey } | ConvertTo-Json -Compress),
        (@{ schemaVersion = 1; coordinatorIP = '192.0.2.10' } | ConvertTo-Json -Compress),
        (@{ schemaVersion = 1; coordinatorIP = '192.0.2.10'; agentKey = 12345 } | ConvertTo-Json -Compress),
        (@{ schemaVersion = 1; coordinatorIP = '192.0.2.10'; agentKey = 'short' } | ConvertTo-Json -Compress)
    )
    foreach ($InvalidEnvelope in $InvalidEnvelopes) {
        Write-ProtectedTestText -Path $InvalidPath -Text $InvalidEnvelope
        Reset-TestPrompt -Key $SecondKey
        $ActualKey = Get-WorkerAgentKey -CoordinatorIP $FirstCoordinator -SecretPath $InvalidPath
        Assert-TestCondition ($ActualKey -ceq $SecondKey -and $script:PromptCalls -eq 1) 'Malformed or unsupported saved credentials must prompt again.'
        Assert-TestCondition ($script:Messages.Count -gt 0) 'Invalid saved credentials must explain recovery.'
        Assert-SavedCredential -Path $InvalidPath -CoordinatorIP $FirstCoordinator.ToString() -ExpectedKey $SecondKey
    }
    Set-Content -LiteralPath $InvalidPath -Value 'not valid DPAPI ciphertext' -Encoding ASCII
    Reset-TestPrompt -Key $SecondKey
    $ActualKey = Get-WorkerAgentKey -CoordinatorIP $FirstCoordinator -SecretPath $InvalidPath
    Assert-TestCondition ($ActualKey -ceq $SecondKey -and $script:PromptCalls -eq 1) 'Undecryptable saved credentials must allow re-enrollment.'
    Microsoft.PowerShell.Utility\Write-Host '[PASS] Corrupt ciphertext and malformed, incomplete, unsupported, or short saved credentials recover by prompting.'

    $SavedCiphertext = Get-Content -LiteralPath $SecretPath -Raw
    Reset-TestPrompt -Key ('S' * 23)
    Assert-KeyRejected { Get-WorkerAgentKey -CoordinatorIP $SecondCoordinator -SecretPath $SecretPath }
    Assert-TestCondition ($script:PromptCalls -eq 1) 'A coordinator change must prompt even when the entered key is invalid.'
    Assert-TestCondition ((Get-Content -LiteralPath $SecretPath -Raw) -ceq $SavedCiphertext) 'Invalid prompted keys must preserve the previous saved credential.'
    Reset-TestPrompt -Key $null
    Assert-KeyRejected { Get-WorkerAgentKey -CoordinatorIP $SecondCoordinator -SecretPath $SecretPath -AccessToken ('S' * 23) }
    Assert-TestCondition ($script:PromptCalls -eq 0) 'An invalid explicit key must fail validation without prompting.'
    Assert-TestCondition ((Get-Content -LiteralPath $SecretPath -Raw) -ceq $SavedCiphertext) 'An invalid explicit key must preserve the saved credential.'
    Microsoft.PowerShell.Utility\Write-Host '[PASS] Invalid input is rejected before replacing a saved credential.'

    Reset-TestPrompt -Key $null
    $ActualKey = Get-WorkerAgentKey -CoordinatorIP $SecondCoordinator -SecretPath $SecretPath -AccessToken $OverrideKey
    Assert-TestCondition ($ActualKey -ceq $OverrideKey -and $script:PromptCalls -eq 0) 'An explicit key must take priority over another coordinator''s saved key.'
    Assert-TestCondition ((Get-Content -LiteralPath $SecretPath -Raw) -ceq $SavedCiphertext) 'An explicit override must not replace the saved credential.'
    $NoSavePath = Join-Path $TestRoot 'override-only\agent-key.dpapi'
    $ActualKey = Get-WorkerAgentKey -CoordinatorIP $FirstCoordinator -SecretPath $NoSavePath -AccessToken $OverrideKey
    Assert-TestCondition ($ActualKey -ceq $OverrideKey -and -not (Test-Path -LiteralPath $NoSavePath)) 'An explicit override must not create a saved credential.'
    $AccessTokenParameter = @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AccessToken' })
    Assert-TestCondition ($AccessTokenParameter.Count -eq 1 -and $AccessTokenParameter[0].DefaultValue.Extent.Text -ceq '$env:GPUMATES_AGENT_KEY') 'The launcher must retain the environment AgentKey default.'
    Microsoft.PowerShell.Utility\Write-Host '[PASS] Explicit keys retain priority without persistence; the environment key default is preserved.'

    Assert-TestCondition (@(Get-ChildItem -LiteralPath $TestRoot -Recurse -File | Where-Object { $_.Extension -ne '.dpapi' }).Count -eq 0) 'Saving credentials must not leave temporary files behind.'

    # Keep the production command binding and ShouldProcess behavior intact,
    # replacing only its secret location with a file created by this test.
    $ClearSourcePath = Join-Path $PSScriptRoot 'Clear-WorkerAgentKey.ps1'
    $ClearAst = [Management.Automation.Language.Parser]::ParseFile($ClearSourcePath, [ref]$Tokens, [ref]$ParseErrors)
    if ($ParseErrors.Count -gt 0) { throw ($ParseErrors | Out-String) }
    $PathAssignment = @($ClearAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$SecretPath'
    })
    Assert-TestCondition ($PathAssignment.Count -eq 1) 'Clear-WorkerAgentKey secret path assignment must be found for an isolated test.'
    $ClearSecretPath = Join-Path $TestRoot 'clear-test.dpapi'
    Set-Content -LiteralPath $ClearSecretPath -Value 'test-only credential' -Encoding ASCII
    $ClearFixturePath = Join-Path $TestRoot 'Clear-WorkerAgentKey-TestFixture.ps1'
    $ClearSource = Get-Content -LiteralPath $ClearSourcePath -Raw
    $Replacement = '$SecretPath = ''' + $ClearSecretPath.Replace("'", "''") + ''''
    $ClearFixture = $ClearSource.Remove($PathAssignment[0].Extent.StartOffset, $PathAssignment[0].Extent.EndOffset - $PathAssignment[0].Extent.StartOffset).Insert($PathAssignment[0].Extent.StartOffset, $Replacement)
    Set-Content -LiteralPath $ClearFixturePath -Value $ClearFixture -Encoding UTF8
    $WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $WindowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ClearFixturePath -WhatIf | Out-Null
    Assert-TestCondition ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $ClearSecretPath)) 'The forget-key script must support WhatIf without deleting the key.'
    & $WindowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ClearFixturePath | Out-Null
    Assert-TestCondition ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $ClearSecretPath)) 'Windows PowerShell -File must clear the test key without a Confirm argument.'
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
    foreach ($InstallerPath in @('installer\unified\GPUmatesUnified.iss', 'installer\worker\GPUmatesWorker.iss')) {
        $ShortcutLines = @(Get-Content -LiteralPath (Join-Path $ProjectRoot $InstallerPath) | Where-Object { $_ -match '^Name:.*Forget saved AgentKey' })
        Assert-TestCondition ($ShortcutLines.Count -eq 1) 'Each worker installer must offer a forget-key shortcut.'
        Assert-TestCondition ($ShortcutLines[0] -match '-File.*Clear-WorkerAgentKey.ps1' -and $ShortcutLines[0] -notmatch '-Confirm:') 'The forget-key shortcut must not pass a boolean string to a Windows PowerShell -File switch.'
    }
    Microsoft.PowerShell.Utility\Write-Host '[PASS] Forget-key shortcut arguments work through Windows PowerShell -File; WhatIf preserves the test credential.'
    Microsoft.PowerShell.Utility\Write-Host '[PASS] Windows PowerShell DPAPI regression tests completed without starting GPUmates services or using installed credentials.'
}
finally {
    if ((Test-Path -LiteralPath $TestRoot) -and $TestRoot.StartsWith($TemporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
