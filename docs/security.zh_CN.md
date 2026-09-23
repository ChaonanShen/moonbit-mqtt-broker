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

## 原生依赖与可复现测试

密码验证在运行时加载 `libargon2.so.1`（或 `libargon2.so`）。支持的环境是
Ubuntu 24.04 Linux/amd64，以及 Dockerfile 固定的工具链。项目镜像已安装
依赖；在镜像外的 Ubuntu/Debian 环境需安装 `libargon2-1` 和 `argon2`。
TLS 还需要 OpenSSL（Ubuntu 24.04 的软件包名为 `libssl3t64`）。
Mooncakes 只安装 MoonBit 依赖，不会安装操作系统动态库。

缺少动态库时，配置了密码文件的 Broker 会在监听前失败，并给出安装提示；
未配置密码文件的匿名模式仍可使用。原生认证测试会明确失败并提示依赖，
不会跳过检查，也不会再因 `Result::unwrap()` 导致整个测试进程崩溃。

测试向量使用固定密码 `correct horse`、盐值 `0123456789abcdef`、Argon2id
版本 19、4096 KiB 内存、2 次迭代、1 个 lane 和 32 字节哈希。这些是公开测试
数据，不是生产凭据或生产密码哈希参数建议。参考生成命令为：

```bash
printf '%s' 'correct horse' | argon2 '0123456789abcdef' -id -e -t 2 -m 12 -p 1
```

必须用 `printf '%s'` 避免给密码附加换行。命令中的 `-m 12` 表示 2^12 KiB，
所以编码字符串中是 `m=4096`。将哈希复制到 shell 脚本或配置文件时，应确保
`$` 字符保持原样，不被 shell 当作变量展开。

在项目容器中，或已安装依赖的受支持环境中，从仓库根目录运行：

```bash
scripts/check-argon2.sh
moon test src/security/security_test.mbt src/server/broker_runtime_security_test.mbt --target native --deny-warn
tests/integration/argon2_environment.sh
```

fixture 检查将所有内嵌向量与参考 CLI 比较，不会自动覆盖预期结果。
环境回归检查仅对测试子进程隐藏 Argon2 动态库，验证测试正常报告失败而非
SIGABRT，并验证密码认证无法在缺少依赖时启动。两项检查已接入完整发布验证。
包含 NUL、空白或非 ASCII 字符的编码哈希会在进入 C 验证前被拒绝，防止
C 字符串终止符隐藏尾部数据。

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
写为 V3。快照中包含 Client ID、过滤器和应用消息负载，因此必须保护数据目录。



## 认证资源准入

完整且需要密码校验的请求先消费一次全局/IP 认证 token，再预留输入和已验证 PHC 对应的保守工作费用。密码错误、未知用户名和后续资源不足不会退还已消费的 token。匿名路径不占 hash 任务额度，但仍受连接/传输限制。有界原生 pthread 执行器在 worker 运行时持有密码与 PHC 的 C 副本；路由主循环只保留无秘密身份元数据并消费固定大小结果。断开和超时只会取消激活资格，不会提前释放仍运行的任务。CONNECT 流水线通过一次性 reader gate 等到 CONNACK 入队后再恢复。支持的 PHC 上限为内存 65536 KiB、迭代 10、并行度 4。使用 `scripts/verify-auth-isolation-docker.sh` 验证隔离和饱和行为。详见[资源契约](resource-budgets.md)。

## 管理 Bearer 令牌

独立的[只读管理 API](management.zh_CN.md)使用显式 `metrics` 和
`read` 角色。其摘要文件只在启动时读取，与 MQTT PasswordDatabase
及 ACL 无关。文件必须是 Broker 用户持有的私有普通文件。启用管理功能
时动态加载 `libcrypto.so.3` 来提供 CSPRNG 和 SHA-256；库或必需
符号缺失会在监听前使启动失败。禁用时不加载这一功能依赖。管理端口是
没有 TLS 的 loopback HTTP，需保护主机访问，转发时使用安全通道。
