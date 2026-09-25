# Mosquitto → MoonBit API 能力对照

状态：设计清单，不代表下列新接口已存在。日期：2026-09-24。
配套[执行计划](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/moonbit-api-plan.zh_CN.md)。项目基线 `cc00fd67db351d890434bccac168baa44b1f078f`。

参考上游提交 `6aaba32614eb1160ddbfeafd616f9f67e7914a41` 的公开头文件，并辅以官方 API 文档。按能力族归并同步/异步、带长度和 v5 变体；本清单不声称逐符号二进制兼容。实施 M0 须把每个承诺签名展开进版本化 API 清单，列出参数、结果、错误、能力 ID 及测试。

状态：**R** = 现有能力可复用、需封装；**A** = 第一轮新增适配；**U** = 第一轮必须有可调用的 Unimplemented 入口；**M** = MoonBit 类型/运行时替代，不照搬 C 函数。R/A 都是计划目标，不是当前 SDK 的实现状态。

## 1. Broker 与公共控制

本节参考 [broker.h](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto/broker.h)；这些函数主要服务 Broker 插件。嵌入式 Broker 生命周期是本项目另行设计的 facade，不把 mosquitto_new 误认成 Broker 构造器。

| ID | Mosquitto 能力/代表符号 | 计划 MoonBit API | 状态/边界 |
| --- | --- | --- | --- |
| B01 | Broker 运行与配置，非 libmosquitto 客户端构造 | BrokerConfig、Broker.new/run/close、with_broker、handle 控制 | A；复用 server.run_listeners，新增受控生命周期 |
| B02 | mosquitto_client、client_id、client_clean_session、client_keepalive、client_sub_count、client_username | connection、session、ConnectionInfo、SessionInfo | R/A；按实例与代际查询，username 与 Principal 含义明确 |
| B03 | client_address、client_port、client_protocol、client_protocol_version | ConnectionInfo 的 peer、listener、transport、protocol_version | A；缺字段要补注册链路，不能默认填假值 |
| B04 | client_id_hashv | 强类型 ClientId 与正常 Hash 支持 | M；不承诺与 Mosquitto 的内部 hash 值相同 |
| B05 | client_certificate | peer_certificate(connection) | U；当前 mTLS 不支持，返回错误而非假装没有证书 |
| B06 | set_clientid、set_username、client_will_set | set_client_id、set_username、set_will | U；涉及所有权/接管/Will/WAL，不直接赋值 |
| B07 | kick_client_by_clientid | disconnect、disconnect_by_client_id | A；精确代际、Operation；首轮只开放现有默认 Will 行为 |
| B08 | kick_client_by_username；NULL clientid 的全体踢除 | disconnect_by_username、disconnect_all | U；批量有界、目标快照和部分结果待设计 |
| B09 | broker_publish、broker_publish_copy：普通发布 | publish(Message, BrokerPublishContext) | A；不绕单写者和 strict；复制/所有权由公共值类型处理 |
| B10 | broker_publish 的指定 clientid 投递 | publish_to(ConnectionRef, Message) | U；它与按订阅路由的 publish 不等价 |
| B11 | subscription_add、subscription_delete | add_subscription、remove_subscription | U；管理指定 Session，需权限、retained 重放和 WAL |
| B12 | apply_on_all_clients | connections(PageRequest) 加宿主迭代 | A/M；用有界分页替代路由线程任意回调，不承诺全量一致快照 |
| B13 | log_printf | 日志配置、结构化 LogRecord、观察日志事件 | R/A/M；不暴露 C varargs，不记录秘密/payload |
| B14 | persistence_location | PersistenceInfo / 由调用者持有的 PersistenceConfig | R/A；路径不进入默认公共状态或匿名观测 |
| B15 | broker_node_id_set | set_node_id | U；不因此宣称已支持集群 |
| B16 | persist_client_add/update/delete | StorageProvider 的 ClientRecord 操作 | U；外部存储契约，不允许从公开 API 任意注入内部会话 |
| B17 | persist_base_msg_add/delete、persist_retain_msg_set/delete | StorageProvider 的 MessageRecord/RetainedRecord 操作 | U；先保留类型与错误方法 |
| B18 | persist_client_msg_add/update/delete/clear | StorageProvider 的 DeliveryRecord 操作 | U；恢复/QoS/事务语义独立设计 |
| B19 | complete_basic_auth | complete_auth(AuthRequestId, AuthDecision) | U；不能把现有 Argon2 worker 当通用插件认证执行器 |
| B20 | 本项目已有管理接口的补充 | status、health、metrics、listeners、sessions、retained、delete_session、submit_*、operation | R/A；和 HTTP 共用类型化服务，保留前置版本及 durable 语义 |
| B21 | 本项目存储/配置控制补充 | flush、checkpoint、reload_config、reconfigure | U；内部调度不等于已定义公开完成契约 |

Mosquitto 内部发布与客户端发布的授权身份不同；本项目 Broker 内部发布必须显式选择受信上下文，同时保持接收方读 ACL。首轮不提供任意冒用 Client ID 的发布入口。没有真实支持的 with_will/协议属性等选项必须报错，不能静默忽略。

## 2. 插件、事件和认证

参考 [broker_plugin.h](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto/broker_plugin.h) 和 [broker_control.h](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto/broker_control.h)。MoonBit 插件接口不承诺直接加载现有 Mosquitto C 插件。

| ID | Mosquitto 能力/代表符号 | 计划 MoonBit API | 状态/边界 |
| --- | --- | --- | --- |
| E01 | plugin_version/init/cleanup、plugin_set_info | PluginDescriptor、install_plugin、uninstall_plugin、plugin_info | 描述类型 A；执行/安装 U，不能只记名字就宣布安装成功 |
| E02 | callback_register/unregister | observe(EventFilter)、EventStream.close；register_hook/unregister_hook | 只读观察 A；决策/修改钩子 U；按事件逐项声明能力 |
| E03 | CONNECT、DISCONNECT、CLIENT_OFFLINE | ConnectionOpened/ConnectionClosed/SessionOffline | A；实际观察点、代际和完成范围写入契约 |
| E04 | SUBSCRIBE、UNSUBSCRIBE | SubscriptionChanged 元数据事件 | A；观察现有结果，不在回调里改订阅 |
| E05 | MESSAGE_IN、MESSAGE_OUT、旧 MESSAGE | Published/Delivery 元数据；MessageInterceptor | 元数据 A；消息修改 U；不能把观察事件叫作 QoS 消息订阅 |
| E06 | TICK、RELOAD | Tick 观察；ConfigReloaded、reload hook | Tick A且可合并；实际 reload 和相应钩子 U |
| E07 | BASIC_AUTH、ACL_CHECK | AuthProvider、AclProvider、register_auth/register_acl | U；超时、失败策略、资源限额须先设计 |
| E08 | EXT_AUTH_START/CONTINUE、PSK_KEY | EnhancedAuthProvider、PskProvider | U；依赖未实现协议/传输能力 |
| E09 | CONTROL、control_command_reply/send_response/generic_callback | register_control、ControlRequest/ControlReply、reply_control | U；不以现有 HTTP 管理 API 冒充 $CONTROL 兼容 |
| E10 | PERSIST_RESTORE；PERSIST_* 客户端、订阅、消息、retained、Will 事件 | StorageProvider、StorageEvent 和恢复上下文 | U；上游相关持久化接口本身标记不稳定，独立设计本项目事务契约 |
| E11 | auth_plugin_version/init/cleanup、auth_security_init/cleanup | LegacyAuthAdapter 描述/初始化/清理入口 | U；可归并，不机械复制多个生命周期体系 |
| E12 | auth_acl_check/unpwd_check/psk_key_get/start/continue | AuthRequest/AuthDecision、AclRequest/AclDecision 及适配入口 | U；与 E07/E08 共用语义，避免两套认证真相 |

未支持事件注册立即返回 Unimplemented；观察回调无权修改授权或持久状态；注销后须定义已排队事件是否继续交付，资源在关停后可回收。MQTT 5 扩展认证与插件接口版本号是两个维度。

## 3. libmosquitto 客户端

参考 [libmosquitto.h 及其子头文件](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto/libmosquitto.h)。客户端对象连接其他 Broker，与本项目的嵌入式 Broker 是不同对象。

| ID | Mosquitto 能力/代表符号 | 计划 MoonBit API | 状态/边界 |
| --- | --- | --- | --- |
| C01 | lib_version、lib_init、lib_cleanup | version/api_version；作用域化实例资源 | 版本 A；全局 C 初始化/清理 M，不引入无意义全局开关 |
| C02 | new、destroy、reinitialise | Client.new/close/reset | A，仅真实配置对象；网络能力仍 U |
| C03 | username_pw_set | ClientConfig.with_credentials | A，纯配置；实际认证 U；秘密不参与默认 Debug 输出 |
| C04 | will_set/will_clear | ClientConfig.with_will/clear_will | A，校验并保存配置；发 CONNECT/Will 网络效果 U |
| C05 | will_set_v5 | with_will_v5 | U，不能忽略属性 |
| C06 | connect/connect_async、connect_bind/connect_bind_async | Client.connect(ConnectOptions) async | U；归并接口，bind 是显式选项 |
| C07 | connect_srv | connect_srv | U；DNS SRV 不等于普通主机解析 |
| C08 | reconnect/reconnect_async、disconnect | Client.reconnect/disconnect | U；客户端运行时完成后启用 |
| C09 | connect_bind_v5、disconnect_v5、ext_auth_continue | connect_v5/disconnect_v5/continue_auth | U；显式 MQTT 5 能力 |
| C10 | publish | Client.publish(Message) | U；不调用本地 Broker.publish 假装远端已发送 |
| C11 | subscribe/subscribe_multiple | Client.subscribe/subscribe_many | U；逐项结果和 SUBACK 语义需真实运行时 |
| C12 | unsubscribe/unsubscribe_multiple | Client.unsubscribe/unsubscribe_many | U；真实 UNSUBACK 完成语义 |
| C13 | publish_v5/subscribe_v5/unsubscribe_v5 | 同名 v5 或具名属性选项 | U；不能降级或丢弃属性 |
| C14 | loop_forever、loop_start/loop_stop | Client.run、with_client、stop/wait_stopped | U；结构化任务替代隐式 C 线程 |
| C15 | loop、loop_read/write/misc、socket、want_write | Client.poll/read_ready/write_ready/tick/socket_handle/wants_write | U；没有外部驱动能力前不返回假就绪状态 |
| C16 | threaded_set | 明确的运行模型/线程能力查询 | M/U；配置不能让未实现的线程安全凭空成立 |
| C17 | int_option/string_option/void_option、旧 opts_set | 类型化 ClientOptions | A 仅基本选项；高级传输/TLS 选项 U；不暴露 void 指针 |
| C18 | reconnect_delay_set、max_inflight_messages_set | ReconnectPolicy、ClientLimits | 配置 A；运行语义 U；兼容旧别名需显式映射 |
| C19 | message_retry_set（上游已无效果） | Client.set_retry_policy | U；文档标记旧函数不应作为新设计依据，不伪装成功 |
| C20 | user_data_set/userdata | 闭包捕获或类型化上下文 | M；不提供任意裸指针 |
| C21 | tls_set/tls_opts_set/tls_insecure_set | ClientTlsConfig、证书/验证选项 | 基础配置 A；实际握手及高级选项 U，默认不关闭校验 |
| C22 | tls_psk_set、ssl_get、外部 SSL_CTX/TLS engine | with_psk、tls_info、native_tls_context | U；裸指针由未来 native 扩展适配，不进入通用 DTO |
| C23 | socks5_set | ProxyConfig、Client.with_proxy | U；不能只保存代理参数却实际直连 |
| C24 | pre_connect/connect/connect_with_flags/disconnect 等 callback_set | ClientEvent、Client.on/off 或 events | U；闭包代替 userdata，事件不虚构 |
| C25 | publish/message/subscribe/unsubscribe/log 回调及 v5/扩展认证变体 | 消息、确认、日志、认证等类型化 ClientEvent | U；版本及确认范围明确，不丢 reason/properties |
| C26 | message_copy/free/free_contents | Message 的值/复制语义 | M；有界 payload 副本；资源对象另有 close |
| C27 | subscribe_simple/subscribe_callback | receive_n、consume_messages | U；依赖真实客户端，含超时、取消、条数/字节上限 |
| C28 | 客户端 WS/WSS、ALPN、系统 CA、OCSP 等可选参数 | 对应类型化 Transport/TlsOptions | 未验证功能 U；Broker 已有 WS/WSS 不代表 Client 已有 |

本清单允许配置对象、错误类型和校验先可用，但文档必须明确“Client 网络功能未实现”。客户端示例首轮展示能力检查和错误处理，不能提供必然失败却描述为可运行的远端收发示例。

## 4. MQTT 属性与通用工具

参考 [libcommon.h](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto/libcommon.h)、[属性接口](https://github.com/eclipse-mosquitto/mosquitto/blob/6aaba32614eb1160ddbfeafd616f9f67e7914a41/include/mosquitto/libcommon_properties.h)及其余子头文件。

| ID | Mosquitto 能力/代表符号 | 计划 MoonBit API/替代 | 状态/边界 |
| --- | --- | --- | --- |
| U01 | strerror/connack_string/reason_string/string_to_command | ApiError.message、ConnackCode/ReasonCode/PacketKind | 基础映射 A；未知值保留，不能误报成功；不承诺同整数码 |
| U02 | pub_topic_check/check2、sub_topic_check/check2 | TopicName.parse、TopicFilter.parse | R；String/Bytes 加长度的 C 变体类型化归并 |
| U03 | topic_matches_sub/sub2、sub_topic_tokenise/tokens_free | TopicFilter.matches、topic_levels | R/A/M；使用 MoonBit 值数组，无手动 free |
| U04 | topic_matches_sub_with_pattern、sub_matches_acl/with_pattern | matches_pattern、matches_acl_pattern | U，除非完整证明现有语义等价，不因都有通配符就复用 |
| U05 | validate_utf8 | validate_mqtt_utf8(Bytes) | A；包含 MQTT 禁止字符规则，不只是普通 UTF-8 解码 |
| U06 | property_add_byte/int16/int32/varint/binary/string/string_pair | mqtt5.Properties 及类型化 add | 类型 A；相关语义方法 U，不能代表协议已支持 |
| U07 | property_identifier/next、property_read_* | Properties.iter/read | U；保留类型和签名，范围/重复规则待实现 |
| U08 | property_copy_all/free_all/check_command/check_all | Properties.copy/validate_for(PacketKind) | U/M；不用 C 手动释放，验证不能返回固定 true |
| U09 | property_identifier_to_string/type、string_to_property_info、properties_to_json | PropertyId/PropertyType、parse/to_json | U；JSON 形式不是 MQTT 5 wire 支持 |
| U10 | calloc/malloc/realloc/free/strdup/strndup、FREE 宏 | MoonBit 值/内存管理 | M；不人为增加公开裸内存接口 |
| U11 | memory_used/max_memory_used/memory_set_limit | ResourceStats、BrokerLimits | R/A；指标是逻辑预算，不能冒充与上游同口径的真实内存/RSS |
| U12 | base64_encode/decode、getrandom | 标准编码工具；需要时提供受控 random_bytes | M/R/A；随机源失败必须返回错误，不回退伪随机 |
| U13 | fopen/fgets/read_file/write_file/trimblanks | MoonBit 标准 I/O/字符串库，配置加载提供对应入口 | M；一般文件工具不扩充成 Broker 控制 API |
| U14 | time/time_ns/time_cmp/time_init | MonoTime/Duration 与运行时标准时钟 | M；超时用单调时钟，公开时间区分观测墙钟 |
| U15 | pw_new/cleanup/decode/hash_encoded/verify、参数/状态函数 | PasswordHash/PasswordVerifier 配置契约 | 现有 Argon2 校验可复用；Mosquitto 格式/算法适配 U，不宣称哈希格式通用 |

MQTT 3.1、MQTT 5、MQTT-SN、共享订阅、Bridge、动态安全插件等新增选择均须可识别。协议不支持时返回 UnsupportedProtocol 或对应专用入口的 Unimplemented；不能静默忽略选项。Bridge/共享订阅/MQTT-SN/动态安全 provider 的 enable/register 入口首轮为 U，不因为本表提供选项就进入已支持能力列表。

## 5. 覆盖与验收规则

1. M0 将本表按实际公开签名展开：ID、MoonBit 符号、能力 ID、状态、前置条件、副作用、返回/错误、完成范围、验证用例。原始 C 变体归并后要记录别名去向。
2. R/A 接口完成后才把运行时能力标记 Implemented。U 必须同时具有定义、可调用错误路径和测试；M 必须说明对应的 MoonBit 类型/标准库/所有权模型，不能简单遗漏。
3. 对错误入口逐项验证没有 socket、文件、状态、注册和持续租约副作用。一个枚举包含某选项不代表该选项支持。
4. 新增 typed 入口优先，避免 string + Any/Json 的万用 invoke 接口；DTO 及受控资源对象要能被后续 C adapter 包装。
5. 首轮完成的最低可用链：MoonBit 宿主启动 Broker → 外部 MQTT 客户端订阅 → 宿主 publish → 消息收到 → 宿主查询/精确断开 → 正常停止与资源回收。另以 strict 故障用例验证持久化屏障。
6. 参考快照升级时重新核对，不把 master 的未来变化自动纳入兼容承诺。本表按能力族覆盖，不保证复制每个私有/宏/废弃 C 符号。

参考读取的原始头文件和 SHA-256 清单只保留在远端 `.local/api-plan-mosquitto-20260924/`，不加入发布包。官方在线 API 页面用于辅助解释；本表优先使用上述固定快照。
