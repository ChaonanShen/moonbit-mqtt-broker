# 只读管理 API

**中文** | [English](management.md)

可选管理端口提供进程健康检查、有限量的 Prometheus 指标和状态摘要。默认
关闭，只接受 `127.0.0.1:PORT`。它是独立于 MQTT/TLS 的 HTTP/1.1
监听器。当前版本没有管理写操作、查询、热重载或在线轮换令牌的接口。

## 启动

生成 32 字节随机 secret，私有文件中只保存带域分隔的 SHA-256 摘要：

```bash
secret="$(openssl rand -hex 32)"
token="observer.${secret}"
digest="$(printf 'moonbit-mqtt-broker/admin/v1:%s' "${token}" | sha256sum | awk '{print $1}')"
printf 'observer:%s:metrics,read\n' "${digest}" >management-tokens
chmod 0600 management-tokens
printf '客户端 Bearer 令牌：%s\n' "${token}"
```

请将打印的令牌存入密钥管理系统。令牌文件必须由 Broker 运行用户持有，
且只有该用户可读。符号链接、目录、FIFO、过宽权限、格式错误、重复 ID、
超过 16 KiB 的文件均会被拒绝。客户端令牌格式为
`token_id.64位小写十六进制secret`；角色需要逐项授予，不互相包含。
最多 32 条记录。

```bash
broker --management-enabled true \
  --management-listen 127.0.0.1:9091 \
  --management-token-file /path/to/management-tokens
```

`--check-config` 会在服务启动前校验令牌文件。启用管理端口时动态加载
`libcrypto.so.3`；禁用管理功能本身不要求此库。受支持的 Ubuntu 24.04
运行镜像包含 libcrypto。修改令牌文件后需要重启。

## 路由

| 路由 | 鉴权 | 响应 |
| --- | --- | --- |
| `GET /health/live` | 无 | 进程存活时 200；能响应但不可用时 503 |
| `GET /health/ready` | 无 | MQTT、管理端口和观测缓存就绪时 200；否则 503 |
| `GET /metrics` | Bearer，需 `metrics` 角色 | Prometheus 0.0.4 文本；缓存过期时 503 |
| `GET /v1/status` | Bearer，需 `read` 角色 | 有界 JSON 摘要；缓存过期时 503 |

```bash
curl -H "Authorization: Bearer ${token}" http://127.0.0.1:9091/metrics
curl -H "Authorization: Bearer ${token}" http://127.0.0.1:9091/v1/status
```

缺少或错误凭据返回 401，角色不足返回 403。URL 查询参数、Cookie、
请求体里的令牌均无效。每个连接只处理一个有界 GET；歧义请求头、请求体、
后缀请求和不支持的方法会被拒绝。匿名健康检查仍受连接和请求限流约束。

状态摘要包含启动 ID、观测时间及年龄、生命周期、就绪状态、MQTT 计数、
持久化概要和资源用量。JSON 中的 Int64 使用十进制字符串。不输出客户端 ID、
Topic、载荷、令牌、文件路径或 Principal。指标名称与标签固定，最多 256
个时间序列。`publish_actions_total` 统计下游动作，并非网络写入确认。
抓取指标不会创建 MQTT 发布或改变 MQTT 接收计数。

## 就绪与资源边界

路由循环按周期发布缓存观测值。就绪要求真实 driver 心跳与新鲜缓存；
缓存过期时 ready、metrics 和 status 不可用。Snapshot 降级只有在启用
`ready_require_snapshot_healthy` 时才使 ready 失败。live 仍可能返回
成功；若事件循环完全无法运行，客户端可能收到超时，而非 HTTP 503。

默认值：16 个管理连接、4 KiB 请求头、32 个 header、64 KiB 响应、
5 秒请求期限、2 秒写入期限、1 秒观测周期、5 秒最大观测年龄及 8 MiB
逻辑管理预算。独立的请求/连接令牌桶分别为每秒 50（burst 100）和每秒
100（burst 200）。CLI/TOML 键见[配置](configuration.zh_CN.md)，
计费口径见[资源预算](resource-budgets.md)。

管理端口是 loopback HTTP，自身没有 TLS。应限制主机和网络命名空间的访问；
转发时使用安全通道。不要把 Bearer 令牌放入 URL 或命令日志。Prometheus
的 `bearer_token_file` 应包含客户端令牌。
[发布验证手册](release-verification.zh_CN.md)在实际发布制品上检查授权
抓取成功及错误令牌失败。
