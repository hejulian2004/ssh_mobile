[CmdletBinding()]
param([string]$Minimum=$env:SDK_COVERAGE_MINIMUM,[string]$DartTimeout=$env:SDK_DART_COVERAGE_TIMEOUT,[switch]$KeepArtifacts,[string]$TempRoot=$env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root=Get-RepositoryRoot
$temp=Initialize-NativeEnvironment $TempRoot
if(-not $Minimum){$Minimum='90'}
if(-not $DartTimeout){$DartTimeout='10m'}
if($env:SDK_KEEP_COVERAGE_ARTIFACTS -eq '1'){$KeepArtifacts=$true}
if($Minimum -notmatch '^[0-9]+(?:\.[0-9]+)?$'){[Console]::Error.WriteLine("SDK_COVERAGE_MINIMUM must be numeric: $Minimum");exit 64}
Write-Host "SDK coverage threshold: $Minimum%"
Assert-Commands @('dart','cargo','cargo-llvm-cov')
ConvertTo-TimeoutSeconds $DartTimeout|Out-Null
$run=Join-Path $temp ("sdk-coverage-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run|Out-Null
$packages=@(
 @{Name='network_sdk';Dir='packages\infrastructure\network_sdk';Tests=@('test/network_sdk_contract_test.dart','test/network_v2_contract_test.dart','test/network_v2_facade_test.dart','test/network_models_boundaries_test.dart','test/realtime_test.dart')},
 @{Name='network_transport';Dir='packages\infrastructure\network_transport';Tests=@('test/event_mux_test.dart','test/network_boundary_test.dart','test/network_runtime_test.dart','test/transport_contract_test.dart')},
 @{Name='realtime_media';Dir='packages\infrastructure\realtime_media';Tests=@('test/realtime_media_lifecycle_test.dart','test/realtime_media_public_contract_test.dart')},
 @{Name='ssh_mobile_network_native';Dir='packages\infrastructure\ssh_mobile_network_native';Tests=@('test/ssh_mobile_network_native_test.dart','test/protocol_event_matrix_test.dart','test/protocol_event_matrix_events_test.dart')}
)
function Measure-Lcov([string]$Name,[string]$Path){
  $found=0;$hit=0;$scope=$false
  foreach($line in Get-Content $Path){
    if($line.StartsWith('SF:')){$source=$line.Substring(3).Replace('\','/');$scope=($source -match "(^lib/|^package:$Name/|/packages/infrastructure/$Name/lib/)" -and $source -notmatch 'third_party|\.g\.dart$')}
    elseif($scope -and $line -match '^DA:[0-9]+,([0-9]+)'){$found++;if([int64]$Matches[1]-gt 0){$hit++}}
  }
  if($found-eq 0){throw "No coverage for $Name"}
  @{Found=$found;Hit=$hit;Percent=100.0*$hit/$found}
}
try{
  $allFound=0;$allHit=0
  foreach($package in $packages){
    $dir=Join-Path $root $package.Dir;$raw=Join-Path $run "$($package.Name)-raw";$profile=Join-Path $run "$($package.Name).lcov"
    New-Item -ItemType Directory $raw|Out-Null
    Invoke-CommandWithTimeout dart (@('test',"--coverage=$raw",'--concurrency=1','--reporter','compact')+$package.Tests) $DartTimeout $dir
    Invoke-CommandChecked dart @('run','coverage:format_coverage','--lcov',"--in=$raw", "--out=$profile", "--packages=$(Join-Path $root '.dart_tool\package_config.json')",'--report-on=lib',"--package=$dir") $dir
    $c=Measure-Lcov $package.Name $profile
    Write-Host ("Dart {0}: {1}/{2} {3:N2}%"-f $package.Name,$c.Hit,$c.Found,$c.Percent)
    if($c.Percent-lt[double]$Minimum){throw "Dart SDK coverage below $Minimum%."}
    $allFound+=$c.Found;$allHit+=$c.Hit
  }
  $rustPackages=@('network-ffi','network-identity','network-nat','network-protocol','network-quic','network-relay-proto','network-transfer','network-transport','network-webrtc')
  $args=@('llvm-cov');foreach($p in $rustPackages){$args+=@('--package',$p)}
  $profile=Join-Path $run 'rust.lcov';$args+=@('--locked','--all-features','--no-fail-fast','--lcov','--output-path',$profile)
  Invoke-CommandChecked cargo $args (Join-Path $root 'native\network_core')
  $found=0;$hit=0;$scope=$false
  foreach($line in Get-Content $profile){
    if($line.StartsWith('SF:')){$source=$line.Substring(3).Replace('\','/');$scope=$false;foreach($p in $rustPackages){if($source -match "/crates/$p/" -and $source -notmatch 'target|build\.rs$'){$scope=$true;break}}}
    elseif($scope -and $line -match '^DA:[0-9]+,([0-9]+)'){$found++;if([int64]$Matches[1]-gt 0){$hit++}}
  }
  if($found-eq 0){throw 'No Rust coverage.'}
  $percent=100.0*$hit/$found
  if($percent-lt[double]$Minimum){throw "Rust SDK coverage below $Minimum%."}
  Write-Host ("SDK coverage passed: Dart {0:N2}%, Rust {1:N2}% (minimum {2}%)."-f(100.0*$allHit/$allFound),$percent,$Minimum)
}finally{
  if($KeepArtifacts){Write-Host "Artifacts: $run"}else{Remove-Item $run -Recurse -Force -ErrorAction SilentlyContinue}
}
