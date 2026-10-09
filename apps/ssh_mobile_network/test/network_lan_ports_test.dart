import 'dart:io';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile_network/lan/network_control_executor.dart';
import 'package:ssh_mobile_network/lan/network_lan_identity.dart';
import 'package:ssh_mobile_network/lan/network_lan_keys.dart';
import 'package:ssh_mobile_network/lan/network_lan_ports.dart';
import 'package:ssh_mobile_network/lan/network_lan_protection.dart';
import 'package:ssh_mobile_network/lan/network_lan_settings.dart';
import 'package:ssh_mobile_network/lan/network_lan_strings.dart';

import 'support/memory_secret_store.dart';

void main() {
  test('storage keys do not reuse Full App key names', () {
    const owned = <String>[
      NetworkLanStorageKeys.deviceId,
      NetworkLanStorageKeys.deviceAlias,
      NetworkLanStorageKeys.relayEndpoint,
      NetworkLanStorageKeys.ed25519Seed,
      NetworkLanStorageKeys.x25519Seed,
      NetworkLanStorageKeys.dataProtectionKey,
    ];
    const fullApp = <String>[
      'network_quic_ed25519_seed_v1',
      'network_x25519_seed_v1',
      'data_protection_key_v1',
      'lan_device_id',
      'lan_device_alias',
    ];
    expect(owned.toSet().length, owned.length);
    expect(owned.toSet().intersection(fullApp.toSet()), isEmpty);
  });

  test('page strings cover both languages', () {
    final chinese = _read(const NetworkLanStrings(LanShareLanguage.zh));
    final english = _read(const NetworkLanStrings(LanShareLanguage.en));
    expect(chinese.values, everyElement(isNotEmpty));
    expect(english.values, everyElement(isNotEmpty));
    expect(chinese['lanShare'], '网络传输');
    expect(english['lanShare'], 'Network Transfer');
    expect(chinese['lanShareDeviceList'], '设备列表');
    expect(chinese['lanShareTransferHistory'], '传输历史');
    expect(chinese['lanShareInitializationFailed'], '局域网快传初始化失败。');
    expect(chinese['isEnglish'], 'false');
    expect(english['isEnglish'], 'true');
    expect(chinese['retry'], '重试');
    expect(chinese['filePreviewTooLargeHint'], contains('1 KB'));
    expect(english['filePreviewTooLargeHintMb'], contains('1 MB'));
    expect(chinese['networkIncomingTransferDescription'], contains('设备 peer'));
  });

  test('settings persist identity and reject a non-HTTPS relay', () async {
    final secrets = MemorySecretStore();
    final settings = NetworkLanSettings(secrets: secrets);
    var notifications = 0;
    settings.addListener(() => notifications++);

    final first = settings.ensureLanIdentity();
    final second = settings.ensureLanIdentity();
    await Future.wait([first, second]);

    expect(
      settings.lanDeviceId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(settings.lanDeviceAlias, '本机');
    expect(settings.receiverEnabled, isTrue);
    expect(settings.relayPort, 443);
    expect(notifications, greaterThan(0));

    await expectLater(
      settings.setRelayEndpoint('http://relay.example'),
      throwsArgumentError,
    );
    await expectLater(
      settings.setRelayEndpoint('https://user:pass@relay.example'),
      throwsArgumentError,
    );
    await expectLater(
      settings.setRelayEndpoint('https://relay.example/path'),
      throwsArgumentError,
    );
    await expectLater(
      settings.setRelayServer(host: '', port: 443),
      throwsArgumentError,
    );
    await settings.setRelayServer(host: 'relay.example', port: 8443);
    expect(settings.relayEndpoint, 'https://relay.example:8443');
    expect(settings.relayHost, 'relay.example');
    expect(settings.relayPort, 8443);

    await settings.setLanDeviceAlias('Desk');
    final reloaded = NetworkLanSettings(secrets: secrets);
    await reloaded.ensureLanIdentity();
    expect(reloaded.lanDeviceId, settings.lanDeviceId);
    expect(reloaded.lanDeviceAlias, 'Desk');
    expect(reloaded.relayEndpoint, 'https://relay.example:8443');

    await settings.setRelayEndpoint('');
    expect(settings.relayEndpoint, isEmpty);
    await settings.setLanDeviceAlias('Desk');
    settings.dispose();
    settings.dispose();
    reloaded.dispose();

    final ignored = NetworkLanSettings(
      secrets: MemorySecretStore()
        ..values[NetworkLanStorageKeys.relayEndpoint] = 'http://bad.example',
      language: LanShareLanguage.en,
    );
    await ignored.ensureLanIdentity();
    expect(ignored.relayEndpoint, isEmpty);
    expect(ignored.isEnglish, isTrue);
    expect(ignored.strings.lanShare, 'Network Transfer');
    ignored.dispose();
  });

  test('identity is stable and a corrupt seed is not replaced', () async {
    final secrets = MemorySecretStore();
    final identity = NetworkLanIdentity(secrets);
    final first = await identity.loadOrCreate();
    final second = await identity.loadOrCreate();

    expect(first.privateSeed, hasLength(32));
    expect(first.publicKey, hasLength(32));
    expect(first.x25519PrivateSeed, hasLength(32));
    expect(first.x25519PublicKey, hasLength(32));
    expect(second.publicKey, first.publicKey);
    expect(second.privateSeed, first.privateSeed);
    final reloaded = await NetworkLanIdentity(secrets).loadOrCreate();
    expect(reloaded.publicKey, first.publicKey);
    expect(reloaded.x25519PublicKey, first.x25519PublicKey);
    expect(
      secrets.values.keys,
      containsAll([
        NetworkLanStorageKeys.ed25519Seed,
        NetworkLanStorageKeys.x25519Seed,
      ]),
    );

    final corrupt = MemorySecretStore()
      ..values[NetworkLanStorageKeys.ed25519Seed] = 'abcd';
    await expectLater(
      NetworkLanIdentity(corrupt).loadOrCreate(),
      throwsA(isA<StateError>()),
    );
    expect(corrupt.values[NetworkLanStorageKeys.ed25519Seed], 'abcd');
    expect(
      corrupt.values.containsKey(NetworkLanStorageKeys.x25519Seed),
      isFalse,
    );
  });

  test('data protection round-trips and rejects foreign ciphertext', () async {
    final secrets = MemorySecretStore();
    final protection = NetworkLanProtection(secrets);
    final first = await protection.encryptString('history-note');
    final second = await protection.encryptString('history-note');

    expect(first.startsWith(NetworkLanProtection.prefix), isTrue);
    expect(first.contains('history-note'), isFalse);
    expect(first, isNot(second));
    expect(await protection.decryptString(first), 'history-note');
    expect(
      await NetworkLanProtection(secrets).decryptString(first),
      'history-note',
    );
    expect(
      await protection.encryptString(''),
      '${NetworkLanProtection.prefix}.',
    );
    expect(
      await protection.decryptString('${NetworkLanProtection.prefix}.'),
      isEmpty,
    );
    expect(protection.isEncrypted('ssh-mobile-v1:abc'), isFalse);
    expect(
      await protection.decryptString('ssh-mobile-v1:abc'),
      'ssh-mobile-v1:abc',
    );

    final broken = '${first.substring(0, first.length - 2)}aa';
    await expectLater(protection.decryptString(broken), throwsA(anything));

    final invalid = MemorySecretStore()
      ..values[NetworkLanStorageKeys.dataProtectionKey] = 'YQ==';
    await expectLater(
      NetworkLanProtection(invalid).encryptString('x'),
      throwsA(isA<StateError>()),
    );
    expect(invalid.values[NetworkLanStorageKeys.dataProtectionKey], 'YQ==');
  });

  test('logs drop secret material and screen share stays closed', () async {
    final logger = AppLoggerImpl();
    final port = NetworkLanLogger(logger);
    port.info('receiver ready');
    port.error(
      'enrollment failed',
      error: StateError('token=abc'),
      details: 'password=hunter2',
    );

    final records = logger.buffer.oldestFirst;
    expect(records.first.message, 'receiver ready');
    expect(records.last.message, 'redacted');
    expect(records.last.details, isNull);
    expect(records.last.error, isNull);
    expect(
      records.map((record) => '${record.message} ${record.details}').join(),
      isNot(contains('hunter2')),
    );
    expect(
      records.map((record) => '${record.message} ${record.error}').join(),
      isNot(contains('token=abc')),
    );
    await logger.dispose();

    const screenShare = NetworkLanScreenShare();
    expect(screenShare.canShareWith('peer'), isFalse);
    expect(screenShare.canReceiveScreenShareFrom('peer'), isFalse);
    await expectLater(
      screenShare.startScreenShare('peer'),
      throwsA(isA<StateError>()),
    );
    expect(await const NetworkLanAccess().borrowFacade(), isNull);
  });

  test('control executor returns a bounded response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      final body = await request.fold<List<int>>(
        <int>[],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      request.response.statusCode = body.isEmpty ? 204 : 200;
      request.response.add(body);
      await request.response.close();
    });
    final executor = const NetworkControlExecutor(maxResponseBytes: 4);
    final uri = Uri(
      scheme: 'http',
      host: server.address.host,
      port: server.port,
      path: '/healthz',
    );

    final empty = await executor.execute(SdkRequest(method: 'GET', uri: uri));
    expect(empty.statusCode, 204);

    final posted = await executor.execute(
      SdkRequest(method: 'POST', uri: uri, body: Uint8List.fromList([1, 2])),
    );
    expect(posted.statusCode, 200);
    expect(posted.body, [1, 2]);
    await expectLater(
      executor.execute(
        SdkRequest(
          method: 'POST',
          uri: uri,
          body: Uint8List.fromList([1, 2, 3, 4, 5]),
        ),
      ),
      throwsFormatException,
    );
  });
}

Map<String, String> _read(NetworkLanStrings strings) {
  return {
    'isEnglish': '${strings.isEnglish}',
    'accept': strings.accept,
    'cancel': strings.cancel,
    'close': strings.close,
    'connected': strings.connected,
    'copy': strings.copy,
    'disconnected': strings.disconnected,
    'delete': strings.delete,
    'deleteConnectionConfirm': strings.deleteConnectionConfirm,
    'externalPreviewContentBlocked': strings.externalPreviewContentBlocked,
    'filePreviewRenderFailed': strings.filePreviewRenderFailed,
    'filePreviewRenderFailedHint': strings.filePreviewRenderFailedHint,
    'filePreviewResourceLimit': strings.filePreviewResourceLimit,
    'filePreviewResourceLimitHint': strings.filePreviewResourceLimitHint,
    'filePreviewTooLarge': strings.filePreviewTooLarge,
    'filePreviewTooLargeHint': strings.filePreviewTooLargeHint(1024),
    'filePreviewTooLargeHintMb': strings.filePreviewTooLargeHint(1024 * 1024),
    'hostAddress': strings.hostAddress,
    'htmlPreviewUnavailable': strings.htmlPreviewUnavailable,
    'htmlPreviewUnavailableHint': strings.htmlPreviewUnavailableHint,
    'imagePreviewLabel': strings.imagePreviewLabel,
    'invalidPort': strings.invalidPort,
    'loadingFilePreview': strings.loadingFilePreview,
    'moreActions': strings.moreActions,
    'networkIncomingTransferDescription': strings
        .networkIncomingTransferDescription('peer', 'a.txt', '1 KB'),
    'networkIncomingTransferTitle': strings.networkIncomingTransferTitle,
    'port': strings.port,
    'reject': strings.reject,
    'retry': strings.retry,
    'save': strings.save,
    'unknown': strings.unknown,
    'unsupportedPreview': strings.unsupportedPreview,
    'unsupportedPreviewTitle': strings.unsupportedPreviewTitle,
    'lanCameraPermission': strings.lanCameraPermission,
    'lanDeviceAlias': strings.lanDeviceAlias,
    'lanDeviceId': strings.lanDeviceId,
    'lanNotificationPermission': strings.lanNotificationPermission,
    'lanPermissions': strings.lanPermissions,
    'lanRelayClear': strings.lanRelayClear,
    'lanRelayConnect': strings.lanRelayConnect,
    'lanRelayConnecting': strings.lanRelayConnecting,
    'lanRelayDisconnect': strings.lanRelayDisconnect,
    'lanRelayEnrollmentRequired': strings.lanRelayEnrollmentRequired,
    'lanRelayEnrollmentToken': strings.lanRelayEnrollmentToken,
    'lanRelayEnrollmentTokenHint': strings.lanRelayEnrollmentTokenHint,
    'lanRelayFailed': strings.lanRelayFailed,
    'lanRelayServer': strings.lanRelayServer,
    'lanRouteDirect': strings.lanRouteDirect,
    'lanRouteRelay': strings.lanRouteRelay,
    'lanRouteUnknown': strings.lanRouteUnknown,
    'lanShare': strings.lanShare,
    'lanShareChatInputHint': strings.lanShareChatInputHint,
    'lanShareClearChatHistory': strings.lanShareClearChatHistory,
    'lanShareClipboard': strings.lanShareClipboard,
    'lanShareCopyAll': strings.lanShareCopyAll,
    'lanShareDeleteMessage': strings.lanShareDeleteMessage,
    'lanShareDeviceList': strings.lanShareDeviceList,
    'lanShareDeviceOfflineHint': strings.lanShareDeviceOfflineHint,
    'lanShareDragDropHint': strings.lanShareDragDropHint,
    'lanShareExport': strings.lanShareExport,
    'lanShareFileExpired': strings.lanShareFileExpired,
    'lanShareForgetConfirm': strings.lanShareForgetConfirm,
    'lanShareForgetConfirmMessage': strings.lanShareForgetConfirmMessage,
    'lanShareForgetDevice': strings.lanShareForgetDevice,
    'lanShareInitializationFailed': strings.lanShareInitializationFailed,
    'lanShareInvalidAddress': strings.lanShareInvalidAddress,
    'lanShareAddressAmbiguous': strings.lanShareAddressAmbiguous,
    'lanShareAddressUnavailable': strings.lanShareAddressUnavailable,
    'lanShareAddressOverrideStale': strings.lanShareAddressOverrideStale,
    'lanShareNoDevices': strings.lanShareNoDevices,
    'lanShareNoDevicesRefreshHint': strings.lanShareNoDevicesRefreshHint,
    'lanShareNoHistory': strings.lanShareNoHistory,
    'lanShareOffline': strings.lanShareOffline,
    'lanShareOfflineReauthHint': strings.lanShareOfflineReauthHint,
    'lanShareOnline': strings.lanShareOnline,
    'lanShareOpenBrowser': strings.lanShareOpenBrowser,
    'lanSharePinMismatch': strings.lanSharePinMismatch,
    'lanSharePinPairing': strings.lanSharePinPairing,
    'lanSharePinPrompt': strings.lanSharePinPrompt,
    'lanShareRadarHint': strings.lanShareRadarHint,
    'lanShareRadarStoppedHint': strings.lanShareRadarStoppedHint,
    'lanShareReauthenticate': strings.lanShareReauthenticate,
    'lanShareRecall': strings.lanShareRecall,
    'lanShareRecalled': strings.lanShareRecalled,
    'lanShareSavedToDownloads': strings.lanShareSavedToDownloads,
    'lanShareSavedToGallery': strings.lanShareSavedToGallery,
    'lanShareSaveFailed': strings.lanShareSaveFailed,
    'lanShareScan': strings.lanShareScan,
    'lanShareScanning': strings.lanShareScanning,
    'lanShareScanOrAdd': strings.lanShareScanOrAdd,
    'lanShareScanQrCode': strings.lanShareScanQrCode,
    'lanShareSelectFile': strings.lanShareSelectFile,
    'lanShareSelectImage': strings.lanShareSelectImage,
    'lanShareSelectToCopy': strings.lanShareSelectToCopy,
    'lanShareSelectVideo': strings.lanShareSelectVideo,
    'lanShareSendToNearby': strings.lanShareSendToNearby,
    'lanShareSettings': strings.lanShareSettings,
    'lanShareTransferHistory': strings.lanShareTransferHistory,
    'lanShareWebShare': strings.lanShareWebShare,
    'lanShareWebShareHint': strings.lanShareWebShareHint,
  };
}
