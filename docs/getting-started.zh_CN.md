# 入门指南

**中文** | [English](getting-started.md)

本指南介绍如何启动本地 MQTT 3.1.1 Broker、验证发布订阅，并进一步启用
持久化和带身份认证的 TLS。

## 环境要求

- 支持 Linux/amd64 容器的 Docker；
- Mosquitto clients、MQTT.js 等 MQTT 3.1.1 客户端；
- 可用的本地端口：明文 `1883` 或 TLS `8883`。

项目容器已经包含所需的 MoonBit 工具链和测试客户端。

## 启动明文 Broker

在仓库根目录执行：

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 0.0.0.0:1883
```

保持该终端运行。在第二个终端启动订阅者：

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 -i demo-sub -t 'demo/#' -q 1
```

在第三个终端发布消息：

```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -i demo-pub \
  -t demo/hello -m 'hello from MoonBit' -q 1
```

订阅者应输出 `hello from MoonBit`。

## 使用配置文件

将[配置文档](configuration.zh_CN.md)中的示例保存为本地 TOML 文件。
启动前先验证配置：

```bash
broker --config /etc/moonbit-mqtt-broker.toml --check-config
broker --config /etc/moonbit-mqtt-broker.toml --print-effective-config
broker --config /etc/moonbit-mqtt-broker.toml
```

未知键、重复键、格式错误或类型错误都会在监听端口打开之前使启动失败。
命令行参数优先于 TOML 中的值。

## 启用重启持久化

传入一个私有数据目录：

```bash
mkdir -p data
chmod 0700 data
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 0.0.0.0:1883 \
  --data-dir /workspace/data
```

使用 SIGTERM 或 SIGINT 停止 Broker，以便写入最新快照。SIGKILL、宿主机故障
或断电只能保留最近一次已经完成的快照。依赖重启恢复前请阅读
[本地持久化](persistence.zh_CN.md)。

## 启用 TLS、密码和 ACL

使用证书和仅所有者可读的私钥。密码文件只能保存 Argon2id 编码哈希：

```text
# /run/secrets/mqtt-passwords，权限 0600
alice:$argon2id$v=19$m=65536,t=3,p=1$...$...
```

定义仅允许式权限：

```text
# /etc/moonbit-mqtt-broker.acl
user alice
topic read devices/#
topic write commands/+
topic read $SYS/broker/#
```

然后启动仅 TLS 的监听器：

```bash
chmod 0600 server.key /run/secrets/mqtt-passwords
broker --listen 0.0.0.0:8883 \
  --tls-cert /etc/broker/server.crt \
  --tls-key /etc/broker/server.key \
  --allow-anonymous false \
  --password-file /run/secrets/mqtt-passwords \
  --acl-file /etc/moonbit-mqtt-broker.acl
```

MQTT 3.1.1 凭据在明文连接上可被观察到。启用密码认证时必须使用 TLS。
文件和授权规则见[安全文档](security.zh_CN.md)。

## 运行示例和测试

```bash
examples/basic_pubsub.sh
examples/restart_persistence.sh
scripts/verify-release-docker.sh
```

完整验证会执行构建、测试、互操作场景、示例、文档和敏感信息检查，并在
干净目录中重新构建 mooncakes 发布包。

## 运行边界

本版本为单机 Linux x86_64 Native 实现，不支持 MQTT 5、QoS 2、WebSocket、
集群、Bridge、插件、外部数据库、WAL 或零丢失持久化。部署前请查看
[兼容性矩阵](compatibility.zh_CN.md)。

