import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../fakes/lan_share_test_fakes.dart';

part 'lan_receiver_coordinator_incoming_tests.dart';
part 'lan_receiver_coordinator_lifecycle_tests.dart';
part 'lan_receiver_coordinator_observation_tests.dart';
part 'lan_receiver_coordinator_relay_tests.dart';
part 'lan_receiver_coordinator_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;

  setUp(() {
    originalPathProvider = PathProviderPlatform.instance;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
  });

  _registerReceiverLifecycleTests();
  _registerReceiverObservationTests();
  _registerReceiverRelayTests();
  _registerReceiverIncomingTests();
}
