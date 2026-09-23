// LAN Share Feature 的 App Shell 适配器测试。

import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/lan_share_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';

import 'support/feature_adapter_test_fakes.dart';

void main() {
  test(
    'LAN settings adapter maps language and forwards settings writes',
    () async {
      final settings = FakeAppSettings()..language = AppLanguage.zh;
      final adapter = AppLanShareSettingsAdapter(settings);
      var notifications = 0;
      adapter.addListener(() => notifications++);

      expect(adapter.language, lan.LanShareLanguage.zh);
      expect(adapter.isEnglish, isFalse);
      expect(adapter.strings, isA<AppLanShareStrings>());
      expect(adapter.lanDeviceId, 'device-a');
      expect(adapter.lanDeviceAlias, 'My Phone');
      expect(adapter.relayEndpoint, 'https://relay.example.test');
      expect(adapter.relayHost, 'relay.example.test');
      expect(adapter.relayPort, 443);
      expect(adapter.receiverEnabled, isTrue);

      settings.language = AppLanguage.en;
      settings.emitChange();
      expect(adapter.language, lan.LanShareLanguage.en);
      expect(adapter.isEnglish, isTrue);
      expect(notifications, 1);

      await adapter.ensureLanIdentity();
      await adapter.setLanDeviceAlias('Laptop');
      await adapter.setRelayEndpoint('https://relay2.example.test');
      await adapter.setRelayServer(host: 'relay2.example.test', port: 8443);

      expect(settings.lanAliases, <String>['Laptop']);
      expect(settings.relayEndpoints, <String>['https://relay2.example.test']);
      expect(settings.relayServers.single.host, 'relay2.example.test');
      expect(settings.relayServers.single.port, 8443);

      adapter.dispose();
      adapter.dispose();
      settings.emitChange();
      expect(notifications, 1);
    },
  );

  test('LAN strings project every interface getter for both languages', () {
    for (final language in <AppLanguage>[AppLanguage.en, AppLanguage.zh]) {
      final strings = AppLanShareStrings(AppStrings(language));

      expect(strings.isEnglish, language == AppLanguage.en);
      final values = <String>[
        strings.accept,
        strings.cancel,
        strings.close,
        strings.connected,
        strings.copy,
        strings.disconnected,
        strings.delete,
        strings.deleteConnectionConfirm,
        strings.externalPreviewContentBlocked,
        strings.filePreviewRenderFailed,
        strings.filePreviewRenderFailedHint,
        strings.filePreviewResourceLimit,
        strings.filePreviewResourceLimitHint,
        strings.filePreviewTooLarge,
        strings.filePreviewTooLargeHint(1024),
        strings.hostAddress,
        strings.htmlPreviewUnavailable,
        strings.htmlPreviewUnavailableHint,
        strings.imagePreviewLabel,
        strings.invalidPort,
        strings.loadingFilePreview,
        strings.moreActions,
        strings.networkIncomingTransferDescription('sender', 'a.bin', '2 KB'),
        strings.networkIncomingTransferTitle,
        strings.port,
        strings.reject,
        strings.retry,
        strings.save,
        strings.unknown,
        strings.unsupportedPreview,
        strings.unsupportedPreviewTitle,
        strings.lanCameraPermission,
        strings.lanDeviceAlias,
        strings.lanDeviceId,
        strings.lanNotificationPermission,
        strings.lanPermissions,
        strings.lanRelayClear,
        strings.lanRelayConnect,
        strings.lanRelayConnecting,
        strings.lanRelayDisconnect,
        strings.lanRelayEnrollmentRequired,
        strings.lanRelayEnrollmentToken,
        strings.lanRelayEnrollmentTokenHint,
        strings.lanRelayFailed,
        strings.lanRelayServer,
        strings.lanRouteDirect,
        strings.lanRouteRelay,
        strings.lanRouteUnknown,
        strings.lanShare,
        strings.lanShareChatInputHint,
        strings.lanShareClearChatHistory,
        strings.lanShareClipboard,
        strings.lanShareCopyAll,
        strings.lanShareDeleteMessage,
        strings.lanShareDeviceList,
        strings.lanShareDeviceOfflineHint,
        strings.lanShareDragDropHint,
        strings.lanShareExport,
        strings.lanShareFileExpired,
        strings.lanShareForgetConfirm,
        strings.lanShareForgetConfirmMessage,
        strings.lanShareForgetDevice,
        strings.lanShareInitializationFailed,
        strings.lanShareInvalidAddress,
        strings.lanShareAddressAmbiguous,
        strings.lanShareAddressUnavailable,
        strings.lanShareAddressOverrideStale,
        strings.lanShareNoDevices,
        strings.lanShareNoDevicesRefreshHint,
        strings.lanShareNoHistory,
        strings.lanShareOffline,
        strings.lanShareOfflineReauthHint,
        strings.lanShareOnline,
        strings.lanShareOpenBrowser,
        strings.lanSharePinMismatch,
        strings.lanSharePinPairing,
        strings.lanSharePinPrompt,
        strings.lanShareRadarHint,
        strings.lanShareRadarStoppedHint,
        strings.lanShareReauthenticate,
        strings.lanShareRecall,
        strings.lanShareRecalled,
        strings.lanShareSavedToDownloads,
        strings.lanShareSavedToGallery,
        strings.lanShareSaveFailed,
        strings.lanShareScan,
        strings.lanShareScanning,
        strings.lanShareScanOrAdd,
        strings.lanShareScanQrCode,
        strings.lanShareSelectFile,
        strings.lanShareSelectImage,
        strings.lanShareSelectToCopy,
        strings.lanShareSelectVideo,
        strings.lanShareSendToNearby,
        strings.lanShareSettings,
        strings.lanShareTransferHistory,
        strings.lanShareWebShare,
        strings.lanShareWebShareHint,
      ];

      expect(values, everyElement(isNotEmpty));
    }
  });

  test('LAN logger adapter forwards every level', () {
    final logger = FakeAppLogService();
    final adapter = AppLanShareLoggerAdapter(logger);
    final failure = ArgumentError('bad');
    final stackTrace = StackTrace.current;

    adapter.info('info', details: 'i');
    adapter.warning('warn', details: 'w');
    adapter.error('err', error: failure, stackTrace: stackTrace, details: 'e');

    expect(logger.calls, hasLength(3));
    expect(logger.calls[0].level, 'info');
    expect(logger.calls[0].details, 'i');
    expect(logger.calls[1].level, 'warning');
    expect(logger.calls[1].details, 'w');
    expect(logger.calls[2].level, 'error');
    expect(logger.calls[2].error, same(failure));
    expect(logger.calls[2].stackTrace, same(stackTrace));
    expect(logger.calls[2].details, 'e');
  });

  test(
    'data protection adapter forwards encrypt, decrypt, and detection',
    () async {
      final service = FakeDataProtectionService();
      final adapter = AppLanShareDataProtectionAdapter(service);

      expect(await adapter.encryptString('secret'), 'ssh-mobile-v1:secret');
      expect(await adapter.decryptString('ssh-mobile-v1:secret'), 'secret');
      expect(adapter.isEncrypted('ssh-mobile-v1:x'), isTrue);
      expect(adapter.isEncrypted('plain'), isFalse);
      expect(service.encryptCalls, 1);
      expect(service.decryptCalls, 1);
      expect(service.isEncryptedCalls, 2);
    },
  );

  test('network identity adapter maps the identity bundle', () async {
    final service = FakeNetworkIdentityService();
    final adapter = AppLanShareNetworkIdentityAdapter(service);

    final material = await adapter.loadOrCreate();

    expect(material.privateSeed, <int>[1]);
    expect(material.publicKey, <int>[2]);
    expect(material.x25519PrivateSeed, <int>[3]);
    expect(material.x25519PublicKey, <int>[4]);
    expect(service.loadCalls, 1);
  });

  test('network access adapter borrows the shared facade', () async {
    final facade = FakeNetworkFacade();
    final adapter = AppLanShareNetworkAccessAdapter(facade);

    expect(await adapter.borrowFacade(), same(facade));
  });
}
