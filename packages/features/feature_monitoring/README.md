最新更新时间：2026-10-22

# feature_monitoring

服务器实时监控 Feature Package，包含 Linux/Windows 采样解析、健康评分、告警、
端口/进程/服务查询和监控工具适配器。

## 边界

- `lib/src/domain`：监控模型、解析器和 App/SSH Port；
- `lib/src/application`：监控服务、Module、ViewModel 和工具适配器；
- `MonitoringService` 只编排选择、Timer、低优先级 SSH probe 和平台路由；内部
  `MonitoringSampleStore` 独占有界历史/派生健康视图，
  `MonitoringAlertEvaluator` 独占阈值、五分钟去重和告警上限；
- 每次显式启动都会冻结所选连接的 `SshTargetBinding` 并生成新的 run epoch；停止、
  重启或移除连接后，旧轮次的迟到成功、错误、重试和清理不得写入当前轮次；
- 不创建 `monitoring.db`，实时采样只保存在服务内存窗口；
- 不依赖统一存储门面、`SshService`、`AppSettings` 或其他 Feature 实现。

App Shell 负责把现有 SSH、连接目录、日志和后台服务适配到公开 Port。旧
`performance_monitor_service.dart` 与 `lib/features/performance/` 已删除；
`apps/ssh_mobile_full/lib/services/server_status_probe.dart` 只保留对公开探针类型的兼容导出。

## Package contract

- 职责：提供实时采样、解析、健康评分、告警、端口/进程/服务查询和监控 Port。
- 不负责：持久化监控数据库、SSH/连接目录实现、全局 Timer 或其他 Feature 逻辑。
- Public API：`package:feature_monitoring/feature_monitoring.dart`。
- 依赖：`app_core`、`connection_core`、`ssh_core` 和 Flutter SDK；共享监控 UI
  由 App Shell 或调用方提供，不引入 `app_ui`。
- 数据库：不拥有 `monitoring.db`；历史采样只保存在受限内存窗口。
- 生命周期与资源 Owner：AppRuntime 拥有 `MonitoringModule`；Module/Service 拥有
  采样 Timer 和订阅，Sample Store/Alert Evaluator 只拥有内存状态；Module 在
  deactivate/dispose 时停止释放运行资源。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
