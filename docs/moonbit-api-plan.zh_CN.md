# 统一 MoonBit API 执行计划

状态：规划稿，尚未实施 API。日期：2026-09-24。

项目基线：`cc00fd67db351d890434bccac168baa44b1f078f`。
规划分支：`docs/moonbit-api-plan-20260924`。
唯一工作目录：`/home/scn/moonbit-mqtt-broker`。

## 1. 目标与范围

先建立一套 MoonBit 原生、类型明确、可独立引用的 API，再在这套 API 上绑定 C 及其他语言。使用者不必直接组装 BrokerState、RouterDriver、持久化 writer 和管理邮箱。

参考 [Eclipse Mosquitto](https://github.com/eclipse-mosquitto/mosquitto) 的接口能力，不承诺源码、函数名、错误码或二进制兼容。参考快照固定为上游 master 提交 `6aaba32614eb1160ddbfeafd616f9f67e7914a41`（2026-09-03），不称为已发布稳定版。上游现在由 `include/mosquitto.h` 聚合拆分的 `mosquitto/*.h`；不能只依据旧单头文件文档。

| 接口面 | 本项目定位 | 第一轮交付边界 |
| --- | --- | --- |
| 嵌入式 Broker | 主要产品能力：生命周期、监听器、发布、查询、管理、持久化 | 封装已有能力，实现必要的服务控制通道 |
| MQTT Client | 对应 libmosquitto 的客户端连接、发布订阅、回调、TLS | 提供类型、签名和能力清单；缺少客户端运行时的操作返回 Unimplemented |
| Broker 扩展 | 对应 Broker 查询/控制、插件生命周期及事件钩子 | 已有查询/控制尽量落地；插件执行、认证拦截、消息修改和外部存储先保留错误入口 |

“接口已提供”和“功能已实现”分别验收。未实现接口必须能编译、被引用、被调用、被识别；不能仅写在文档里，也不能返回假的成功结果。

第一轮不以完成 MQTT 5、完整客户端、动态插件或 C 绑定为完成条件。它们均有明确入口和缺口，后续单独实现。C 内存函数、裸指针和重复的同步/异步变体按 MoonBit 类型与 async 模型归并，见[接口对照清单](moonbit-api-mosquitto-map.zh_CN.md)。

## 2. 当前基础与新增工程

以 `.mbt` 源码为准：部分现存 `pkg.generated.mbti` 未包含多监听器、管理和 strict 后续变化，实施时须重新生成。

| 能力 | 当前源码 | API 工作 |
| --- | --- | --- |
| 多监听器 TCP/TLS/WS/WSS | `src/server/server.mbt`、`listener_config.mbt` | 复用运行入口，新增生命周期与控制句柄 |
| 配置与启动装配 | `src/config/config_file.mbt`、`src/cmd/broker/main.mbt` | 抽离默认值、合并和校验；库模式不解析进程 argv |
| 路由/QoS/retained/Session | `src/router`、`src/server/broker_runtime.mbt` | 通过单写者命令执行，不直接改运行中的状态 |
| 状态、指标、分页 | `src/server/management_query.mbt`、`broker_observation.mbt` | 提取类型化结果，HTTP 与 SDK 共用服务层 |
| kick/离线 Session 删除 | `src/server/management_command*.mbt`、`strict_management_command.mbt` | 保持代际、前置版本、Operation 和提交完成语义 |
| snapshot/strict WAL | `src/persistence`、`src/server/strict_*` | 保持恢复/提交屏障，补充 SDK 操作收据 |
| 日志/认证/ACL | `src/observability`、`src/security` | 复用静态策略；自定义认证插件不算已有能力 |
| 通用客户端/动态插件 | 当前无统一实现 | 独立命名空间和 stub，不用 Broker 协议支持冒充 Client SDK 支持 |

本任务包含生命周期、控制邮箱和类型化服务重构，不只是给现有公开函数改名。

## 3. 包结构

建议公共入口为 `ChaonanShen/moonbit-mqtt-broker/api`，别名可用 `@mqtt`。保留根包无依赖的现有约定。

| 计划目录 | 内容 |
| --- | --- |
| `src/api/types` | 公共 DTO、版本、能力、错误、身份/句柄、消息、分页、完成收据 |
| `src/api` | Broker、BrokerHandle、配置、常用工具的统一入口 |
| `src/api/client` | Client API，区分纯配置与未实现的网络能力 |
| `src/api/extensions` | 插件描述、钩子注册、控制消息及外部存储契约 |
| `src/api/mqtt5` | MQTT 5 属性及选项契约，能力状态独立 |
| `src/embedding` | 内部启动装配、生命周期、命令/查询邮箱、错误转换 |
| `examples/embedded_broker` | 完整嵌入示例 |
| `examples/api_capabilities` | 能力查询与 Unimplemented 处理示例 |

公共类型不反向依赖 server；API 经 embedding 调用运行层。内部层可引用 DTO，不能反向调用 facade 形成循环。CLI 与新 API 共用启动装配和运行服务。HTTP 只负责协议/鉴权/编码，SDK 不在进程内发 HTTP 或解析 HTTP JSON 来获得类型化结果。

保留旧 server/router 等入口；新增 facade 才是向集成者承诺的接口面。公共签名不泄露 BrokerState、内部 Queue/Map、driver、HTTP 回复或 OpenSSL 指针。第一轮完整 Broker API 的验证平台仍为 Linux/amd64 Native，不因类型包能跨后端就宣称整个 Broker 支持 JS/Wasm。

## 4. 公共契约草案

以下为设计签名，省略命名空间和部分 DTO，不是已编译声明。M0/M1 使用项目固定工具链确定精确的 async、泛型回调及类型语法。

公共模型包括：配置 `BrokerConfig`；拥有生命周期的 `Broker`；绑定实例代际的 `BrokerHandle`；不透明 `ConnectionRef/SessionRef/OperationId/OperationHandle`；含二进制 payload 的 `Message`；有界 `Page[T]`；含完成范围及可选 committed LSN 的 `OperationReceipt`；`VersionInfo/CapabilityInfo/ApiError`。公开结果是有所有权的快照，不暴露内部可变对象。

### 4.1 生命周期

| 计划接口 | 返回/行为 | 第一轮 |
| --- | --- | --- |
| `version/api_version/capabilities` | 版本与逐功能状态 | 实现 |
| `BrokerConfig::default/from_toml/validate` | 默认值、解析和纯校验 | 实现 |
| `BrokerConfig::with_listener/with_security/with_persistence/with_limits` | 具名配置组合 | 实现现有选项 |
| `Broker::new(config)` | Result[Broker, ApiError]，不启动服务 | 实现 |
| `Broker::handle()` | 同一异步运行时内的控制句柄 | 实现 |
| `Broker::run()`（async） | Result[StopReport, ApiError]，拥有整个服务任务生命周期 | 实现 |
| `with_broker(config, async body)`（async） | 等待 ready 后把 handle 交给 body；退出时停止并 join | 实现，推荐入口 |
| `BrokerHandle::wait_ready/request_stop/wait_stopped` | 就绪、停止请求、等待结果 | 实现 |
| `Broker::close()` | 关闭未运行或已 join 的实例 | 实现；重复 close 成功，运行中调用报错 |
| `Broker::restart/reconfigure` | 重启/重新配置 | Unimplemented |
| `Broker::poll/loop_read/loop_write/loop_misc` | 宿主事件循环驱动 | Unimplemented |

不提供无所有者的后台 start。未来如增加 start，必须绑定宿主任务作用域并明确 join/cancel 责任；C 专属线程另行设计。生命周期为 Created → Starting → Running → Stopping → Stopped → Closed，失败进入 Failed 并清理。run 只允许一次；重启先新建实例。

ready 只在恢复、凭据检查、全部监听器绑定、必要 writer 就绪后发出。启动失败回收监听器、锁、writer、worker 和预算。库模式不安装进程信号处理、不调用 exit、不读 argv、不改工作目录。CLI 继续自行处理 SIGINT/SIGTERM。

### 4.2 发布、查询和管理

下表涉及运行态的方法统一通过 BrokerHandle 调用，等待型方法为 async，普通失败返回 Result[..., ApiError]。

| 计划接口 | 第一轮 | 语义 |
| --- | --- | --- |
| `publish(message, context)` | 新增控制路径后实现 | 明确受信的 Broker 内部发布身份，不伪装客户端；保留读 ACL、预算、QoS 和 strict 规则 |
| `publish_to(connection, message)` | Unimplemented | 定向投递不同于现有普通订阅路由 |
| `status/health/metrics/listeners` | 实现 | 类型化、有界、带观察时间 |
| `connections/connection/sessions/session/subscriptions/retained` | 已有字段实现 | 有界分页、代际和观察时间；retained 默认仅元数据 |
| `disconnect(connection, options)` | 默认策略实现 | 返回 Operation；等待 terminal、注销、认证 reap 及 strict 后继事务 |
| `disconnect_by_client_id(id, expected_ref, options)` | 精确目标适配实现 | 单写者核对代际，不能跨接管误踢新连接 |
| `disconnect_by_username/disconnect_all` | Unimplemented | 需单独定义有界批量和部分结果 |
| `delete_session(ref, expected_version)` | 仅离线持久 Session 实现 | 版本、资源结算、Operation、strict durable 与现有 HTTP 一致 |
| `add_subscription/remove_subscription` | Unimplemented | 管理其他 Session 的订阅不等同 Client.subscribe；需补权限、重放、代际、WAL |
| `set_client_id/set_username/set_will` | Unimplemented | 不能直接改字段绕过身份所有权、接管、Will 和持久化 |
| `submit_publish/submit_disconnect/submit_delete_session` | 实现 | 非等待式原子准入，返回有界 OperationHandle；满队列当场拒绝 |
| `operation/wait_operation` | 实现 | 接纳与完成分离；跨重启不保证可查询或 exactly-once |
| `flush/checkpoint/reload_config` | Unimplemented | 内部存储调度不等于公开可等待契约；热重载尚无协调器 |

配置支持 snapshot/strict 不意味着手动 flush/checkpoint 已实现。ConnectionInfo 中已有字段直接封装；远端地址、监听端口、传输类型等缺少保留链路的字段在 transport 注册时有界捕获。mTLS 证书身份查询返回 Unimplemented，不能用 None 混淆“功能存在但没证书”。非默认的强制发送/抑制 Will 选项若没有完成路径，必须报错，不能忽略。

### 4.3 Client 与扩展

Client 覆盖 create/close/reset、connect/reconnect/disconnect、publish/subscribe/unsubscribe、Will、认证、TLS、事件/回调、重连策略、代理和网络循环。能真实实现的纯配置和校验可以成功；没有客户端运行时前，所有网络方法及依赖它们的快捷订阅均返回 Unimplemented。Client.new 可创建配置对象，不返回假的 Connected 状态。

扩展覆盖描述/安装/卸载、事件注册/取消、认证/ACL、消息检查/修改、控制消息、持久化 provider。首轮实现有界只读观察事件：连接、断开、订阅变化、发布元数据、日志、生命周期。消息载荷流、认证决策、消息修改、插件执行/provider 安装是独立能力，先占位。请求包含未实现的必需钩子时整体拒绝，不留下部分注册。

## 5. Unimplemented 与统一错误

普通失败统一使用 Result[T, ApiError]，包含 async 操作。宿主 async 取消沿结构化并发传播，清理受作用域保护，不把取消吞成成功。ApiError 至少包含稳定 kind/code、operation、可选 feature、可读消息。秘密、证书内容和 payload 不进入错误。

| kind / 建议 code | 场景 |
| --- | --- |
| Unimplemented / `unimplemented` | 有接口，本版本功能未实现 |
| UnsupportedProtocol / `unsupported_protocol` | 已实现入口请求了不支持的协议 |
| UnsupportedPlatform / `unsupported_platform` | 当前平台没有实现 |
| FeatureDisabled / `feature_disabled` | 实现存在，配置关闭 |
| DependencyUnavailable / `dependency_unavailable` | 当前环境缺系统库 |
| InvalidArgument、InvalidState、NotRunning、Closed | 参数或实例生命周期错误 |
| NotFound、Conflict、StaleHandle、PermissionDenied | 标识、前置条件或权限错误 |
| ResourceExhausted、Busy、Timeout、PersistenceFailure、InternalFailure | 有界资源、等待、持久化及可恢复内部失败 |

例：Client.connect_v5 返回 Err，kind=Unimplemented，operation=`client.connect_v5`，feature=`client.network.mqtt5`。不使用 abort/panic/TODO 终止宿主，不静默降级，不返回空列表、假句柄或 Ok(()) 伪装成功。消息文本不作为稳定 API。

能力清单分开表达实现状态、平台、配置启用状态、依赖和约束。采用 `broker.publish`、`broker.publish_direct`、`client.network.mqtt311`、`extensions.auth` 等明确 ID；不能用一个 `mqtt311=true` 掩盖客户端缺失。

错误优先级固定为：基本句柄/授权 → 功能和平台 → 具体参数/运行状态 → 准入和执行。stub 在任何执行副作用之前返回，不连网、不创建目录、不改状态、不登记半个插件、不留下持续租约。未实现钩子的注册当场失败，不等事件到达才发现缺实现。

所有承诺入口、能力状态和默认值维护在同一版本化清单。保留入口意味着真实可调用的错误实现，不能只有注释。

## 6. 必须保持的运行契约

1. **单写者。** SDK、HTTP、MQTT 修改最终进入同一 RouterDriver。新增邮箱有容量、字节预算、公平调度、代际及关闭唤醒规则。
2. **strict 屏障。** SDK publish/管理复用 prepare → WAL commit → apply/发送链。不能直接 BrokerState.apply，也不能伪造 MQTT 报文跳过真实准入。需要时新增类型化 SDK 事件及 durable delta。
3. **完成范围。** off/snapshot 成功代表 Runtime 效果，snapshot 尚未必落盘；strict 的 Durable 成功须有 committed LSN。两者都不表示接收端业务处理完成。PublishReceipt 报告准入、部分路由/丢弃，不把接纳说成全员投递。
4. **超时和取消。** submit_* 在一次不挂起的准入步骤中返回 OperationHandle 或明确拒绝；调用方先持有 ID，再异步 wait_operation。接纳后等待超时/取消不撤销效果，句柄可继续查询。publish/disconnect 等 async 便利方法封装 submit+wait；需要取消后追踪结果的调用方使用两步形式。便利方法被宿主取消时不保证调用方已取得 ID，必须声明效果可能已发生，不能建议盲目重试。普通 Timeout 错误若已有 ID，应携带它。记录和幂等范围有界，不承诺跨重启查询。
5. **所有权与预算。** 公共结果为不可变快照或有所有权的值；复制、payload、事件积压和分页都计入预算，不公开可写内部集合。
6. **回调。** 观察事件通过写者之外的有界 dispatcher 处理，不在路由临界路径执行任意宿主代码。溢出有 gap/计数且不阻塞 Broker；观察流不是有 QoS 保证的消息订阅。
7. **安全扩展。** 未来认证/ACL 钩子要有超时、并发上限和失败策略；普通观察回调不决定授权；未实现安全钩子不默认放行。
8. **句柄与资源。** 绑定实例/boot/代际；事件流、游标、Operation 有关闭/过期规则。多个实例不共享业务状态、锁或信号处理。句柄只支持同一 MoonBit 异步运行时内任务，不承诺任意 OS 线程安全。
9. **停机。** request_stop 只表示请求；run/wait_stopped 返回才提供停止结果。保留 writer/同步失败，未完成清理不能宣称正常退出。
10. **兼容。** 新 facade 语义稳定，旧入口先保留；不把所有原有内部 pub 永久冻结。HTTP 的权限/ETag 与 SDK 的受信能力/expected version 明确映射。

## 7. 分阶段实施

执行顺序 M0 → M1 → M2 → M3 → M4 → M5 → M6；M5 的清单和 stub 在 M1 明确契约后可提前完成。这是工作包划分，不触发本轮功能实施。

| 阶段 | 交付物 | 完成判据 |
| --- | --- | --- |
| M0 契约冻结 | 公共签名、Mosquitto 对照、能力状态、错误和完成语义 | 每组参考能力有入口、类型化归并或语言不适用的明确去向 |
| M1 类型与配置 | api/types、配置、错误、能力、工具；CLI 装配抽到 embedding | 外部消费夹具能 import；默认值/CLI 优先级保持；公共签名不泄露内部类型 |
| M2 生命周期 | Broker/handle/run/with_broker/ready/stop/close | 真实 MQTT 客户端能连接；启动失败回收；重复停止/关闭、宿主取消、join 有确定结果 |
| M3 类型化管理 | 查询、分页、Operation、kick/离线删除；HTTP 共用服务层 | 新旧入口前置条件与终态一致；覆盖接管、旧句柄、超时、索引退化 |
| M4 SDK 发布与事件 | 单写者发布命令、收据、strict 集成、有界观察事件 | 真实消息验证 QoS/retain/ACL/预算；strict 故障路径不提前放行；慢观察者不堵 Broker |
| M5 覆盖与错误入口 | client/extensions/mqtt5 的承诺入口、能力表、错误实现 | stub 均可调用且无副作用；不支持功能有 kind/feature；安全注册不能部分成功 |
| M6 文档与交付 | 使用指南、消费示例、迁移说明、生成接口、CI 接线 | 从实际打包产物独立引用；CLI 回归保持；新增测试确实进入验证链 |

M2–M4 是主要风险所在，宜分成连贯候选批次交付。不能只有完整 stub 清单就宣布可用 Broker SDK 完成。粗略工作量约 2–4 个工程周，取决于类型化管理抽离与 strict 发布改造；这是估算，不含完整客户端、MQTT 5、插件和 C 绑定。

后续独立阶段：N1 实现真实 MQTT 3.1.1 Client（连接/重连、QoS 0/1/2、订阅、Will、TLS、会话恢复）；N2 逐项实现扩展/高级管理/热重载；N3 C ABI 加一种语言绑定；MQTT 5 独立排期。每项从 Unimplemented 转为实现时同步更新能力清单、错误、文档与验证。

## 8. 验证与交付

规划阶段只核对源码、上游接口、文档链接和 diff，不运行长测试，不自动提交或推送。

实施时在远端现有 Docker/固定工具链运行必要 fmt、check 和少量定向测试；完整回归由 CI 执行。

| 验证面 | 必须覆盖 |
| --- | --- |
| 外部使用 | 从实际包导入 facade，创建/关闭实例，不依赖内部包或仓库私有路径 |
| 生命周期 | ready 前失败、端口冲突、取消、重复 stop/close、join、锁释放、多实例隔离 |
| 管理 | 接管/旧代际、版本冲突、分页边界、关闭唤醒、Operation 留存与取消 |
| 发布 | 二进制 payload、QoS 0/1/2、retained 更新/删除、ACL、资源不足和部分结果 |
| 持久化 | off/snapshot/strict 完成范围、崩溃恢复、WAL 失败，SDK 不绕提交屏障 |
| 事件 | 慢消费者、回调异常、gap、注销/关闭、重入、payload 不泄漏/不无界复制 |
| stub | 每个入口的 kind/feature 一致性、状态/资源不变、无文件/网络副作用 |
| 回归/分发 | 旧 CLI/MQTT/管理行为、Debug/Release 包、四系统库环境、既有严格门禁 |

新增消费夹具和快测脚本进入仓库；M6 必须把适用脚本接入 `.github/workflows/ci.yml` 的真实严格分发链，不能仅写“CI 覆盖”。改验证链时同步更新发布验证手册。

实施候选按项目约定提交并推送任务分支触发 CI，成功后交付 SHA、CI 链接/入口和必要用户测试命令并结束，不等待 CI。CI 未覆盖的必跑测试才准备远端日志/退出码保留脚本交用户；没有额外必测就明确写“无额外手动必测”。正式验收仍需同一候选的完整成功证据。规划文档交付不等于上述实现验收通过。

## 9. 后续 C 绑定边界

先稳定 MoonBit 语义，再用 C adapter 映射不透明句柄、固定错误码、指针加长度及明确分配/释放方。不要把 MoonBit struct/enum 的运行时布局或引用计数规则当普通调用方必须遵守的公共 ABI。

回调对应函数指针与 userdata；线程归属、取消、join、重入和错误边界专门验证。MoonBit 泛型便利方法可有 C 专用非泛型 wrapper，无须机械复制 C 写法。

现有最小互操作探针只验证标量函数互调，记录在远端 `.local/interop-probe-20260924-USP3sV/RESULTS.md`。它不证明完整 Broker、多实例、跨线程或稳定 ABI 已可用；原生库打包仍需项目维护构建步骤。

## 10. 参考

- [固定快照聚合头文件](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto.h)
- [Broker 能力](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto/broker.h)
- [插件契约](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto/broker_plugin.h)
- [客户端 API](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto/libmosquitto.h)
- [项目架构](architecture.zh_CN.md)、[兼容性](compatibility.zh_CN.md)、[管理](management.zh_CN.md)、[持久化](persistence.zh_CN.md)
- 实施与 CI 交接：远端本地文档 `p1-ci-handoff.local.md`（不随发布包分发）。
