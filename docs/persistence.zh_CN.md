# 本地持久化：快照与严格 WAL

**中文** | [English](persistence.md)

不提供 `--data-dir PATH` 时为 `off`，不会创建持久化文件。提供数据目录但
未指定模式时仍使用兼容的 `snapshot`；显式设置 `--persistence-mode strict`
或 `[persistence] mode = "strict"` 才启用提交前同步的 WAL。快照模式选项：

| 选项 | 默认值 | 约束 |
| --- | ---: | --- |
| `--max-snapshot-bytes` | 67,108,864 | 至少为 24，且必须能够进行有界 Native 读取 |
| `--snapshot-debounce-ms` | 250 | 至少为 1 |
| `--snapshot-max-delay-ms` | 2,000 | 不小于 debounce |
| `--snapshot-retry-ms` | 1,000 | 至少为 1 |

未提供 `--data-dir` 时使用快照调优参数属于配置错误。strict 必须配置数据
目录，并拒绝 snapshot debounce/max-delay/retry 参数；显式 off 不能同时提供数据目录。

## 快照模式的文件和启动过程

规范化后的数据目录权限为 `0700`，其中只使用以下固定文件名：

- `broker.snapshot`：已提交的 Disk V3（兼容读取旧版 V1/V2），权限 `0600`；
- `broker.snapshot.tmp`：当前尚未提交的写入，权限 `0600`；
- `broker.snapshot.lock`：进程排他锁，权限 `0600`。

Broker 会在读取状态前获取非阻塞排他锁，并持有至退出。第二个使用同一目录的
Broker 会在绑定端口前失败。加锁后会尽力删除旧临时文件，但绝不会将其提升为
主快照。主文件不存在表示首次启动。已有主文件必须是非符号链接的普通文件、
大小不超过配置上限，并通过 envelope、CRC、有界解码和完整 Router 导入检查。
空文件、截断、损坏、未知版本、过大、键重复、符号链接、FIFO、设备或目录都会
导致启动失败。只有恢复成功后才开始监听。

## 快照模式的提交和失败行为

每次保存都会先在内存中进行规范编码，然后创建或截断临时文件、写入全部字节、
完整同步文件、关闭文件、原子替换主文件，最后同步目录。重命名前失败会尽力
删除临时文件，主文件保持不变。重命名后的目录同步失败表示持久性不确定：当前
可见的主文件是完整的，但无法保证断电后仍然存在。

状态变化通过静默 debounce 合并，并受最大延迟限制。Router 提交为非阻塞、
容量为一；写入较慢时只保留最新 revision。保存失败会记录
`persistence=degraded`，并持续重试最新状态；之后成功会记录恢复和已提交的
revision。日志示例：

```text
snapshot restored version=1-or-2-or-3 sessions=2 retained=1 bytes=412 data_dir=/data
snapshot failed revision=8 category=filesystem persistence=degraded
snapshot persistence recovered revision=11
snapshot committed revision=11 bytes=487
```

快照模式的持久性边界是最近一条成功的 `snapshot committed` 日志；该模式没有 WAL，
也不会在发送 PUBACK 前同步；在 debounce 窗口内的变更可能因 `SIGKILL`、
宿主机故障或断电而丢失。`--once` 自然结束时会排空最后提交的 revision。
SIGTERM 和 SIGINT 会转换为正常停止请求：停止监听器和连接任务、抑制活动
Will，并在进程退出前强制写入和排空最新内存 revision。进程级退出测试使用
60 秒 debounce，因此信号处理路径必须能够创建第一份快照。

## strict WAL 模式

strict 复用 `broker.snapshot.lock` 排他锁及 Disk V3 业务状态，另有版本化
checkpoint、`broker.manifest` 和编号 `wal-<id>.log` 段。唯一写者顺序追加完整
事务帧与批次提交帧，完整 `fsync` 成功后，driver 才安装受影响键的变更并放行
网络动作。写集互不冲突的事务可以共享一次同步；批次上限为 64 个事务、8 MiB，
收集延迟约 2 ms。单个 delta 默认最多 4 MiB；持久结果超过上限的请求会在提交
前拒绝，不会降级为快照语义。占盘统计包括 checkpoint、WAL 段和 orphan；默认
硬上限 1 GiB，并为轮转及 checkpoint 保留 256 MiB。可用
`--wal-disk-max-bytes` 和 `--wal-disk-reserve-bytes` 调整。

发布者收到 QoS 1 PUBACK 表示本次发布产生的 retained 变化及全部持久目标状态
已整体提交。QoS 2 PUBREC 还要求持久发布会话的 AwaitPubrel ID 与路由结果
一起提交，PUBCOMP 则等待该 ID 的删除提交。持久订阅者的 PUBLISH/PUBREL
须在出站 Packet ID 和阶段提交后才发送。持久 CONNACK、SUBACK、UNSUBACK
也等相应会话变化提交。管理删除 Operation 只有提交后才报告
`completion_scope=durable` 和 `committed_lsn_at_finish`；kick 等真实关闭、认证
任务回收和持久会话清理完成。TCP、TLS、WS、WSS 共用同一运行时与 WAL。
QoS 0 和 clean 会话不会仅因收到 ACK 就获得跨崩溃消息副本；MQTT 3.1.1
的 ACL 拒绝后确认并丢弃策略保持不变。

恢复只读取经过校验的 manifest 引用文件，按连续 LSN 重放完整提交批次；旧进程
即使未送出 ACK，完整提交也可能被重放。只有 active 段末端不完整追加可自动
截断并同步；完整帧 CRC 错误、缺失引用段、链断裂、坏 checkpoint 或未知版本
均使启动失败，不自动回退到旧快照。恢复与 WAL 写者就绪前不开放业务。写入或
同步失败、manifest 发布结果不确定、提交超时会令进程进入 fenced：不发送
结果不明批次的 ACK，停止 MQTT 业务准入，并维持只读运维诊断且
`ready=false`。结果须重启并在同一目录锁下恢复判定。checkpoint 在发布前失败
而 WAL 仍可靠时，可标记 degraded 继续提交，但受占盘上限约束。

正常 SIGTERM/SIGINT 会排空已接纳事务及持久 detach/清理后释放锁。已触发
Will 的路由属于后继事务：触发与提交之间崩溃仍可能丢失该 Will；未触发 Will
不会在进程崩溃后补发。OS 崩溃或断电保证还依赖文件系统与设备正确实现
`fsync`；SIGKILL 测试不能冒充断电实验。

### 模式迁移与回滚

从 snapshot 改为 strict 前，先停止旧进程并备份整个数据目录。首次 strict 启动
导入 V1/V2/V3 旧快照，并在监听前发布初始 checkpoint 与 manifest。manifest
一旦存在就是唯一恢复权威；同目录改回 snapshot 会被拒绝。不能删除 manifest
来让旧二进制读取过期的 `broker.snapshot`。回滚必须恢复迁移前的停机备份，
备份之后的写入会丢失。存储故障诊断前保留完整 strict 目录，服务持锁时不得
编辑文件。未选择 strict 时，原快照命令与语义不变。

## 持久化内容和恢复操作

Disk V3 保存 retained 和持久会话，包括 Client ID、Principal、detach epoch、
下一个 Packet ID、订阅、入站 AwaitPubrel ID、有序出站三个阶段和 pending QoS 1/2 FIFO。
AwaitPubcomp 不保存 topic/payload；Clean Session、离线 QoS 0、连接、Keep Alive
和尚未触发的 Will 不进入快照。

24 字节 envelope 保持 MBMQTT01 magic，后接大端 u16 version=3、u16 flags=0、
u64 payload 长度和 IEEE CRC-32。字符串及 bytes 均使用 u32 字节长度前缀。

| V3 payload 顺序 | 编码 |
| --- | --- |
| 模型及会话数 | u32 version=3、u32 count |
| 会话身份 | string Client ID、string Principal、string 非负 detach 毫秒、u16 next ID |
| 订阅 | u32 count；string filter、u8 QoS 0..2 |
| 入站 QoS 2 | u32 count；按接收顺序保存非零且唯一的 u16 ID |
| 出站 inflight | u32 count；u16 ID、u8 phase 1/2/3；仅 phase 1/2 带 message |
| pending | u32 count；按 FIFO 保存 message |
| message | string topic、bytes payload、u8 retain 0/1、u8 QoS 1/2 |
| 所有会话后的 retained | u32 count；string topic、bytes payload、u8 QoS 0..2 |

phase 1/2/3 分别是 AwaitPuback/AwaitPubrec/AwaitPubcomp。消息 QoS 必须与
phase 1/2 一致，phase 3 不得带消息。有序数组同时保留 PUBLISH 顺序和首次 PUBREC
顺序，无需会溢出的序号。监听前完整校验格式、状态不变量和配置上限。
当前公开快照类型使用 V3 后缀，inflight.message 为可选值，pending 显式携带 QoS。

### V1/V2 迁移和回滚

旧格式按原字段顺序与 QoS 0/1 范围严格读取。旧 inflight 转为 AwaitPuback，
pending 转为 QoS 1，入站 QoS 2 为空。V1 获得 LegacyAnonymous 与未知 detach
epoch，V2 保留 owner 与 epoch。下一次状态变化或停机提交写 V3。
测试保留非空 V1/V2 及 V3 固定字节 golden fixture。

升级前停旧服务并备份完整 data-dir。首次写入 V3 后，仅支持 V1/V2 的程序无法读取。
回滚须停止新程序、保留 V3 目录，再恢复停机前旧版本备份；备份后接收的状态会被舍弃。
不执行隐式 V3→V2 降级。

磁盘满、权限或运行时 I/O 错误发生时，Broker 会继续服务、明确标记 degraded
并重试。锁冲突和启动恢复错误是致命错误。系统不会自动修复损坏的主快照、回退
备份或提升临时文件。手动恢复前请停止 Broker 并复制整个数据目录；在替换或
删除主文件前，应先诊断并保留原文件。Broker 持锁期间切勿编辑这些文件。


## 快照字节预算

导出、排队、编码和实际写入共用 snapshot-work 预算；覆盖旧请求会归还其预算，正在写的请求持票至真实保存完成。恢复会在构造记录/复制 payload 前检查类别、会话和全局字节上限，且不改变 V1/V2/V3 格式。预算不足时保留 dirty 状态并产生受限诊断，最终未提交的快照导致关闭失败；不裁剪既有快照或静默空状态启动。文件类型在大小读取前检查，FIFO、目录和符号链接不作为快照读取。详见[资源契约与诊断指标](resource-budgets.md)。

严格模式的 WAL 写入或同步结果不确定时会隔离业务准入；只读管理诊断仍可用。快照模式的失败重试策略不适用于严格模式。
