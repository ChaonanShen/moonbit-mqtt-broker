# moonbit-mqtt-broker

**中文** | [English](README.md)

[![CI](https://github.com/ChaonanShen/moonbit-mqtt-broker/actions/workflows/ci.yml/badge.svg)](https://github.com/ChaonanShen/moonbit-mqtt-broker/actions/workflows/ci.yml)

一个使用 MoonBit 实现的轻量级、单机 MQTT 3.1.1 Broker。

`0.1.0` 是一个可实际运行的 Linux x86_64 Native 版本，适用于小型部署、
本地开发、互操作测试和 MoonBit MQTT 应用。它支持多个 TCP 或 TLS 客户端、
QoS 0/1、通配符订阅、保留消息、Will、Keep Alive、持久会话、可选的重启
持久化、身份认证、ACL、指标、结构化日志和 TOML 配置。

## 快速开始

推荐使用可复现的 Docker 环境，无需在宿主机安装 MoonBit：

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 0.0.0.0:1883
```

在另一个终端中，使用任意 MQTT 3.1.1 客户端订阅和发布：

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 -t 'demo/#' -q 1
mosquitto_pub -h 127.0.0.1 -p 1883 -t demo/hello -m world -q 1
```

如需完整了解安装、配置文件、持久化和带 TLS 的认证部署，请阅读
[入门指南](docs/getting-started.zh_CN.md)。

## 功能

| 范围 | 0.1.0 支持情况 |
| --- | --- |
| 协议 | 基于 TCP 或 TLS 的 MQTT 3.1.1 |
| 消息投递 | QoS 0/1 发布订阅；出站 inflight 使用原 Packet ID 和 `DUP=1` 重放 |
| Topic | `+`、`#` 过滤器，重叠订阅确定性合并，保留消息 |
| 会话 | Clean/Persistent Session、Client ID 接管、有界离线 QoS 1 |
| 生命周期 | PING、Keep Alive、QoS 0/1 Will、SIGTERM/SIGINT 优雅退出 |
| 持久化 | 可选本地校验快照和严格启动恢复 |
| 安全 | 可选 Argon2id 密码、仅允许式 ACL、Principal 所有权会话 |
| 运维 | TOML 配置、资源限制、`$SYS/broker/#` 指标、文本/JSON 日志 |

MQTT 5、QoS 2、WebSocket、共享订阅、Bridge、插件、集群、外部数据库、
WAL 和零丢失持久化明确不在本版本范围内。可选持久化只保证恢复到最近一次
成功提交的快照，不提供同步消息持久化。详细边界见
[兼容性矩阵](docs/compatibility.zh_CN.md)。

## 配置

建议显式设置资源上限：

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:1883 \
  --max-connections 128 \
  --max-packet-size 1048576 \
  --max-receive-buffer-size 1048576 \
  --max-sessions 1024 \
  --max-inflight-per-session 16 \
  --max-inflight-total 512 \
  --max-pending-qos1-per-session 64 \
  --max-pending-qos1-total 1024
```

通过 `--data-dir` 启用本地重启持久化：

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:1883 \
  --data-dir /workspace/data
```

所有设置也可以从 TOML 加载，命令行参数优先于配置文件：

```bash
broker --config /etc/moonbit-mqtt-broker.toml --check-config
broker --config /etc/moonbit-mqtt-broker.toml --print-effective-config
broker --config /etc/moonbit-mqtt-broker.toml
```

以下命令只显示参数或版本，不会监听端口或创建数据目录：

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- --help
scripts/moon-docker.sh run --target native src/cmd/broker -- --version
```

## 示例

仓库提供三个可执行的端到端示例：

```bash
examples/basic_pubsub.sh

# 针对已经运行在 HOST PORT 的 Broker：
examples/persistent_session.sh 127.0.0.1 1883

examples/restart_persistence.sh
```

它们分别演示 QoS 0/1 实时投递、持久会话恢复，以及 Broker 重启后的保留消息
和离线 QoS 1 恢复。

## 构建和测试

受支持的开发和 CI 目标是 Ubuntu 24.04 Linux/amd64 Native。容器固定使用
MoonBit `0.10.10+f8a486b6f`、Node.js `22.23.1`、运行时依赖、MQTT.js、
Mosquitto 客户端和行为参考工具。

运行基础质量检查：

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/moon-docker.sh fmt --check
scripts/moon-docker.sh check --target native --deny-warn
scripts/moon-docker.sh test --target native --deny-warn
scripts/moon-docker.sh build --target native
```

运行完整发布验证：

```bash
scripts/verify-release-docker.sh
```

完整验证还会执行协议和参考 Broker 矩阵、有界稳定性负载、全部示例、TLS、
安全、会话过期、配置文件进程测试、敏感信息扫描、文档检查，以及在干净目录
中重建 mooncakes 发布包。

## 文档

- [入门指南](docs/getting-started.zh_CN.md)
- [配置](docs/configuration.zh_CN.md)
- [安全](docs/security.zh_CN.md)
- [本地持久化](docs/persistence.zh_CN.md)
- [兼容性和限制](docs/compatibility.zh_CN.md)
- [架构](docs/architecture.zh_CN.md)

## 许可证和来源

项目使用 Apache License 2.0。运行时依赖、仅测试工具、标准、行为参考、
版本、许可证和使用方式记录在
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 中。Broker 为原创 MoonBit
代码，没有复制 Aedes 或 Mosquitto 的实现源码。
