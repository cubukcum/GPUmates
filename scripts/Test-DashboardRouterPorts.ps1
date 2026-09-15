[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

# Load the actual URL-validation functions without starting a dashboard or
# contacting any running model server. Invalid URLs must never reach HTTP.
$ParseErrors = $null
$Tokens = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Start-GPUmatesDashboard.ps1'), [ref]$Tokens, [ref]$ParseErrors)
Assert-Test ($ParseErrors.Count -eq 0) 'The dashboard script must parse.'
foreach ($Name in @('Get-ConfigProperty', 'ConvertTo-SafeLlamaModels', 'Get-LlamaStatus')) {
    $Function = $Ast.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name }, $true)
    Assert-Test ($null -ne $Function) "Missing dashboard function $Name."
    Invoke-Expression $Function.Extent.Text
}
$Requests = [Collections.Generic.List[string]]::new()
function Invoke-GPUmatesHttpGet {
    param([uri]$Uri, [hashtable]$Header, [int]$TimeoutMilliseconds)
    $Requests.Add($Uri.AbsoluteUri)
    return [pscustomobject]@{ data = @([pscustomobject]@{ id = 'port-test'; status = [pscustomobject]@{ value = 'unloaded' } }) }
}

foreach ($RouterPort in @(8080, 18080)) {
    $OtherPort = if ($RouterPort -eq 8080) { 18080 } else { 8080 }
    foreach ($HostName in @('localhost', '127.0.0.1', '192.168.1.10')) {
        $BaseUrl = "http://${HostName}:$RouterPort"
        $Requests.Clear()
        $Result = Get-LlamaStatus -RouterPort $RouterPort -AllowedCoordinatorIP '192.168.1.10' -LlamaConfig ([pscustomobject]@{
            enabled = $true; baseUrl = $BaseUrl; publicUrl = "http://192.168.1.10:$RouterPort"
        })
        Assert-Test ($Result.online -and $Result.publicUrl -eq "http://192.168.1.10:$RouterPort") 'Configured local and public router URLs must be accepted.'
        Assert-Test ($Requests.Count -eq 1 -and $Requests[0] -eq "$BaseUrl/models") 'Router status must fetch models from the selected port.'
    }
    $Requests.Clear()
    $Result = Get-LlamaStatus -RouterPort $RouterPort -AllowedCoordinatorIP '192.168.1.10' -LlamaConfig ([pscustomobject]@{ enabled = $true })
    Assert-Test ($Result.online -and $Requests[0] -eq "http://127.0.0.1:$RouterPort/models") 'The fallback router URL must use the configured port.'

    foreach ($InvalidUrl in @("http://127.0.0.1:$OtherPort", "http://192.168.1.11:$RouterPort", "https://127.0.0.1:$RouterPort", "http://user@127.0.0.1:$RouterPort", "http://127.0.0.1:$RouterPort/path", "http://127.0.0.1:$RouterPort/?key=value")) {
        foreach ($Property in @('baseUrl', 'publicUrl')) {
            $Requests.Clear()
            $Config = [pscustomobject]@{ enabled = $true; baseUrl = "http://127.0.0.1:$RouterPort"; publicUrl = "http://192.168.1.10:$RouterPort" }
            $Config.$Property = $InvalidUrl
            $Result = Get-LlamaStatus -RouterPort $RouterPort -AllowedCoordinatorIP '192.168.1.10' -LlamaConfig $Config
            $ExpectedError = if ($Property -eq 'baseUrl') { 'invalid_local_url' } else { 'invalid_public_url' }
            Assert-Test (-not $Result.online -and $Result.error -eq $ExpectedError -and $Requests.Count -eq 0) "An invalid $Property must be rejected before HTTP: $InvalidUrl"
        }
    }
}
Write-Host 'Dashboard router URL checks passed on default and custom ports; unrelated ports, hosts, credentials, and paths remain blocked.'
