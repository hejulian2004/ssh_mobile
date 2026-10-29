最新更新时间：2026-10-29

# ssh_core

`ssh_core` 是 SSH Mobile 的 App Scope SSH 基础设施包，提供：

- `SshSessionManager`、`SshSessionLease` 和引用计数 Session Pool；
- Desktop/移动端 Runtime Adapter 契约；
- SSH Client、Host Key 校验和一次性命令执行边界；
- 非敏感远端目标绑定与安全凭据运行时模型。

## 依赖边界

本包只依赖 `app_core`、`connection_core` 和 `dartssh2`。它不依赖
App Shell 存储实现、任何 Feature、Flutter 页面或平台 Background Service。
密码、私钥不进入目标绑定、日志和序列化数据；持久化通过
`CredentialRepository`、`HostKeyRepository` 等契约注入。
Host Key 首次确认使用独立候选快照，只有持久化成功后才更新调用方配置；连接
编辑验证可显式只返回候选信任，再由 Feature 与配置、凭据统一提交。
`SshClientFactory` 与 `SshHostKeyPolicy` 可注入同一 `validateTarget` 能力：
Socket 创建及 Host Key 确认前后重新核验目标和凭据 revision。未知 Host Key
对话框或信任持久化等待期间的撤销不能返回认证许可；只有合法首个已确认
Host Key 可以通过 `authenticatedConfig` 丰富原绑定快照。

## 生命周期

`AppRuntime` 创建唯一的 `SshSessionManager`。Feature 通过
`SshSessionManager.acquire` 获取租约，并在页面离开时调用
`SshSessionLease.release`。Feature 不得关闭共享 Session；Pool 只在引用归零并
经过 idle timeout 后关闭输出流。App 退出时由 Runtime 调用 `close`。

当前应用仍保留 `SshService` 作为旧 Terminal/Background API 兼容层；该入口与
App Runtime 的 SSH Manager 使用同一 Owner，后续 Terminal Pilot 会逐步替换旧
方法面，避免一次迁移删除现有会话行为。

## Package contract

- 职责：提供 App Scope SSH Manager、Session Pool、Lease、Runtime Adapter、Client、
  Host Key、命令和目标绑定契约。
- 不负责：Feature UI、App Shell 存储、凭据持久化或平台 Background Service。
- Public API：`package:ssh_core/ssh_core.dart`。
- 依赖：`app_core`、`connection_core`、`dartssh2` 和 Flutter SDK。
- 数据库：不拥有数据库；凭据/Host Key 由 Core Repository 契约注入。
- 生命周期与资源 Owner：AppRuntime 创建并关闭唯一 `SshSessionManager`；Feature
  只持有并释放 Lease，不得关闭共享 Session；Pool 负责 idle Timer/Stream 清理。
- 测试命令：`flutter analyze --no-pub`、`flutter test --no-pub`。
