param([Parameter(ValueFromRemainingArguments = $true)][string[]]$LogArguments)
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
Push-Location -LiteralPath $repositoryRoot
try {
    & dart run (Join-Path $repositoryRoot 'tool/agent_logs.dart') @LogArguments
    $result = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $result
