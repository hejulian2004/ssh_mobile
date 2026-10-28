part of '../lan_share_database.dart';

/// LAN 传输历史的查询和状态更新 DAO。
@DriftAccessor(tables: [LanTransferRecords])
class LanHistoryDao extends DatabaseAccessor<LanShareDatabase>
    with _$LanHistoryDaoMixin {
  LanHistoryDao(super.db);

  /// 按创建时间倒序读取历史。
  Future<List<LanTransferRecord>> getAllRecords() {
    return (select(lanTransferRecords)..orderBy([
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
        .get();
  }

  /// 监听历史变化。
  Stream<List<LanTransferRecord>> watchAllRecords() {
    return (select(lanTransferRecords)..orderBy([
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
        .watch();
  }

  /// 读取一条历史记录。
  Future<LanTransferRecord?> getRecord(String id) {
    return (select(
      lanTransferRecords,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 插入或替换一条历史记录。
  Future<int> insertRecord(LanTransferRecordsCompanion record) {
    return into(
      lanTransferRecords,
    ).insert(record, mode: InsertMode.insertOrReplace);
  }

  /// 修复或升级敏感字段的加密表示。
  Future<bool> updateSensitiveFields(
    String id, {
    required Value<String?> textContent,
    required Value<String?> manifestJson,
    required Value<String?> sftpRemotePath,
  }) async {
    final count =
        await (update(lanTransferRecords)..where((t) => t.id.equals(id))).write(
          LanTransferRecordsCompanion(
            textContent: textContent,
            manifestJson: manifestJson,
            sftpRemotePath: sftpRemotePath,
          ),
        );
    return count > 0;
  }

  /// 更新传输状态和可选进度元数据。
  Future<bool> updateRecordStatus(
    String id,
    String status, {
    int? bytesTransferred,
    bool? isRecalled,
    String? localPath,
    String? transport,
    String? routeType,
    int? avgRtt,
    int? bytesTotal,
    String? failureReason,
    bool clearFailureReason = false,
  }) async {
    final count =
        await (update(lanTransferRecords)..where((t) => t.id.equals(id))).write(
          LanTransferRecordsCompanion(
            status: Value(status),
            bytesTransferred: bytesTransferred != null
                ? Value(bytesTransferred)
                : const Value.absent(),
            isRecalled: isRecalled != null
                ? Value(isRecalled)
                : const Value.absent(),
            localPath: localPath != null
                ? Value(localPath)
                : const Value.absent(),
            transport: transport != null
                ? Value(transport)
                : const Value.absent(),
            routeType: routeType != null
                ? Value(routeType)
                : const Value.absent(),
            avgRtt: avgRtt != null ? Value(avgRtt) : const Value.absent(),
            bytesTotal: bytesTotal != null
                ? Value(bytesTotal)
                : const Value.absent(),
            failureReason: failureReason != null
                ? Value(failureReason)
                : clearFailureReason
                ? const Value<String?>(null)
                : const Value.absent(),
          ),
        );
    return count > 0;
  }

  /// 删除一条历史记录。
  Future<int> deleteRecord(String id) =>
      (delete(lanTransferRecords)..where((t) => t.id.equals(id))).go();

  /// 删除指定时间之前的历史记录。
  Future<int> deleteExpiredRecords(int expiredBeforeTimestamp) => (delete(
    lanTransferRecords,
  )..where((t) => t.createdAt.isSmallerThanValue(expiredBeforeTimestamp))).go();

  /// 清空全部历史记录。
  Future<int> clearAllRecords() => delete(lanTransferRecords).go();
}
