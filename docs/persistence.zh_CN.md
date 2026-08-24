# 本地快照持久化

**中文** | [English](persistence.md)

仅在提供 `--data-dir PATH` 时启用持久化。纯内存模式不会创建任何持久化
文件。启用后可使用以下选项：

| 选项 | 默认值 | 约束 |
| --- | ---: | --- |
| `--max-snapshot-bytes` | 67,108,864 | 至少为 24，且必须能够进行有界 Native 读取 |
| `--snapshot-debounce-ms` | 250 | 至少为 1 |
| `--snapshot-max-delay-ms` | 2,000 | 不小于 debounce |
| `--snapshot-retry-ms` | 1,000 | 至少为 1 |

未提供 `--data-dir` 时使用快照调优参数属于配置错误。

## 文件和启动过程

规范化后的数据目录权限为 `0700`，其中只使用以下固定文件名：

- `broker.snapshot`：已提交的 Disk V2（或可读取的旧版 V1），权限 `0600`；
- `broker.snapshot.tmp`：当前尚未提交的写入，权限 `0600`；
- `broker.snapshot.lock`：进程排他锁，权限 `0600`。

Broker 会在读取状态前获取非阻塞排他锁，并持有至退出。第二个使用同一目录的
Broker 会在绑定端口前失败。加锁后会尽力删除旧临时文件，但绝不会将其提升为
主快照。主文件不存在表示首次启动。已有主文件必须是非符号链接的普通文件、
大小不超过配置上限，并通过 envelope、CRC、有界解码和完整 Router 导入检查。
空文件、截断、损坏、未知版本、过大、键重复、符号链接、FIFO、设备或目录都会
导致启动失败。只有恢复成功后才开始监听。

## 提交和失败行为

每次保存都会先在内存中进行规范编码，然后创建或截断临时文件、写入全部字节、
完整同步文件、关闭文件、原子替换主文件，最后同步目录。重命名前失败会尽力
删除临时文件，主文件保持不变。重命名后的目录同步失败表示持久性不确定：当前
可见的主文件是完整的，但无法保证断电后仍然存在。

状态变化通过静默 debounce 合并，并受最大延迟限制。Router 提交为非阻塞、
容量为一；写入较慢时只保留最新 revision。保存失败会记录
`persistence=degraded`，并持续重试最新状态；之后成功会记录恢复和已提交的
revision。日志示例：

```text
snapshot restored version=1-or-2 sessions=2 retained=1 bytes=412 data_dir=/data
snapshot failed revision=8 category=filesystem persistence=degraded
snapshot persistence recovered revision=11
snapshot committed revision=11 bytes=487
```

持久性边界是最近一条成功的 `snapshot committed` 日志。本设计没有 WAL，
也不会在发送 PUBACK 前同步；在 debounce 窗口内的变更可能因 `SIGKILL`、
宿主机故障或断电而丢失。`--once` 自然结束时会排空最后提交的 revision。
SIGTERM 和 SIGINT 会转换为正常停止请求：停止监听器和连接任务、抑制活动
Will，并在进程退出前强制写入和排空最新内存 revision。进程级退出测试使用
60 秒 debounce，因此信号处理路径必须能够创建第一份快照。

## 持久化内容和恢复操作

Disk V2 保存保留消息以及 `clean_session=false` Session，包括 Client ID、
订阅 QoS、使用原 Packet ID 的出站 inflight、有序离线 QoS 1 队列、下一个
Packet ID、所属 Principal 和 detach epoch。它不保存 Clean Session、离线
QoS 0 消息、TCP 连接、attached 状态、Keep Alive 截止时间和尚未触发的连接
Will。已经路由到 retained、inflight 或 pending 状态的 Will 会按普通消息保存。

Disk V2 以 `MBMQTT01` 开头，envelope 版本为 2、flags 为零，随后是无符号
大端 payload 长度和 IEEE CRC-32。其规范 payload 是公开的 Snapshot V2 模型。

### V1 迁移和回滚

版本 1 会被严格解码，不会在原文件上重新解释。其 Session 会获得
`legacy-anonymous` owner 和未知 detach epoch；完整的配置过期窗口从恢复后
首次观察时开始计算。下一次状态变化或退出提交会写入版本 2。测试套件保留了
V1 golden fixtures。

升级前请停止旧 Broker，并复制完整数据目录。一旦提交 V2，仅支持 V1 的二进制
文件将无法读取它。因此回滚必须恢复停止状态下制作的 V1 备份，不支持原地降级。

磁盘满、权限或运行时 I/O 错误发生时，Broker 会继续服务、明确标记 degraded
并重试。锁冲突和启动恢复错误是致命错误。系统不会自动修复损坏的主快照、回退
备份或提升临时文件。手动恢复前请停止 Broker 并复制整个数据目录；在替换或
删除主文件前，应先诊断并保留原文件。Broker 持锁期间切勿编辑这些文件。
