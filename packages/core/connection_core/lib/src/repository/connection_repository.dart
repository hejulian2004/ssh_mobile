import '../model/connection_profile.dart';

/// 可选的只读目录订阅能力；订阅者只取消自己的订阅，不关闭数据库。
/// 每次发出不含凭据的持久化快照，包括首次读取、导入和删除。
abstract interface class ConnectionCatalogChanges {
  Stream<List<ConnectionConfig>> watchConnections();
}

/// Connection 结构数据的公共读写契约。
///
/// 该契约故意保留现有 App 的同步快照接口，方便当前 ViewModel 逐步迁移；
/// 实现必须把密码和私钥视为运行时字段，不能将它们写入结构化数据库。
abstract interface class ConnectionRepository {
  /// 当前已加载连接的不可变快照。
  List<ConnectionConfig> get connections;

  /// 初始化 Repository 并加载独立 Connection 数据库。
  Future<void> initialize();

  /// 从数据库重新加载连接并返回最新快照。
  Future<List<ConnectionConfig>> loadConnections();

  /// 新增连接结构；重复 id 必须显式失败。
  Future<void> addConnection(ConnectionConfig config);

  /// 更新已有连接结构；不存在的 id 必须显式失败。
  Future<void> updateConnection(ConnectionConfig config);

  /// 删除一个连接结构；凭据由 CredentialRepository 单独清理。
  Future<void> deleteConnection(String id);

  /// 按调用顺序删除多个连接结构。
  Future<void> deleteConnections(List<String> ids);

  /// 更新当前列表顺序并持久化排序字段。
  Future<void> reorderConnections(int oldIndex, int newIndex);

  /// 从已加载快照中读取连接结构。
  ConnectionConfig? getConnection(String id);
}
