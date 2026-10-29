part of '../connection_database.dart';

/// Connection 表的最小 DAO 边界，避免 Repository 直接散落 SQL 操作。
@DriftAccessor(tables: [ConnectionTable])
class ConnectionDao extends DatabaseAccessor<ConnectionDatabase>
    with _$ConnectionDaoMixin {
  /// 创建由 Drift 注入数据库的 DAO。
  ConnectionDao(super.attachedDatabase);

  /// 订阅持久化目录；只拥有查询订阅，不拥有数据库生命周期。
  Stream<List<ConnectionTableData>> watchAll() =>
      (select(connectionTable)..orderBy([
            (table) => OrderingTerm(expression: table.sortOrder),
            (table) => OrderingTerm(expression: table.createdAt),
          ]))
          .watch();

  /// 按显式排序字段读取所有连接。
  Future<List<ConnectionTableData>> loadAll() {
    return (select(connectionTable)..orderBy([
          (table) => OrderingTerm(expression: table.sortOrder),
          (table) => OrderingTerm(expression: table.createdAt),
        ]))
        .get();
  }

  /// 查询一个连接。
  Future<ConnectionTableData?> findById(String id) {
    return (select(
      connectionTable,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
  }

  /// 插入或替换一个结构记录。
  Future<void> save(ConnectionTableCompanion entry) async {
    await into(connectionTable).insertOnConflictUpdate(entry);
  }

  /// 删除一个结构记录并返回是否命中。
  Future<bool> deleteById(String id) async {
    final count = await (delete(
      connectionTable,
    )..where((table) => table.id.equals(id))).go();
    return count > 0;
  }

  /// 更新排序值，供 Repository 在事务中批量调用。
  Future<void> updateSortOrder(String id, int sortOrder) async {
    await (update(connectionTable)..where((table) => table.id.equals(id)))
        .write(ConnectionTableCompanion(sortOrder: Value(sortOrder)));
  }

  /// 更新 Host Key 元数据和修改时间。
  Future<void> updateHostKey({
    required String id,
    required String? algorithm,
    required String? fingerprint,
    required int? trustedAt,
    required int updatedAt,
  }) async {
    await (update(
      connectionTable,
    )..where((table) => table.id.equals(id))).write(
      ConnectionTableCompanion(
        hostKeyAlgorithm: Value(algorithm),
        hostKeyFingerprint: Value(fingerprint),
        hostKeyTrustedAt: Value(trustedAt),
        updatedAt: Value(updatedAt),
      ),
    );
  }
}
