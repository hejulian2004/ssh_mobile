[CmdletBinding()]
param([string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root = Get-RepositoryRoot
$temp = Initialize-NativeEnvironment $TempRoot
Assert-Commands @('python', 'git')
$testData = Join-Path $root 'protocol\relay_v2_testdata'
$protoRelative = 'protocol/proto/relay/v2/relay_v2.proto'
$proto = Join-Path $root $protoRelative
Invoke-CommandChecked python @((Join-Path $testData 'generate_fixtures.py'), '--check') $root
$manifest = Get-Content (Join-Path $testData 'manifest.json') -Raw | ConvertFrom-Json
if ($manifest.schema_version -ne 2 -or $manifest.fixtures.Count -ne 23 -or $manifest.constants.RELAY_V2_VERSION -ne 2) {
  throw 'Relay V2 manifest shape is invalid.'
}
$text = Get-Content $proto -Raw
if ($text -notmatch 'source_device_id\s*=\s*7' -or $text -match 'target_device_id\s*=\s*7|sender_device_id\s*=\s*7|ready\s*=\s*14|message\s+RelayDataReady') {
  throw 'Forbidden Relay V2 additions are present.'
}
$status = 'NOT RUN (protoc unavailable)'
if (Get-Command protoc -ErrorAction SilentlyContinue) {
  $commit = '6ec194bb3a66a748215d3abc11d6da84bd329619'
  $run = Join-Path $temp ("relay-contract-{0}" -f [Guid]::NewGuid().ToString('N'))
  $frozen = Join-Path $run $protoRelative
  New-Item -ItemType Directory (Split-Path $frozen -Parent) -Force | Out-Null
  try {
    & git -C $root show "${commit}:$protoRelative" | Set-Content $frozen -Encoding utf8NoBOM
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read frozen proto.' }
    $currentDescriptor = Join-Path $run 'current.desc'
    $frozenDescriptor = Join-Path $run 'frozen.desc'
    Invoke-CommandChecked protoc @('--proto_path=protocol', "--descriptor_set_out=$currentDescriptor", $protoRelative) $root
    Invoke-CommandChecked protoc @('--proto_path=protocol', "--descriptor_set_out=$frozenDescriptor", $protoRelative) $run
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { throw 'Go is required for the shared Relay V2 descriptor helper.' }
    Invoke-CommandChecked go @('run', './cmd/relay-v2-descriptor-check', "--current=$currentDescriptor", "--frozen=$frozenDescriptor") (Join-Path $root 'relay')
    $status = "additive source_device_id=7 compatible with $commit"
  } finally {
    Remove-Item $run -Recurse -Force -ErrorAction SilentlyContinue
  }
}
Write-Host "Relay V2 contract passed; descriptor $status."
