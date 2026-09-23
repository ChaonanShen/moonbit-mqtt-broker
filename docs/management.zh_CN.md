# 管理 API

**中文** | [English](management.md)

管理端口仅接受 `127.0.0.1:PORT` 的 HTTP/1.1。开启管理功能后即可使用
健康检查、Prometheus 和状态摘要；明细与操作有各自的开关，默认关闭。
派生明细索引异常时 MQTT 继续运行，明细和写路由返回 503，需修正问题并
重启。当前没有管理 HTTPS、公网监听、UI、消息载荷查看、批量删除、
retained 删除、在线令牌轮换或真实配置热重载。

## 启动与角色

令牌文件仅保存带域分隔的 SHA-256 摘要。由运行用户持有并限制为私有普通
文件；更换文件后需重启：

```bash
secret="$(openssl rand -hex 32)"
token="operator.$secret"
digest="$(printf 'moonbit-mqtt-broker/admin/v1:%s' "$token" | sha256sum | awk '{print $1}')"
printf 'operator:%s:read,operator\n' "$digest" >management-tokens
chmod 0600 management-tokens
```

Bearer 令牌格式是 `token_id.64位小写十六进制secret`。作用域可分别授予
`metrics`、`read`、`operator`、`config_admin`，彼此不隐含。操作者如需
先查询目标，应显式具有 `read`。Operation 和审计查询要求 `operator` 或
`config_admin`，且只能读本 token ID 发起的记录。响应和审计不保存
Bearer、原始请求头、载荷或密码。

```toml
[management]
enabled = true
listen = "127.0.0.1:9091"
token_file = "/path/to/management-tokens"
details_enabled = true
operations_enabled = true
max_bytes_total = 33554432
```

`operations_enabled` 依赖 `details_enabled`，后者依赖 `enabled`。示例明确
将父池设为 32 MiB；只读部署仍沿用 8 MiB 默认值。请求、缓存、索引、查询、
游标、Operation 和审计共享一个普通资源父池，也受 Broker 全局普通预算
约束。`--check-config` 会在监听前校验参数、依赖关系和令牌文件。
完整键见[配置](configuration.zh_CN.md)和[资源预算](resource-budgets.md)。

## 路由

| 路由 | 作用域 | 结果 |
| --- | --- | --- |
| `GET /health/live`、`GET /health/ready` | 无 | 200 或 503 |
| `GET /metrics` | metrics | 有界 Prometheus 文本 |
| `GET /v1/status` | read | 观测摘要、能力和可用性 |
| `GET /v1/listeners` | read | 当前 MQTT TCP 与管理 HTTP 监听器 |
| `GET /v1/connections[/{id}]` | read | 连接阶段、已知的 Client ID/Principal 与 ETag |
| `GET /v1/sessions[/{handle}]` | read | 实例身份、生命周期、归属及队列数量/字节 |
| `GET /v1/sessions/{handle}/subscriptions` | read | 过滤器与 QoS |
| `GET /v1/retained` | read | Topic、QoS 与载荷字节数，无载荷 |
| `GET /v1/config` | read | 白名单限制与开关，无令牌路径或秘密 |
| `POST /v1/connections/{id}/disconnect` | operator | 精确关闭该连接 |
| `DELETE /v1/sessions/{handle}` | operator | 只删除离线持久 Session |
| `GET /v1/operations/{id}` | operator 或 config_admin | 本 token 的进程内 Operation |
| `GET /v1/audit` | operator 或 config_admin | 本 token 的近期进程内审计 |
| `POST /v1/config/reload` | config_admin | 尚无协调器时返回 501 `capability_unavailable` |

连接阶段为 `await_connect`、`authenticating`、`active`。MQTT 注册之前的 TLS
握手不在列表中。当前只有一个 MQTT 监听器 `mqtt`；管理 HTTP 不计作 MQTT
连接。

## 明细、分页与身份

列表支持 `limit`（默认 50，最大 100）和 `cursor`。Session 列表还支持
`attached=true|false`、`mode=clean|persistent`；连接列表支持
`phase=await_connect|authenticating|active`。未知、重复或错误的查询参数
会被拒绝。路径 ID 必须为规范的正十进制数；Client ID、Topic 和过滤器
只在经过 JSON 转义的值中出现，不能用原始 Client ID 路径删除会话。

列表响应包含 `api_version`、`boot_id`、十进制字符串
`observed_at_ms`/`state_revision`、`consistency:"per_page"`、`items` 和
字符串或 null 的 `next_cursor`。默认每页最多扫描 256 个物理槽；稀疏
过滤可得到空 `items` 和非空游标。游标随机生成并绑定 token ID、路由、
过滤条件、boot 与索引代际；默认 60 秒到期，重试不续期，表容量为 256。
游标不是快照：未扫描槽上的新增和删除可影响后续页；已扫描槽复用后的新
对象可能漏于本次遍历。一个仍存活的实例在一次线性遍历中不迁移槽，
不同遍历也不保证排序一致。

默认响应体上限 64 KiB。身份不会被悄悄截断。单行转义后仍装不下时返回
422 `result_too_large`，可在审查配置后增加 `max_response_bytes` 并重启。
多行合计超限时返回已装入的行，并使游标指向尚未输出的行。retained 明细
不会复制消息载荷。

Session `handle` 只在当前 boot 内代表一个实例。clean 或 persistent
替换、删除后重建会换新 handle；同一个持久实例重连保留 handle，但成功
attach、detach 和重连都会推进 `lifecycle_version`。离线积压消息新增、
ACK 或预算变化不会推进它。离线删除在串行执行点删除该实例当前全部内容，
因此可能包含读取详情后收到的新离线消息。

## 管理操作与完成语义

从当前详情取 `connection_etag` 或 `etag`，放进唯一的强 `If-Match`
请求头。`Idempotency-Key` 必须为 16–64 位 ASCII 字母、数字、`_` 或
`-`。弱 ETag、`*`、列表、多值/重复头、路径别名和任何请求体都会被拒绝。
新命令返回 HTTP 202 和 `Location: /v1/operations/{id}`。HTTP 响应丢失
后，已接纳的操作仍继续；可查询 Operation，或以原 key 重试。同 token
ID/key 且方法、目标、ETag 完全相同会返回原 Operation（进行中 202、
终态 200）；同 key 不同请求返回 409。终态记录及其幂等键默认保留 15
分钟，运行中记录不会因为 TTL 被清理。重启后无法查询旧 Operation，
这里不承诺跨重启 exactly-once。

kick 按数值 ConnectionId 定位，不按 Client ID 定位。它发出关闭信号后，
等待真实 terminal、注销以及该连接的全部认证任务完成 reap 才成功。
先处理的合法 MQTT DISCONNECT 会抑制 Will；否则按异常关闭规则发布 Will，
最多一次。后来使用相同 Client ID 的新连接不属于目标。`timed_out=true`
表示已超过期限；开始后的 kick 仍继续跟踪，停机时无法确认的效果会记为
失败并标明不确定。

delete 在单写者上重新核对 handle、生命周期 ETag 和离线持久状态，释放
该实例全部队列、QoS 2、订阅与预算，并派发释放容量后推进其他会话的动作。
不会删除 retained，也不会发布旧 Will。在线会话应先 kick、等 Operation
成功、再取新的离线 ETag 后 delete。生命周期过期返回 412，在线目标
返回 409。

目前写结果均为 `persistence_mode:"off"|"snapshot"` 与
`completion_scope:"runtime"`。成功只表示运行时状态已变化，不能据此认定
普通快照已经提交。`snapshot_committed_revision_at_finish` 仅为观察值。
正常退出会保存最终快照；新快照提交前 SIGKILL 可能恢复旧 Session。
strict/WAL 耐久完成及 HTTP reload 等待对应功能后续接线。

## 审计与边界

审计响应含 `sequence`、`oldest_available_sequence`、
`audit_overwritten_total`、`gap` 和不透明续页游标。accepted、started、
terminal 事件只记录固定结果码和不透明 ID。环形表满时覆盖最旧历史；
读取审计不再写审计。审计只在进程内，重启丢失；若需留存，应由外部定期
采集。Broker 原有日志仍可能受 stdout 接收端阻塞；本审计环不增加逐请求
同步日志输出。

常见状态：401 缺少/错误 token，403 权限不足，428 缺命令前置条件，
400 格式错误，404 目标不存在或非本人 Operation，409 在线 Session
或幂等冲突，410 游标过期或旧 boot Operation，412 陈旧 ETag，422
单行过大，429 容量/速率限制，501 reload 尚不可用，503 功能关闭、
索引降级或正在停机。所有响应使用 `Cache-Control: no-store`。连接、
请求及命令令牌桶独立于 MQTT 限速，队列/槽位固定；慢读取者直到真实写出
或取消后才归还请求槽。管理监听器没有自身 TLS，需限制本机访问，转发时
使用安全通道。
