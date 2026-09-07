# Service and workspace CI jobs. Dot-sourced by full_test.ps1.

function JobBootstrap{if(-not(Need @('dart','flutter','npm','cargo','go','python'))){exit$gap};Cmd dart @('pub','get');Cmd flutter @('pub','get') (Join-Path $root 'packages\infrastructure\ssh_mobile_network_native');Cmd flutter @('pub','get') (Join-Path $root 'apps\ssh_mobile_full');Cmd npm @('ci') (Join-Path $root 'front');Cmd cargo @('fetch','--locked') (Join-Path $root 'native\network_core');Cmd go @('mod','download') (Join-Path $root 'relay')}
function JobFront{if(-not(Need @('npm'))){exit$gap};$directory=Join-Path $root 'front';foreach($task in @('typecheck','typecheck:tests','lint','test:run','build')){Cmd npm @('run',$task) $directory};if($NoDocker-or-not(Need @('docker'))){exit$gap};&docker info*>$null;if($LASTEXITCODE-ne0){exit$gap};Cmd docker @('build','-t',"ssh-mobile-relay-front:$RunId",$directory)}
function JobAdmin{Script (Join-Path $PSScriptRoot '..\contracts\admin_api_contract.ps1') @{TempRoot=$temp}}
function JobTelemetry{Script (Join-Path $PSScriptRoot '..\contracts\telemetry_contract.ps1') @{TempRoot=$temp}}
function JobNative{
  if(-not(Need @('cargo'))){exit$gap}
  $directory=Join-Path $root 'native\network_core'
  Cmd cargo @('fmt','--all','--','--check') $directory
  Cmd cargo @('test','--workspace','--locked','--','--test-threads=1') $directory
  Cmd cargo @('clippy','--workspace','--all-targets','--locked','--','-D','warnings') $directory
  Write-Host 'ENVIRONMENT GAP: Linux host-network coturn is unavailable on the native Windows gate; TURN fallback was not run.'
  exit$gap
}
function JobSdk{if(-not(Need @('dart','flutter'))){exit$gap};$scopes=@('network_sdk','network_transport','realtime_media','ssh_mobile_network_native');Melos 'dart format --output=none --set-exit-if-changed lib test' $scopes;Melos 'flutter analyze --no-fatal-infos --no-pub' $scopes;Melos "flutter test --no-pub --concurrency $MelosTestConcurrency" $scopes}
function JobLanNetworkV2{
  if(-not(Need @('dart','flutter','cargo'))){exit$gap}
  $featureDirectory=Join-Path $root 'packages\features\feature_lan_share'
  $featureTests=@(
    'test/services/lan_peer_trust_v2_test.dart',
    'test/features/lan_native_peer_registry_v2_test.dart',
    'test/features/lan_network_v2_acceptance_matrix_test.dart',
    'test/features/network_incoming_transfer_host_test.dart',
    'test/services/lan_storage_service_test.dart',
    'test/services/lan_pairing_protocol_v2_test.dart',
    'test/services/lan_peer_trust_identity_v2_test.dart',
    'test/services/lan_peer_presentation_models_test.dart',
    'test/services/lan_native_transfer_coordinator_v2_test.dart',
    'test/services/lan_http_v2_route_test.dart',
    'test/services/lan_web_share_request_handler_test.dart'
  )
  $sdkDirectory=Join-Path $root 'packages\infrastructure\network_sdk'
  $sdkTests=@(
    'test/network_facade_v2_refactor_test.dart',
    'test/network_sdk_contract_test.dart',
    'test/network_v2_contract_test.dart',
    'test/network_v2_facade_test.dart'
  )
  $appDirectory=Join-Path $root 'apps\ssh_mobile_full'
  $appTests=@(
    'test/app/network_runtime_ownership_v2_test.dart',
    'test/services/network/network_identity_service_test.dart',
    'test/services/network/network_protocol_v2_codec_test.dart',
    'test/features/lan_share/lan_e2e_encryption_test.dart',
    'test/features/lan_share/lan_pairing_v2_contract_test.dart',
    'test/features/lan_share/lan_storage_safety_v2_test.dart',
    'test/features/lan_share/lan_runtime_restart_transfer_v2_test.dart',
    'test/services/lan_web_share_safety_test.dart'
  )
  $webShareTlsWorker='tool/lan_web_share_tls_process.dart'
  $missing=@($featureTests|Where-Object{-not(Test-Path (Join-Path $featureDirectory $_))}|ForEach-Object{"packages/features/feature_lan_share/$_"})
  $missing+=@($sdkTests|Where-Object{-not(Test-Path (Join-Path $sdkDirectory $_))}|ForEach-Object{"packages/infrastructure/network_sdk/$_"})
  $missing+=@($appTests|Where-Object{-not(Test-Path (Join-Path $appDirectory $_))}|ForEach-Object{"apps/ssh_mobile_full/$_"})
  $webShareWorkerDirectory=Join-Path $root 'packages\features\feature_lan_share'
  if(-not(Test-Path (Join-Path $webShareWorkerDirectory $webShareTlsWorker))){$missing+="packages/features/feature_lan_share/$webShareTlsWorker"}
  if($missing.Count){$missing|ForEach-Object{Write-Error "MISSING LAN V2 acceptance test: $_"};throw'LAN V2 acceptance manifest is incomplete.'}
  Cmd flutter (@('test','--no-pub','--no-test-assets')+$featureTests) $featureDirectory
  Cmd flutter (@('test','--no-pub','--no-test-assets')+$sdkTests) $sdkDirectory
  Cmd flutter (@('test','--no-pub','--no-test-assets')+$appTests) $appDirectory
  # Keep the real TLS listener in an ordinary Dart VM process. The boundary
  # suite above uses in-memory requests; this worker owns bindSecure and has no
  # retry/skip path that could hide a native bind stall in flutter_tester.
  Invoke-CommandWithTimeout dart @('run',$webShareTlsWorker) $AppTimeout $webShareWorkerDirectory @{HTTP_PROXY='';HTTPS_PROXY='';ALL_PROXY='';NO_PROXY='localhost,127.0.0.1,::1'}
  $nativeDirectory=Join-Path $root 'native\network_core'
  Cmd cargo @('test','-p','network-core','--locked','--lib','two_runtimes','--','--test-threads=1') $nativeDirectory
  Cmd cargo @('test','-p','network-core','--locked','--lib','receiver_runtime_restart_restores_direct_trust_without_repairing','--','--test-threads=1') $nativeDirectory
  Cmd cargo @('test','-p','network-core','--locked','--lib','peer_runtime_restart_replaces_session_and_keeps_e2ee_delivery','--','--test-threads=1') $nativeDirectory
  Cmd cargo @('test','-p','network-core','--locked','--lib','network_v2_route_auth','--','--test-threads=1') $nativeDirectory
}
function StartStorage{
  $script:mysql="ssh-mobile-full-mysql-$RunId";$script:redis="ssh-mobile-full-redis-$RunId";$script:analyticsMysql="ssh-mobile-full-analytics-mysql-$RunId";$script:analyticsRedis="ssh-mobile-full-analytics-redis-$RunId";$analyticsMysqlPassword=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant();$analyticsMysqlRootPassword=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant();$analyticsRedisPassword=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
  Cmd docker @('run','-d','--rm','--name',$mysql,'-p','127.0.0.1::3306','-e','MYSQL_ROOT_PASSWORD=root','-e','MYSQL_DATABASE=relay','-e','MYSQL_USER=relay','-e','MYSQL_PASSWORD=relay','mysql:8.4@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb')
  Cmd docker @('run','-d','--rm','--name',$redis,'-p','127.0.0.1::6379','redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf')
  Cmd docker @('run','-d','--rm','--name',$analyticsMysql,'-p','127.0.0.1::3306','-e',"MYSQL_ROOT_PASSWORD=$analyticsMysqlRootPassword",'-e','MYSQL_DATABASE=telemetry','-e','MYSQL_USER=telemetry','-e',"MYSQL_PASSWORD=$analyticsMysqlPassword",'mysql:8.4@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb')
  Cmd docker @('run','-d','--rm','--name',$analyticsRedis,'-p','127.0.0.1::6379','-e',"ANALYTICS_REDIS_PASSWORD=$analyticsRedisPassword",'redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf','sh','-ec','exec redis-server --maxmemory 64mb --maxmemory-policy noeviction --requirepass "$ANALYTICS_REDIS_PASSWORD"')
  $mysqlPort=((&docker port $mysql '3306/tcp'|Select-Object -First 1)-replace'^.*:','');$redisPort=((&docker port $redis '6379/tcp'|Select-Object -First 1)-replace'^.*:','')
  $analyticsMysqlPort=((&docker port $analyticsMysql '3306/tcp'|Select-Object -First 1)-replace'^.*:','');$analyticsRedisPort=((&docker port $analyticsRedis '6379/tcp'|Select-Object -First 1)-replace'^.*:','')
  if($mysqlPort-notmatch'^\d+$'-or$redisPort-notmatch'^\d+$'-or$analyticsMysqlPort-notmatch'^\d+$'-or$analyticsRedisPort-notmatch'^\d+$'){throw'Docker did not publish all Relay and Analytics storage ports.'}
  $mysqlReady=$false
  foreach($i in 1..60){&docker exec $mysql mysqladmin ping -h 127.0.0.1 -urelay -prelay*>$null;if($LASTEXITCODE-eq0){$mysqlReady=$true;break};Start-Sleep 2}
  if(-not$mysqlReady){throw 'MySQL test container did not become ready.'}
  $redisReady=$false
  foreach($i in 1..30){$pong=&docker exec $redis redis-cli ping 2>$null;if($LASTEXITCODE-eq0-and$pong-eq'PONG'){$redisReady=$true;break};Start-Sleep 2}
  if(-not$redisReady){throw 'Redis test container did not become ready.'}
  $analyticsMysqlReady=$false
  foreach($i in 1..60){&docker exec $analyticsMysql mysqladmin ping -h 127.0.0.1 -utelemetry -p$analyticsMysqlPassword*>$null;if($LASTEXITCODE-eq0){$analyticsMysqlReady=$true;break};Start-Sleep 2}
  if(-not$analyticsMysqlReady){throw 'Analytics MySQL test container did not become ready.'}
  $analyticsRedisReady=$false
  foreach($i in 1..30){$pong=&docker exec $analyticsRedis redis-cli -a $analyticsRedisPassword --no-auth-warning ping 2>$null;if($LASTEXITCODE-eq0-and$pong-eq'PONG'){$analyticsRedisReady=$true;break};Start-Sleep 2}
  if(-not$analyticsRedisReady){throw 'Analytics Redis test container did not become ready.'}
  $env:RELAY_TEST_MYSQL_DSN="relay:relay@tcp(127.0.0.1:$mysqlPort)/relay?parseTime=true&loc=UTC";$env:RELAY_TEST_REDIS_URL="redis://127.0.0.1:$redisPort/0"
  $env:TELEMETRY_TEST_MYSQL_DSN="telemetry:$analyticsMysqlPassword@tcp(127.0.0.1:$analyticsMysqlPort)/telemetry?parseTime=true&loc=UTC";$env:TELEMETRY_MYSQL_DSN=$env:TELEMETRY_TEST_MYSQL_DSN;$env:TELEMETRY_TEST_REDIS_URL="redis://:$analyticsRedisPassword@127.0.0.1:$analyticsRedisPort/0";$env:TELEMETRY_REDIS_URL=$env:TELEMETRY_TEST_REDIS_URL
}
function JobRelay{
  if(-not(Need @('go','gofmt'))){exit$gap};$directory=Join-Path $root 'relay';$script:mysql='';$script:redis='';$script:analyticsMysql='';$script:analyticsRedis='';$ready=$env:RELAY_TEST_MYSQL_DSN-and$env:RELAY_TEST_REDIS_URL-and$env:TELEMETRY_TEST_MYSQL_DSN-and$env:TELEMETRY_TEST_REDIS_URL
  try{if(-not$ready-and-not$NoDocker-and(Need @('docker'))){&docker info*>$null;if($LASTEXITCODE-eq0){try{StartStorage;$ready=$true}catch{Write-Host "ENVIRONMENT GAP: Relay/Analytics MySQL/Redis test containers were not ready: $_"}}};$bad=@(&gofmt -l $directory);if($bad.Count){$bad|Write-Host;throw'Go formatting failed.'};Cmd go @('test','./...') $directory;Cmd go @('test','-race','./...') $directory;Cmd go @('vet','./...') $directory;Cmd go @('run','golang.org/x/vuln/cmd/govulncheck@v1.6.0','./...') $directory;if(-not$ready){exit$gap}}finally{if($mysql){&docker rm -f $mysql $redis $analyticsMysql $analyticsRedis*>$null}}
}
function JobProtocol{if(-not(Need @('cargo','go','python','protoc','buf','dart','flutter'))){exit$gap};Cmd protoc @('--proto_path=protocol',"--descriptor_set_out=$(Join-Path $LogDir 'network-v2.desc')",'protocol/proto/relay/v2/relay_v2.proto','protocol/proto/network/v2/network.proto');Cmd dart @('run','scripts/bash/contracts/check_network_v2_contract.dart','--test');Cmd dart @('run','scripts/bash/contracts/check_network_v2_contract.dart');Script (Join-Path $PSScriptRoot '..\contracts\relay_v2_contract.ps1') @{TempRoot=$temp};Script (Join-Path $PSScriptRoot '..\contracts\network_v2_acceptance.ps1') @{Mode='strict';TempRoot=$temp};Cmd buf @('lint') (Join-Path $root 'protocol');Cmd buf @('breaking','.','--against','../.git#ref=6ec194bb3a66a748215d3abc11d6da84bd329619,subdir=protocol','--path','proto/relay/v2/relay_v2.proto') (Join-Path $root 'protocol')}
function JobArchitecture{if(-not(Need @('dart'))){exit$gap};foreach($file in @('tool/check_agent_docs.dart','test/tool/agent_docs_check_test.dart','test/tool/ci_workflow_test.dart','test/tool/ci_production_config_test.dart','tool/check_file_sizes.dart','tool/check_telemetry_contract_generated.dart','test/tool/telemetry_contract_codegen_test.dart','tool/architecture_check.dart','tool/check_module_dependencies.dart','tool/check_resource_owners.dart','tool/compatibility_check.dart','tool/duplicate_implementation_check.dart')){Cmd dart @('run',$file)}}
function JobAppStatic{if(-not(Need @('dart','flutter','git'))){exit$gap};$directory=Join-Path $root 'apps\ssh_mobile_full';Cmd dart @('run','tool/generate_app_icons.dart') $directory;Cmd git @('diff','--exit-code','--','assets','android','ios','macos','web','windows/runner/resources/app_icon.ico') $directory;Cmd dart @('format','--output=none','--set-exit-if-changed','lib','test','tool') $directory;Cmd dart @('run','build_runner','clean') $directory;Cmd dart @('run','build_runner','build') $directory;Cmd git @('diff','--exit-code','--','lib/data/database/app_database.g.dart') $directory;Assert-AppSecurityIdentifiers;Cmd flutter @('analyze','--no-fatal-infos') $directory}
function JobCore{$scopes=@('app_core','app_ui','connection_core','ssh_core');Melos 'dart format --output=none --set-exit-if-changed lib test' $scopes;Melos 'flutter analyze --no-fatal-infos --no-pub' $scopes;Melos "flutter test --no-pub --concurrency $MelosTestConcurrency" $scopes}
function JobFeatures{
  $scopes=@('feature_ai','feature_connection','feature_developer','feature_lan_share','feature_mcp','feature_monitoring','feature_playbook','feature_rag','feature_sftp','feature_system_admin','feature_terminal','feature_webview')
  Melos 'dart format --output=none --set-exit-if-changed lib test' $scopes;Melos 'flutter analyze --no-fatal-infos --no-pub' $scopes
  $ordinaryScopes=@($scopes|Where-Object{$_-ne'feature_mcp'});Melos "flutter test --no-pub --no-test-assets --concurrency $MelosTestConcurrency" $ordinaryScopes
  $mcp=Join-Path $root 'packages\features\feature_mcp';$tests=@(Get-ChildItem (Join-Path $mcp 'test') -Recurse -Filter '*_test.dart'|ForEach-Object{[IO.Path]::GetRelativePath($mcp,$_.FullName).Replace('\','/')}|Where-Object{$WithFeatureLoopback-or$_-ne'test/services/mcp/mcp_http_server_native_test.dart'}|Sort-Object)
  if($tests.Count){Invoke-CommandWithTimeout flutter (@('test','--no-pub','--no-test-assets','--concurrency',"$MelosTestConcurrency")+$tests) $WorkspaceTestTimeout $mcp}
}
