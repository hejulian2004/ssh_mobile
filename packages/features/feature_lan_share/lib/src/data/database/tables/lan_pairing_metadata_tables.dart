part of '../lan_share_database.dart';

/// 不含密钥、PIN、Token 的对端展示元数据。
class LanPairingMetadata extends Table {
  TextColumn get deviceId => text()();
  TextColumn get alias => text()();
  TextColumn get deviceType => text().withDefault(const Constant('mobile'))();
  TextColumn get ip => text().nullable()();
  IntColumn get port => integer().nullable()();

  /// Latest locally observed came-online transition, in Unix milliseconds.
  IntColumn get lastSeen => integer()();

  @override
  Set<Column<Object>> get primaryKey => {deviceId};
}
