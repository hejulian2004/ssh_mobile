# Full App test and build jobs. Dot-sourced by full_test.ps1.

function AppFiles{$directory=Join-Path $root 'apps\ssh_mobile_full';@(Get-ChildItem (Join-Path $directory 'test') -Recurse -Filter '*_test.dart'|ForEach-Object{[IO.Path]::GetRelativePath($directory,$_.FullName).Replace('\','/')}|Where-Object{$_-notin@('test/features/startup/views/startup_screen_test.dart','test/screens/system_admin/system_admin_snapshot_tabs_test.dart','test/services/network/transfer_transport_test.dart')-and$_-notlike'test/integration/client_backend/*'}|Sort-Object)}
function Partition-AppFiles([string[]]$Files,[int]$Shard){
  $directory=Join-Path $root 'apps\ssh_mobile_full';$assignments=@();$sizes=@();for($index=0;$index-lt$AppShards;$index++){$assignments+=,([Collections.Generic.List[string]]::new());$sizes+=[int64]0}
  $ordered=@($Files|ForEach-Object{$path=$_;[pscustomobject]@{Path=$path;Size=(Get-Item -LiteralPath (Join-Path $directory $path)).Length}}|Sort-Object Size -Descending)
  foreach($item in $ordered){$target=0;for($candidate=1;$candidate-lt$AppShards;$candidate++){if($sizes[$candidate]-lt$sizes[$target]){$target=$candidate}};$assignments[$target].Add([string]$item.Path);$sizes[$target]+=[int64]$item.Size}
  [string[]]$assignments[$Shard]
}
function Invoke-AppTestWithRetry([string[]]$Arguments,[string]$Directory){
  for($attempt=1;$attempt-le2;$attempt++){try{Invoke-CommandWithTimeout flutter $Arguments $AppTimeout $Directory @{HTTP_PROXY='';HTTPS_PROXY='';ALL_PROXY='';NO_PROXY='localhost,127.0.0.1,::1'};return}catch{if($attempt-eq2){throw};Write-Host "Retrying App shard after failed attempt ${attempt}: $($_.Exception.Message)"}}
}
function Assert-AppSecurityIdentifiers{
  $directory=Join-Path $root 'apps\ssh_mobile_full';$forbidden=@('SshIdentityCache','reconnectCredentials','privateKeyDigest')
  foreach($needle in $forbidden){$matches=@(Get-ChildItem (Join-Path $directory 'lib') -Recurse -File -Filter '*.dart'|Select-String -SimpleMatch $needle);if($matches){$matches|Write-Host;throw "Security regression grep found $needle"}}
}
function JobApp([int]$Shard){
  if(-not(Need @('flutter'))){exit$gap};$directory=Join-Path $root 'apps\ssh_mobile_full';$files=@(Partition-AppFiles @(AppFiles) $Shard)
  $coverageDir=Join-Path $LogDir "coverage\shard-$Shard";New-Item -ItemType Directory $coverageDir -Force|Out-Null
  $batchSize=10
  for($offset=0;$offset -lt $files.Count;$offset+=$batchSize){
    $batch=@($files|Select-Object -Skip $offset -First $batchSize)
    $batchIndex=[int]($offset/$batchSize);$batchCoverage=Join-Path $coverageDir "lcov-batch-$batchIndex.info"
    $arguments=@('test','--no-pub','--exclude-tags','client-backend,native-loopback','--reporter','compact','--fail-fast','--timeout','60s','--concurrency',"$FlutterConcurrency")
    if($coverage){$arguments+=@('--coverage','--coverage-path',$batchCoverage)}
    $arguments+=$batch
    Invoke-AppTestWithRetry $arguments $directory
  }
  if($coverage){
    $merged=Join-Path $coverageDir 'lcov.info';Remove-Item $merged -Force -ErrorAction SilentlyContinue
    foreach($part in (Get-ChildItem $coverageDir -Filter 'lcov-batch-*.info'|Sort-Object Name)){
      if(-not(Test-Path $merged)){Copy-Item $part.FullName $merged}else{Get-Content $part.FullName|Where-Object{$_ -ne 'TN:'}|Add-Content $merged}
    }
  }
  foreach($isolated in @(
    @{Name='startup';File='test/features/startup/views/startup_screen_test.dart';Coverage=$true},
    @{Name='system-admin';File='test/screens/system_admin/system_admin_snapshot_tabs_test.dart';Coverage=$true},
    @{Name='native-transfer';File='test/services/network/transfer_transport_test.dart';Coverage=$false}
  )){
    $isolatedArguments=@('test','--no-pub','--reporter','compact','--fail-fast','--timeout','60s','--concurrency',"$FlutterConcurrency",'--total-shards',"$AppShards",'--shard-index',"$Shard")
    if($coverage-and$isolated.Coverage){$isolatedArguments+=@('--coverage','--coverage-path',(Join-Path $coverageDir "isolated-$($isolated.Name)-lcov.info"))}
    $isolatedArguments+=$isolated.File
    Invoke-CommandWithTimeout flutter $isolatedArguments $AppTimeout $directory @{HTTP_PROXY='';HTTPS_PROXY='';ALL_PROXY='';NO_PROXY='localhost,127.0.0.1,::1'}
  }
}
function JobCoverage{$arguments=@('run','tool/check_coverage.dart','--minimum=90');foreach($shard in 0..($AppShards-1)){$coverageDir=Join-Path $LogDir "coverage\shard-$shard";$arguments+="--file=$(Join-Path $coverageDir 'lcov.info')";foreach($name in @('startup','system-admin')){$arguments+="--file=$(Join-Path $coverageDir "isolated-$name-lcov.info")"}};$arguments+='--source-root=lib';$coverageBaseRef=if($env:FULL_TEST_COVERAGE_BASE_REF){$env:FULL_TEST_COVERAGE_BASE_REF}elseif($env:CI_BASE_SHA){$env:CI_BASE_SHA}elseif($env:GITHUB_BASE_SHA){$env:GITHUB_BASE_SHA}else{$env:GITHUB_EVENT_BEFORE};if($coverageBaseRef){$arguments+="--base-ref=$coverageBaseRef"};Write-Host 'Enforce Full App coverage (90% minimum)';Cmd dart $arguments (Join-Path $root 'apps\ssh_mobile_full')}
function JobAndroid{
  Cmd flutter @('build','apk','--debug','--no-pub') (Join-Path $root 'apps\ssh_mobile_full')
  Cmd (Join-Path $root 'apps\ssh_mobile_full\android\gradlew.bat') @(':android_server_widgets:verifyWidgetCoverage','--no-daemon','--console=plain') (Join-Path $root 'apps\ssh_mobile_full\android')
  Cmd (Join-Path $root 'apps\ssh_mobile_full\android\gradlew.bat') @(':app:assembleDebugAndroidTest','--no-daemon','--console=plain') (Join-Path $root 'apps\ssh_mobile_full\android')
}
function JobWindows{Cmd flutter @('build','windows','--no-pub') (Join-Path $root 'apps\ssh_mobile_full')}
function JobTerminal{Cmd flutter @('build','windows','--debug','--no-pub') (Join-Path $root 'apps\ssh_mobile_terminal')}
function JobE2E{Script (Join-Path $PSScriptRoot '..\e2e\client_backend_e2e.ps1') @{Mode='smoke';TempRoot=$temp}}
