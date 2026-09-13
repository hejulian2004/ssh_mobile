import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/app/screen_share_peer_arbitration.dart';

void main() {
  test('arbitrates crossed intents without relying on realtime IDs', () async {
    final registry = AppScreenSharePeerArbitrationRegistry();
    var replaced = false;

    expect(
      registry.acquire(
        remotePeerId: 'peer-remote',
        initiatorPeerId: 'peer-b',
        operationId: 'operation-z',
        onReplaced: () => replaced = true,
      ),
      isTrue,
    );
    expect(
      registry.acquire(
        remotePeerId: 'peer-remote',
        initiatorPeerId: 'peer-a',
        operationId: 'operation-a',
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(replaced, isTrue);

    registry.release(
      remotePeerId: 'peer-remote',
      initiatorPeerId: 'peer-b',
      operationId: 'operation-z',
    );
    expect(
      registry.acquire(
        remotePeerId: 'peer-remote',
        initiatorPeerId: 'peer-c',
        operationId: 'operation-c',
      ),
      isFalse,
    );
  });
}
