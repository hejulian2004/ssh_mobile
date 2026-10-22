import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/app/screen_share_peer_arbitration.dart';

void main() {
  test(
    'accepted sharing rejects new intents from any peer without replacement',
    () async {
      final registry = AppScreenSharePeerArbitrationRegistry();
      addTearDown(registry.dispose);
      var replaced = false;
      expect(
        registry.acquire(
          remotePeerId: 'peer-a',
          initiatorPeerId: 'local',
          operationId: 'op-z',
          onReplaced: () => replaced = true,
        ),
        isTrue,
      );
      expect(
        registry.activate(
          remotePeerId: 'peer-a',
          initiatorPeerId: 'local',
          operationId: 'op-z',
        ),
        isTrue,
      );
      expect(registry.isBusy, isTrue);
      expect(
        registry.acquire(
          remotePeerId: 'peer-a',
          initiatorPeerId: 'earlier',
          operationId: 'op-a',
        ),
        isFalse,
      );
      expect(
        registry.acquire(
          remotePeerId: 'peer-b',
          initiatorPeerId: 'peer-b',
          operationId: 'op-b',
        ),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(replaced, isFalse);
      registry.release(
        remotePeerId: 'peer-a',
        initiatorPeerId: 'earlier',
        operationId: 'op-a',
      );
      expect(registry.isBusy, isTrue);
      registry.release(
        remotePeerId: 'peer-a',
        initiatorPeerId: 'local',
        operationId: 'op-z',
      );
      expect(registry.isBusy, isFalse);
      expect(
        registry.acquire(
          remotePeerId: 'peer-b',
          initiatorPeerId: 'peer-b',
          operationId: 'op-b',
        ),
        isTrue,
      );
    },
  );

  test(
    'activation is exact, idempotent and exclusive across pending peers',
    () {
      final registry = AppScreenSharePeerArbitrationRegistry();
      addTearDown(registry.dispose);
      registry.acquire(
        remotePeerId: 'a',
        initiatorPeerId: 'local',
        operationId: 'op-a',
      );
      registry.acquire(
        remotePeerId: 'b',
        initiatorPeerId: 'local',
        operationId: 'op-b',
      );
      expect(
        registry.activate(
          remotePeerId: 'a',
          initiatorPeerId: 'wrong',
          operationId: 'op-a',
        ),
        isFalse,
      );
      var changes = 0;
      registry.addListener(() => changes++);
      expect(
        registry.activate(
          remotePeerId: 'a',
          initiatorPeerId: 'local',
          operationId: 'op-a',
        ),
        isTrue,
      );
      expect(
        registry.activate(
          remotePeerId: 'a',
          initiatorPeerId: 'local',
          operationId: 'op-a',
        ),
        isTrue,
      );
      expect(
        registry.activate(
          remotePeerId: 'b',
          initiatorPeerId: 'local',
          operationId: 'op-b',
        ),
        isFalse,
      );
      expect(changes, 1);
      registry.release(
        remotePeerId: 'a',
        initiatorPeerId: 'local',
        operationId: 'op-a',
      );
      expect(changes, 2);
      expect(
        registry.activate(
          remotePeerId: 'b',
          initiatorPeerId: 'local',
          operationId: 'op-b',
        ),
        isTrue,
      );
    },
  );

  test('arbitrates crossed intents without relying on realtime IDs', () async {
    final registry = AppScreenSharePeerArbitrationRegistry();
    addTearDown(registry.dispose);
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
