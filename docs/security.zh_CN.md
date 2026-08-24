# 安全

**中文** | [English](security.md)

身份认证和授权是可选的静态单机启动配置。本版本不提供在线用户或 ACL
修改 API。

## 密码认证

设置 `--allow-anonymous false --password-file PATH`。每个非空行格式为
`username:encoded-hash`，仅接受标准 Argon2id 编码哈希。

以下情况会在监听端口打开前失败：明文密码、重复用户、非法 UTF-8、超过
1 MiB 的文件、符号链接或非普通文件。未知用户仍会执行一次 Argon2id 验证，
以减小用户名时序差异。密码、编码哈希和 CONNECT 凭据不会写入日志。

MQTT 3.1.1 本身不保护凭据传输，明文 MQTT 中的凭据可被网络观察者读取。
请使用 TLS 并验证 Broker 证书。本版本不支持 mTLS、证书热加载和在线密钥轮换。

## 仅允许式 ACL

```text
user alice
topic read sensors/#
topic write commands/+
topic read $SYS/broker/#
```

配置 ACL 后，没有匹配规则的操作默认拒绝。读权限必须完整覆盖所请求的过滤器；
写权限针对具体 PUBLISH/Will Topic 匹配。一个包含多个过滤器的 SUBSCRIBE 可以
部分成功，被拒绝的条目返回 `0x80`。

被拒绝的 QoS 0 消息会被丢弃；被拒绝的 QoS 1 消息会确认但不会路由或保留。
客户端始终禁止写入 `$SYS`。读取指标仍需要显式匹配的订阅和读权限。

## Principal 所有权会话

会话属于 `anonymous` 或 `user:<name>`。不同 Principal 不能接管、清理或恢复
相同 Client ID，即使 Broker 已经重启也不允许。

Disk V1 会话迁移为 `legacy-anonymous`，且只能由匿名连接恢复；下一次提交会
写为 V2。快照中包含 Client ID、过滤器和应用消息负载，因此必须保护数据目录。

