import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'public directory stream observes persisted add, rename and removal without credentials',
    () async {
      final database = ConnectionDatabase.forTesting(NativeDatabase.memory());
      final repository = DriftConnectionRepository(database: database);
      final changes = StreamIterator(
        (repository as ConnectionCatalogChanges).watchConnections(),
      );
      try {
        expect(await changes.moveNext(), isTrue);
        expect(changes.current, isEmpty);
        final config = ConnectionConfig(
          id: 'server-a',
          name: 'Compute A',
          host: 'example.invalid',
          username: 'fixture-user',
          password: 'fixture-only',
        );
        await repository.addConnection(config);
        expect(await changes.moveNext(), isTrue);
        expect(changes.current.single.name, 'Compute A');
        expect(changes.current.single.password, isNull);
        expect(() => changes.current.clear(), throwsUnsupportedError);
        await repository.updateConnection(config.copyWith(name: 'Compute B'));
        expect(await changes.moveNext(), isTrue);
        expect(changes.current.single.name, 'Compute B');
        await repository.deleteConnection('server-a');
        expect(await changes.moveNext(), isTrue);
        expect(changes.current, isEmpty);
      } finally {
        await changes.cancel();
        await database.dispose();
      }
    },
  );
}
