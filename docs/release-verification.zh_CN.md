# 发布前测试与验收操作手册

**中文** | [English](release-verification.md)

本手册规定本项目的发布前验证流程，目标是尽早发现开发环境、发布包和实际运行环境之间的差异。它是本项目的工程约定，不是 Mooncakes 对所有模块统一规定的测试清单。

正式发布或提交验收前，以 [严格发布入口](../scripts/verify-distribution-docker.sh) 的完整成功记录为准。日常测试通过、某个阶段打印通过、旧提交通过，均不能代替当前候选版本的完整验证。

## 1. 为什么要同时验证源码、发布包和运行环境

曾经的 Argon2id 测试在开发镜像中通过，但缺少 `libargon2` 时会走到 `Result::unwrap()`，导致测试进程因 SIGABRT 退出。固定密码 fixture 经参考实现核验是正确的；隐藏的系统依赖和错误处理才是已复现的问题。

仅在开发容器里执行 `moon test` 会漏掉以下差异：

| 差异 | 对应检查 |
| --- | --- |
| 本机存在未提交文件、旧编译结果、依赖缓存 | 只归档已提交 HEAD，在新的 Docker 卷中开始构建 |
| 仓库里有文件，但发布包漏装或混入本机文件 | 生成 ZIP、审查内容、解压后重新检查、测试和构建 |
| 编译通过，但运行时动态加载的库不存在 | 四种库组合的独立运行环境，检查实际库清单并触发功能 |
| Debug 正常，但优化后出现问题 | 对解压后的包分别执行 Debug 和 Release 测试 |
| 只有 root、可写根目录或开发工具齐全时才能运行 | 非 root、只读文件系统、独立客户端、无外网的运行检查 |
| 测试后又修改代码、版本或重新打包 | 记录提交号与产物哈希；改变候选内容后重新验证 |

这里的“干净”指不会挂载当前工作区的源码、`_build`、`.mooncakes` 或 `node_modules` 到候选源码卷。工具链镜像仍提供固定的 SDK、核心库和预装工具；同一次构建容器内可复用正常下载的依赖。不要把它理解成每个阶段都重新安装整个操作系统。

## 2. 支持范围与环境准备

开发和用户手动测试在远端唯一工作区进行；GitHub Actions 可临时检出已推送候选运行自动化验证。CI 不是第二个开发工作区，日志/安全白名单产物先保存在 Actions；用户后续要求核验时，再于保留期内归档所需证据到远端。不要在 Windows 本地创建源码副本或安装另一套 MoonBit。

| 项目 | 当前约定 |
| --- | --- |
| 系统与架构 | Ubuntu 24.04 / Linux amd64（x86_64） |
| 编译后端 | `native` |
| MoonBit 编译器 | Dockerfile 中的 `0.10.10+f8a486b6f` |
| Node.js | Dockerfile 中的 `22.23.1` |
| 开发镜像 | `moonbit-mqtt-broker-dev` |
| 依赖版本 | `moon.mod` 和各 `package-lock.json` |
| CI | `release-native` job；75 分钟超时 |

先读取适用的项目指令，检查 Git 和 Docker：

```bash
git status --short --branch
docker version
docker image inspect moonbit-mqtt-broker-dev --format '{{.Id}}'
scripts/moon-docker.sh version --all
```

镜像缺失，或者 Dockerfile / 固定工具链定义有变化时才重建：

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
```

确保有足够磁盘空间创建临时卷、镜像和产物。构建阶段需要访问 Mooncakes、npm 以及 Docker/Ubuntu 软件仓库；“无外网”限制只施加于后面的运行验证容器，不施加于依赖下载和镜像构建。

`MOONBIT_MQTT_IMAGE` 可以覆盖开发镜像名；若使用它，必须说明原因、核对镜像内工具链，并保留实际镜像 ID。相同镜像标签不代表相同镜像内容。

### 系统库与开发工具的区别

| 依赖 | 用途 | Ubuntu 24.04 名称 |
| --- | --- | --- |
| Argon2 动态库 | 运行密码认证，完整原生认证测试也需要它 | `libargon2-1`；加载 `libargon2.so.1`，兼容备用名 `libargon2.so` |
| OpenSSL 动态库 | TLS 配置、握手和加密连接 | `libssl3t64`，包含 `libssl.so.3` 及相关库 |
| 基础 C/GCC 运行库 | 运行本机可执行文件；具体依赖见 `ldd` 记录 | 系统 libc、`libgcc-s1` |
| Argon2 CLI | 独立生成参考 fixture、集成测试的测试数据 | `argon2`，不是 Broker 的运行必需工具 |
| MoonBit、Node、编译器、MQTT 客户端 | 构建、测试、生成数据、作为外部客户端 | 由开发镜像提供，不能因此认为用户环境也有这些工具 |

从 Mooncakes 安装模块不会安装操作系统动态库。验收环境应使用项目 Docker 环境，或按声明安装系统依赖。当前流程不承诺 Windows、macOS、ARM、其他后端或任意 MoonBit 版本可用。

## 3. 分支开发、CI 验证与用户测试

每个新的开发任务先检查 HEAD/status/diff，保留已有修改，在远端创建独立任务分支并记录基线；禁止直接向 main 提交或推送。用户已授权的功能实施按既定流程在任务分支提交/推送触发 CI，不需逐次重新询问；不自动合并、强推、打发布标签或发布。纯计划/文档修订不自动推送。

实现完成、CI 结果、用户剩余必测、正式候选验收分别记录。CI 能覆盖的完整验证直接在 CI 执行，开发机不预跑或补跑同一全套。功能实现后仍有必须执行而适用 CI 未覆盖的测试时，agent 准备固定 SHA、真实命令和保留日志的启动脚本，由用户运行。所有功能实现及相关修复任务的默认出口是：推送任务分支 CI 成功，立即给出分支/SHA、CI 入口或已有 run 链接、用户测试启动/实时日志/结果查询命令，然后结束本轮。CI/用户验证可以仍未完成，不等待、不 watch/轮询、不自动监控或进入修复循环；用户后续要求检查或告知测试完成时再核验。

### 3.1 开发定向验证与功能开发完成

开发期间按当前风险选择少量直接相关用例、单场景进程或必要编译/链接检查；相邻改动合并验证。提交、细分步骤和功能分组结束不自动触发开发侧测试；推送任务分支按实际 CI 工作流触发验证。以下是按需选项，不是每次改动后的命令套餐：

```bash
scripts/moon-docker.sh fmt --check
scripts/moon-docker.sh check --target native --deny-warn
scripts/moon-docker.sh build --target native
```

WAL 提交/恢复、撤权、原生任务 reap、协议顺序、资源账本与新增库依赖在接线时须有定向证明，可来自当前候选 CI；开发侧只保留实现决策或失败最小复现所需验证，缺证据不得宣称通过。
功能、必要测试、脚本和文档全部形成后，默认提交任务分支 CI 集中运行一次该能力的完整功能测试，开发侧不预跑全量，覆盖全部适用功能矩阵和受影响兼容场景。只有后续修复影响已验证范围，才在修复收敛后复测受影响部分；影响广泛或无法隔离时重跑完整功能测试。不预设第二轮，也不设妨碍排障的硬上限。

完整功能测试与全仓累计 release、分发四环境、长 soak、完整性能对照分开；功能开发完成可以早于正式发布候选验收。若齐备后直接进入正式验收，可用严格链内完整功能门履行功能检查，不在前后另跑相同全套。多个能力在同一候选验收时可共用一条严格链。

矩阵编号是断言索引，不是独立运行次数；可共用同一用例、同次进程门禁或经差异影响审查仍有效的开发证据。10000 次压力、性能和四环境不按编号或功能组重复启动；严格入口内部既有门禁必须完整执行。每次运行记录目的、候选 SHA（未提交另记 diff/内容摘要）、命令、参数、日志和退出码；交接仅列变化和关键结果。无代码变化、风险变化或失败待定位时，不为补记录重跑。

`check` 检查类型与警告，不执行测试；`build` 验证生成程序和链接；`test` 才会执行测试行为。`--deny-warn` 把警告也视为失败。

若修改了密码认证，可先缩小范围：

```bash
scripts/moon-docker.sh test src/security/security_test.mbt src/server/broker_runtime_security_test.mbt --target native --deny-warn
```

若当前风险确需独立定位，可在开发容器中运行 fixture/缺库定向检查；完整范围交给 CI：

```bash
docker run --rm --platform linux/amd64 --entrypoint bash \
  --volume "$PWD:/workspace" --workdir /workspace \
  moonbit-mqtt-broker-dev tests/integration/argon2_environment.sh
```

该脚本会调用 `scripts/check-argon2.sh`，将内嵌密码哈希与参考 CLI 比较，再对子进程模拟缺库。它不会覆盖预期哈希。不要通过删除断言、跳过认证测试或使用 `moon test --update` 接受错误结果来“修好”fixture；生成方法见 [安全文档](security.zh_CN.md)。

### 3.2 CI 完整验证与正式候选证据

功能、必要测试、脚本和文档形成后，在任务分支提交并推送，由现有 CI 调用以下严格入口；不在开发机先跑一次再推送。该入口已包括完整累计正确性、包重建与四环境，本轮分工无需先把它拆成不同来源的结果。

```bash
# CI 在被检出的候选上执行；不是开发侧提交前的必跑命令。
git status --short --branch
git log -1 --oneline
scripts/verify-distribution-docker.sh
```

严格入口仅验证实际 HEAD，已跟踪未提交修改或未提交候选文件会被拒绝。根目录未跟踪的 AGENTS.local.md 是维护指令例外（守卫也兼容旧的 AGENTS.md），不进入归档；不能把源码隐藏在忽略目录绕过检查。

实现任务推送后结束，不等于正式验收通过；正式发布/提交验收继续要求同一 SHA、同批产物、完整四环境、哈希和最外层 exit=0。合格的 CI 完整记录可以直接承担这一门禁，不要求远端重跑。PR 临时 merge SHA、开发分支 SHA 与拟发布 SHA 必须明确区分；候选变更后应取得对应新记录，不能拼接不同运行。

现有 push/PR CI 会运行严格分发；“提交验收”不是普通 Git 提交，但不能因此跳过已配置的 CI。性能/扩展 soak 按需求接相应 job/参数。未运行的必需门禁单列待验收，不把推送成功当作验证通过。

### 3.3 CI 优先的性能与 soak

需要扩展 soak 时优先在 CI 启用，避免先跑不带 soak 的同候选完整链：

```bash
RELEASE_SOAK=1 scripts/verify-distribution-docker.sh
```

相关行为形成且确有性能风险或正式候选需要时，性能/长测优先交适用 CI runner；普通开发不运行完整对照。只有指定硬件/磁盘等环境不适用，或尚未由适用 CI 覆盖的必测，才由 agent 列命令交用户运行，agent 不代跑。先用短定向负载核对夹具的连接/限流、等待上界、采样与清理，再做一次正式测量；既定测量协议内部的配对轮数、阈值及正式 soak 时长不减少。夹具失败标为夹具失败/测量未完成，先定位修复并短测，不计产品失败，也不立即重启整套长测。性能与 soak 分开串行执行。需要 soak 的候选直接使用启用 soak 的严格入口，不先额外跑一遍未启用 soak 的同候选完整链。

默认扩展参数为 `RELEASE_SOAK_SECONDS=600` 和 `RELEASE_SOAK_PUBLICATIONS=100000`，实际负载断言由既有稳定性脚本执行。`RELEASE_SOAK=1` 会运行整条严格流程并启用扩展负载，不是仅重跑压力部分。

如改变这两个参数，必须在发布记录中写明数值；不能把较短的自定义试跑称为“默认十分钟 soak 通过”。默认入口不启用 soak；查看 `evidence.txt` 中的 `soak` 值，不凭印象判断。

### 3.4 用户必跑测试的命令、日志与回收

实施交付必须列出 CI 未覆盖的适用必测、具体原因、候选 SHA、前置环境、预计时间/资源、真实启动命令、查看日志/查询结果命令与通过判据。agent 在远端为每项生成 `run-<case>.sh`，交付时不留占位符，也不把未来尚未实现的测试脚本当作可运行命令。用户自行用 tmux/已有调度器启动；agent 在推送成功后提供上述命令即停止，不等待 CI 完成、不等待用户测试、不自动开始完整/长测。没有额外用户必测时明确写“无额外手动必测”。推送失败须报告实际问题，不能冒充成功。

- 每次运行创建唯一目录，例如 `.local/manual-verification/<能力>/<SHA>/<run-id>/`；启动日志也唯一命名，禁止复用 `.local/release-launch.log` 覆盖旧输出。
- 测试开始即持续保存 stdout/stderr，另存命令/参数、候选 SHA、必要环境/镜像、起止时间、任务标识、原始样本/子进程日志和实际退出码。日志持久保存在远端，不能只留在退出后即删的容器里；不得 dump 密钥、token 或全部环境变量。
- 测试输出直接写日志；实时查看使用另一个 `tail -F` 命令。需要管道时必须保留测试退出状态，不能将 `tee` 成功当作测试成功。失败/超时/重试各留独立记录，不覆盖、不删除旧证据。
- 用户运行期间不切换分支或修改候选；需要并行开发时先安排隔离的已提交候选环境。启动和结束核对 SHA/内容，缺少结束记录或被 SIGKILL 时标未完成，tmux 会话消失不代表成功。
- 仅在用户后续要求核验 CI，或回报 RUN_DIR/会话/启动日志位置时，agent 才恢复读取证据；本轮交付后不轮询等待。通过 SSH 读取用户证据，核对命令、完整输出、退出码、断言/阈值、原始数据和哈希。报告已核验、失败或未完成及缺口；不要求用户粘贴大量重复日志，不擅自重启整套。

## 4. 严格入口实际做什么

| 阶段 | 实际动作 | 主要通过标准 |
| --- | --- | --- |
| 1. 固定候选版本 | 检查工作区；记录完整 HEAD；`git archive` 生成 `source.tar` | 候选内容已提交，不带当前工作区文件 |
| 2. 新建源码环境 | 新 Docker 卷解包；确认没有 `.git`、`_build`、`.mooncakes`、根 `node_modules`；创建仅供文件清单使用的临时 Git 索引 | 从归档内容开始，当前工作区未挂载到构建容器 |
| 3. 完整累计验证 | 运行既有格式、类型、原生测试、构建、接口信息生成、协议 oracle、参考 Broker、网络、QoS、持久化、稳定性、示例、关闭、TLS、认证、会话过期、可观测性和配置检查 | 所有阶段成功；不能只看其中一个测试总数 |
| 4. 发布包审计 | 生成 ZIP；检查必需文件、允许路径、禁止的缓存/凭据/运行数据、大小及数量 | ZIP 不含本地残留；当前上限为 500 文件、20 MiB 解压内容、10 MiB ZIP |
| 5. 解包后重建 | 在新目录安装/解析依赖；严格类型检查；Debug 和 Release 测试及构建；检查程序版本；导出 Release 程序 | 实际包能编译、测试、运行；不是拿原工作区的旧程序验证 |
| 6. 四环境运行矩阵 | 实际库清单、静态链接清单、缺库启动失败、独立客户端真实收发 | 正向用例通过，负向用例按约定失败，进程不崩溃 |
| 7. 收尾核对 | 检查 HEAD 与已跟踪文件未变；重新校验 ZIP 和可执行文件哈希；写完成时间与退出码 | 同一份证据对应同一个提交、同一组镜像和同一批产物 |

严格构建还运行额外的关闭周期与源码敏感数据扫描。原生测试数量会随项目变化，214 是引入该流程时的历史数量，不是以后固定不变的验收指标。

### 四种运行环境的正向与负向要求

| Profile | Argon2 / libssl | 必须成功 | 必须按预期失败 |
| --- | --- | --- | --- |
| `base` | 均缺少 | 明文匿名 QoS 1 收发 | 密码认证配置；TLS 配置 |
| `argon2` | 仅 Argon2 | 明文密码认证及 QoS 1；正确密码通过 | TLS 配置；错误密码、缺失凭据 |
| `tls` | 仅 libssl | TLS 匿名 QoS 1 收发 | 密码认证配置 |
| `full` | 两者齐全 | TLS + 密码认证 + QoS 1；正确密码通过 | 错误密码、缺失凭据 |

Broker 镜像必须没有 MoonBit、编译器、Node/npm、Git 和 Argon2 CLI。Broker 以 UID/GID `65532` 运行，根文件系统只读，`/tmp` 为可写 tmpfs，外部网络禁用，同时限制权限、进程数和内存。客户端在另一个容器中共享其网络命名空间，连接 loopback；客户端依赖不会进入 Broker 文件系统。

`ldd` 只检查常规链接依赖，不能完整列出 `dlopen` 加载的 Argon2/OpenSSL。流程还读取 `ldconfig` 清单并实际触发相关功能。

Ubuntu 基础镜像可能自带 OpenSSL，而且基础工具需要同一软件包中的 `libcrypto`。负向镜像因此移除目标 `libssl`/Argon2 动态库文件并刷新加载器缓存，保留基础工具需要的库；正向镜像重新安装对应库。测试判断的是实际可加载的库，而不是仅看软件包是否显示“已安装”。这些镜像是测试场景，不是通用生产镜像模板。

### 为什么负向测试里会看到失败

单独在缺库环境运行认证测试，应当失败；缺少密码库时，Broker 也必须拒绝启用密码认证。回归脚本检查这些失败是否具有正确的退出状态和提示，且没有 SIGABRT / panic，然后自身才返回成功。

不能把认证测试直接失败当成发布通过；也不能把负向测试预期的子进程失败误判为整个验证失败。以最外层严格脚本的最终状态为准。

## 5. 如何确认整体验证真的通过

至少同时满足：

1. 当前运行完整结束，外层退出码是 0。
2. 同一个 `evidence.txt` 包含正确的 `source_commit`、`completed_at`、`exit_code=0` 和四项 `runtime_*=PASS`。
3. 同一个运行的日志包含最终的 `DISTRIBUTION verification passed: committed source, clean package, four isolated runtime profiles`。
4. `artifacts.sha256` 对本次 ZIP 和程序的校验通过。
5. 候选代码、版本和产物此后未改变；需要 soak 的发布还必须有对应启用 soak 的完整成功记录。

`RELEASE verification passed`、`Total tests: ... passed ...` 都可能只是中间输出。不能拼接不同运行、不同提交的阶段结果来宣称一个候选版本整体通过。

结果目录由终端的 `DISTRIBUTION_RESULTS=...` 给出，形式为 `test-results/distribution/<提交前缀>-<UTC时间>-<进程号>/`。不要随意选一个旧目录，也不要只看目录是否存在；失败或未完成的运行同样可能创建目录。

以下为本地完整结果目录的核对示例。将占位符替换为本次实际结果目录，在仓库根目录运行：

```bash
(
  set -euo pipefail
  result_dir='test-results/distribution/<本次RUN_ID>'
  grep -Fx "source_commit=$(git rev-parse HEAD)" "$result_dir/evidence.txt"
  grep -Fx 'exit_code=0' "$result_dir/evidence.txt"
  grep -q '^completed_at=' "$result_dir/evidence.txt"
  for profile in base argon2 tls full; do
    grep -Fx "runtime_${profile}=PASS" "$result_dir/evidence.txt"
  done
  grep -Fq 'DISTRIBUTION verification passed: committed source, clean package, four isolated runtime profiles' "$result_dir/verification.log"
  (cd "$result_dir" && sha256sum --check artifacts.sha256)
)
```

这只是核对已有证据，不会补跑缺失步骤，也不是上传发布的命令。脚本入口在前置检查失败时可能尚未创建结果目录，此时从启动终端或启动日志定位原因。

## 6. 保存哪些证据

| 文件 | 内容与用途 | 默认 CI 上传 |
| --- | --- | --- |
| `evidence.txt` | 完整提交号、时间、soak 标志、镜像 ID、四环境状态、最终退出码与哈希 | 是 |
| `verification.log` | 完整构建/测试/镜像输出和阶段失败位置 | 是 |
| `toolchain.txt`、`dependencies.txt` | 实际工具链与解析出的模块依赖图 | 是 |
| `linked-libraries.txt`、`libraries-*.txt` | 程序链接依赖、各运行镜像的实际库清单 | 是 |
| `missing-*.log`、`runtime-*.log` | 缺库场景和运行场景的结果；故障时可能有 `runtime-failure.log` | 是 |
| `package.zip` | 本次测试的 Mooncakes 候选包 | 是 |
| `artifacts.sha256` | `package.zip` 和 `runtime/broker` 的哈希 | 是 |
| `source.tar` | HEAD 源码归档 | 否 |
| `runtime/broker` | 从包中源码构建的 Release 程序，用于哈希核验 | 是 |
| `runtime/server.key`、证书、测试密码文件 | 本次运行专用的临时测试材料 | 否 |

CI 先将明确允许的结果文件整理到 runner 可读的 `test-results/distribution-upload/`；私有测试数据目录、WAL 文件和密钥不进入上传目录。随后上传的 `distribution-evidence` artifact 保留 30 天，包含 `package.zip`、`artifacts.sha256` 和 `runtime/broker`。在 artifact 对应目录执行 `sha256sum --check artifacts.sha256` 核对两份文件。用户后续要求核验时，agent 须在保留期内把所需证据归档到远端 `.local/ci-evidence/<SHA>/<run-id>/`，并记录 run/job URL。

原始结果按项目约定留在远端，不把整个结果目录同步到 Windows。保存发布记录时引用结果目录、提交号、候选包哈希和 CI run；需要长期保留时，应在 CI 过期前留存允许保存的证据。测试私钥也不应混入源码、正式包或交付给评审的材料；测试数据不能替代生产凭据。

## 7. 失败后怎样处理

| 表现 | 先看什么 | 处理与重跑要求 |
| --- | --- | --- |
| 提示提交改动或发现未跟踪候选文件 | Git 状态；启动日志 | 审阅后提交应包含的内容，重新运行；不要绕过守卫 |
| 缺少开发镜像或工具链不符合约定 | `docker image inspect`、`version --all` | 按 Dockerfile 准备镜像；不能只改标签冒充固定环境 |
| 原生测试提示 `libargon2.so.1` | 运行位置、镜像 ID、库清单 | 使用开发镜像或安装声明依赖；保留测试断言 |
| fixture 不一致/负载夹具失败 | 参考数据、密码换行/`$` 展开、连接限流、等待上界、采样与清理 | 先定位夹具、定向或短测；不算产品失败。修复收敛后，正式候选按完整严格入口重新验收 |
| 编译/断言失败、panic、SIGABRT | 首个实际错误与对应源码；不是仅看最后一行 | 修复代码/测试根因，新增有意义的回归用例，再验证新提交 |
| 运行 profile 的库清单与预期不符 | `libraries-*.txt`、镜像构建日志 | 修正测试环境；不能放宽断言把错误环境算成已覆盖 |
| 权限、只读目录、证书或配置错误 | 对应运行日志和声明的操作边界 | 核对需要写入的位置和文件权限；不要直接改为 root 或关闭 TLS 校验 |
| 下载索引/包、npm 或镜像仓库超时 | 日志里的 URL、阶段和连接错误 | 记作基础设施导致本次验证失败/未完成；恢复后从入口重跑 |
| 没有完成记录、任务中断或 CI 超时 | 启动日志、运行进程、`evidence.txt` | 不算通过；保留日志后重新运行 |
| 提交号或 SHA-256 不一致 | 当前 HEAD、该次 evidence、实际文件 | 将新内容作为新候选重新验证，不能复用旧报告 |

不能仅凭数字退出码归类故障。例如 255 既可能出现在下载失败时，也曾用于报告原生测试进程崩溃。要结合实际错误文本和阶段判断。

本节完整重跑要求针对正式候选验收：开发排障先做必要定向验证，相关修复收敛后再启动完整严格链。失败/中断的正式运行不能拼接阶段或用已有记录补成通过。

网络恢复后重新进入正式验收仍须运行全部检查；不能把失败阶段标成通过，也不能为了成功而换成未记录的本机依赖。正常退出会尝试清理本次临时卷和容器；强制中断若留下资源，只检查和清理本次精确命名的对象，不要在共享服务器上批量 prune。

## 8. 什么改动必须重新验证

以下任一内容变化会使旧正式候选记录失效；待修复收敛并再次提交正式验收时，需要先提交新候选，再生成完整成功记录。这不是要求每次开发改动立即重跑严格链：

- 生产代码、测试、C FFI、构建脚本、依赖声明或 lock 文件。
- 版本号、模块元信息、发布文件范围，以及进入 ZIP 的文档或示例。
- Dockerfile、运行镜像、编译器、Node、系统库或测试负载配置。
- 支持的平台/架构/后端，或者新增了要动态加载的库。

新增外部库时，应同时补充：库名称与支持版本、安装说明、正常功能用例、缺库负向用例，以及相关 profile 的实际库清单断言。若开始声称支持新的系统或工具链，应扩展矩阵，而不是沿用 Ubuntu 24.04 的通过结论。

0.2.0 的版本元数据会在 manifest、CLI、系统指标、包文件名、CHANGELOG、文档和相关测试中显式核对：

```bash
git grep -n 0\.2\.0 -- moon.mod src/cmd/broker scripts tests/integration README.md README.zh_CN.md CHANGELOG.md
```

不要盲目替换测试数据或第三方版本字符串。版本号更新本身也改变候选包，因此不能在验证成功后再临时改版本发布。

## 9. 交付与实际发布

提交给评审或准备发布时，记录：候选完整提交号、声明支持的环境、复现命令、最终成功结果目录、候选包 SHA-256，以及是否启用了默认 soak。若网络故障或某项检查未完成，要明确说明。

本流程只验证候选，不会检查完所有外部评审隐藏用例，也不会替另一台机器安装系统库。评审应使用声明的环境；若对方环境不同，应取得版本/命令/堆栈后按差异复现。

发布必须保持候选内容与成功记录一致。若发布工具重新生成 ZIP，不应未经核对就把另一个 ZIP 当作已经测试的产物；候选内容或打包结果变化后需要重新验证。脚本产生 `package.zip` 不代表它已经上传，也不代表能覆盖注册表中的同版本模块。

完整 soak 成功后，将结果目录通过 `RELEASE_EVIDENCE_DIR` 传给 `scripts/release-check.sh`，并把同一目录的 `package.zip` 设为 `RELEASE_PACKAGE_PATH`。该预检会确认提交、四种运行环境、哈希与待发布包属于同一候选。

可复用的发布记录模板：

```text
候选版本：
完整提交号：
验证命令与 soak 参数：
运行时间（UTC）：
开发镜像 ID / 工具链版本：
四环境结果：base / argon2 / tls / full
最终退出码：
证据目录 / CI run：
package.zip SHA-256：
已知未覆盖环境或未完成步骤：
实际发布的版本、提交与产物对应关系：
```

## 10. 脚本导航与旧入口的边界

| 入口 | 作用 |
| --- | --- |
| [verify-distribution-docker.sh](../scripts/verify-distribution-docker.sh) | 正式发布/验收的统一入口；CI 同样调用它 |
| [verify-distribution-build.sh](../scripts/verify-distribution-build.sh) | 严格流程内部的构建容器步骤，要求 `/workspace` 与 `/results`；不要在宿主机直接调用 |
| [verify-release-docker.sh](../scripts/verify-release-docker.sh) | 在当前工作区运行既有累计回归，适合开发定位；单独运行不包含新的四环境发布验证 |
| [check-package.sh](../scripts/check-package.sh) | 发布文件审计、解包重建；严格流程额外导出并测试 Release 程序 |
| [check-argon2.sh](../scripts/check-argon2.sh) | 用参考 CLI 独立核验内嵌 fixture |
| [argon2_environment.sh](../tests/integration/argon2_environment.sh) | 检查缺库时测试与 Broker 的错误处理 |
| [release-gate.sh](../scripts/release-gate.sh) | 旧的三轮累计回归加 soak；没有自动接入新的四环境入口，不能替代严格发布验证 |
| [release-check.sh](../scripts/release-check.sh) | 只读最终预检；核对候选提交、四环境 soak 证据与待发布包一致 |

CI 在 push、pull request 和手动触发时运行完整严格链。同一分支的 push/PR 使用同一并发组，新开发运行会取消旧运行；手动触发的正式运行使用独立并发组并予以保留。普通本地提交本身不触发 GitHub CI；手动触发可选择 soak。job 超时为 75 分钟。修改 CI 或这些脚本时应同步本手册；artifact 被上传不代表 job 成功。

## 11. 引入流程时的历史验证记录

以下是 2026-09-07 的历史快照，不是对以后 HEAD 的持续通过声明：

- `4c1a396` 的修复经过 Debug/Release 各 214 项测试、认证/ACL/TLS/重启/配置集成测试及 C FFI ASan/UBSan 检查。
- 首次严格流程的源码累计验证和解压包 Debug/Release 测试已通过；运行环境清单检查发现基础镜像自带 OpenSSL，正确阻止了把它算作“缺库环境”。
- 修正缺库环境后，四种实际运行 profile 的独立矩阵全部通过。
- 最终实现提交 `9c693c0` 的两次完整复核分别遇到 Mooncakes Git 索引连接超时、依赖 ZIP 下载超时，退出码均为 255；因此当时没有宣称该提交整条流程通过。
- 默认十分钟 soak 当时未执行。发布前必须另有当前候选的完整成功记录。

QoS 2 日常入口：scripts/verify-qos2-docker.sh。累计 verify-release.sh（分发构建也调用它）
已接入 verify-qos2.sh，包含逐报文握手、已提交阶段 SIGKILL 恢复、MQTT.js/Mosquitto、
1,000 条发布和 100 次重连。工作树验证不能代替已提交候选 HEAD 的四环境严格分发验证。

工作树 Docker 包装器通过进程级 Git 配置仅信任 /workspace，兼容宿主机 UID 与
容器 root 的差异；不修改宿主机 Git 配置，也不放宽任意目录信任。

Protocol, security and large-load functional fixtures explicitly disable rate/IP policy where their workload would exceed the new defaults. Byte accounting remains enabled. Dedicated resource tests cover enabled policy; disabling limits in a functional fixture is not evidence that rate admission passed.


## 资源预算与认证隔离门禁

独立入口 `scripts/verify-resource-limits-docker.sh` 包含 Native 全量测试和资源网络矩阵。累计 `verify-release.sh` 已调用 `verify-resource-limits.sh`，严格 distribution/CI 因而覆盖该门禁。矩阵保持限流开启，覆盖原子 retained/fanout、QoS2 重复与持久桶、真实 Argon2 尝试、TLS 前 IP 门禁、raw 字节单次计费、慢消费者、低预算恢复不改文件及最后快照失败退出。负载用例只对其专用高流量 profile 显式关闭 rate/IP 策略，字节预算持续有效。

`scripts/verify-auth-isolation-docker.sh` 会运行带 sanitizer 的 W/Q 执行器 harness，并以真实 Argon2id m=32768 KiB、t=10、p=1 进行网络负载。在一次密码校验仍未完成的窗口内，测试要求稳定连接完成多次 QoS 1 PUBACK；W=1/Q=1 饱和后必须出现有界的 ServerUnavailable 拒绝，随后还要验证恢复和 worker 关闭。累计 security 门禁调用同一检查。

日志输出 `RESOURCE_RESULTS` 保存逻辑占用断言、RSS 峰值和 PING 延迟；RSS 不与逻辑预算直接等同。快照 FIFO 负向测试同时设置终止和强制结束超时，超时退出不是通过。


## 使用已验证的运行环境缓存

当 Docker registry/代理暂不可用且已有本机成功的四环境记录时，可为单次运行显式设置 `DISTRIBUTION_RUNTIME_REFERENCE`，值为本仓库 `test-results/distribution/` 内的成功结果目录。默认不设置此变量，仍构建运行镜像。

```bash
DISTRIBUTION_RUNTIME_REFERENCE=/absolute/repo/test-results/distribution/<successful-run> \
  RELEASE_SOAK=1 scripts/verify-distribution-docker.sh
```

该模式首先校验参考记录的完成/退出码、四项 PASS、完整提交号、镜像 SHA-256 与 Linux/amd64 平台，并要求参考提交与候选的整个 `tests/runtime` Git tree 完全相同。任一条件不符即拒绝，不能用旧镜像掩盖运行环境配方变化。镜像按不可变摘要选取，映射写入 `runtime-reference.json`，结束时再次验证其哈希。

源码仍只取当前已提交 HEAD，重新构建/打包/解包测试；四环境工具与库清单、真实收发、缺库失败、最终制品哈希检查全部执行。结果标记 `runtime_image_mode=verified-cache-reference` 并保存参考来源；它不表示重新拉取了最新系统包，也不把此前失败的运行改写成通过。恢复后必须从严格入口完整重跑，不能拼接失败运行与旧结果。

发布主机需要 Python 3（标准库即可）运行缓存参考保护测试和解析器；这不是 Broker 的运行依赖，不要求开发/四环境容器安装 Python。严格入口在启动耗时验证前检查此依赖。资源容器门禁只使用镜像已有的 MoonBit、Node、Argon2 CLI 和 OpenSSL。

干净源码与解包目录在正式门禁前执行正常 registry 的 pinned 依赖准备；明确的下载/网络错误最多尝试 4 次（上限可配置为 1—5），每次日志保存于 `dependency-fetch-source/` 或 `dependency-fetch-package/`。类型/编译错误立即失败。这里不注入主机依赖缓存，成功后全部正式检查仍完整运行；耗尽重试仍是失败。脚本保护测试覆盖瞬时恢复、编译错误不重试及持续错误有界退出。

## 管理功能的候选验证

累计发布门禁保留原有管理加密库与只读门禁，并各运行一次
`management_admin.sh`、`management_auth_kick.sh` 和
`management_snapshot_admin.sh`。admin 门禁覆盖按角色隔离的明细、
强 ETag、202/幂等、精确 kick、离线 QoS 2 删除、审计覆盖与缺口、
一万次受保护 Operation 读取及慢读取停机。认证门禁在真实 Argon2
任务处于 `authenticating` 时 kick 精确 ConnectionId，要求 Operation
等到原生任务真正 reap，且迟到结果不能激活连接。快照门禁区分正常退出
最终保存后的删除和运行时删除成功、下次快照前 SIGKILL 的恢复边界。
这些是严格链中的进程门禁，不单独重复一套完整发布验收。

严格分发构建会生成 UID 65532 持有的私有摘要文件及独立客户端令牌。
四个隔离运行环境各测试管理关闭、仅 A 只读，以及 B 明细加操作三种状态；
关闭时管理端口必须不存在。B 状态对已打包二进制执行真实 read、kick 和
离线 delete。`full` 环境仍在 A-only Broker 网络命名空间内运行固定
Prometheus 镜像，要求授权 `up=1`、错误令牌 `up=0` 和
`moonbit_mqtt_broker_build_info=1`。清单显式检查 `libcrypto.so`，
因为 `ldd` 不列出全部 `dlopen` 依赖。保留
`runtime-*-management.log`、`runtime-*-admin.log` 及 MQTT 运行日志。
同一 HEAD、同一批产物哈希、四项 profile PASS 和最外层退出码 0 才能
验收；新增 B 不得替代原有 A-only/关闭覆盖。

以下完整性能协议和阈值保留；后续接线只在相关行为形成且有具体性能风险或进入正式候选时测量，优先接独立 CI job，不能按每条管理测试编号重复运行。当前工作流尚未调用此脚本，也未上传其 JSON/TSV/原始样本；后续接线需补齐安全白名单 artifact（包括完整哈希核验所需的二进制），在可用 runner 不满足实际测量合同前由 agent 列命令交用户运行。短夹具检查与正式测量分别记录；夹具失败按第 3.3/7 节处理。历史管理功能的证据不因本节奏说明被改写。

独立的 `scripts/verify-management-admin-performance.sh` 使用同一
Native 二进制和 32 MiB 父池上限，对比 B 关闭（A-only）与 B 开启。
三轮各预热 10 秒、测量 60 秒，并保持 QoS 0/1/2 负载。B 开启时叠加
每秒一次抓取、每秒五次明细分页及每秒一次离线 Session 操作。每轮
吞吐量至少为 B 关闭组的 90%；PING 与 QoS 1 PUBACK P99 不高于
「基线两倍」和「基线加 20 ms」中的较大值。另跑 60 秒 B 过载，持续
压满查询/游标/命令/Operation，保持 16 个慢 HTTP 读取者；每个 5 秒
窗口必须有成功的 MQTT PING。容器限制为 2 CPU、256 MiB 和 64 个进程。
原始样本、fd 与阈值摘要保存在
`.local/p1-03b-execution/performance-*`。性能门禁与分发 soak 分开，
避免两组负载互相污染。原有 A-only 性能证据仍在
`.local/p1-03a-execution/`。

## P1-02 传输门禁

严格分发链会进入 `scripts/verify-release.sh`，其中
`tests/integration/transports.sh` 在同一 Broker 启动 TCP、TLS、WS、WSS。
MQTT.js 检查四入口 QoS 1 路由及 TCP 到 WSS 的持久会话恢复。
同一用例还验证：WS 启用时缺少 `libcrypto.so.3` 或必需 EVP 符号会明确
失败，而仅启用 TCP 时仍可校验配置。Native package 定向测试覆盖有界
Upgrade、WebSocket 帧边界、验证证书的 WSS，以及私有 TLS 材料捕获。
对已提交候选的完整功能与分发记录由 CI 提供；开发侧只做定向检查。

## P1-04 热更新门禁

累计入口依次运行 reload 生命周期、TLS/WSS 材料轮换、strict 恢复和安全撤权进程测试。安全撤权脚本分别以 off、snapshot、strict 模式验证匿名关闭、密码变更时空闲连接断开，以及 ACL 收紧后的投递阻断。分发证据只放行各模式的摘要和脱敏事件日志；密码库、manifest 和私钥不得上传。导出的二进制还在 base、argon2、tls、full 四种运行镜像中分别执行启用 reload 的 check-config：普通 reload 仅在具备 Argon2 的环境成功，TLS reload 仅在 full 成功；每种 profile 的预期结果写入 `evidence.txt`。

## P1-01 强持久性门禁

已提交候选的 `verify-release.sh` 各调用一次 `durability_transports.sh`
与 `durability_commit.sh`：覆盖 TCP、TLS、WS、WSS，QoS 1/2 重启恢复，
阻塞 fsync 期间另一连接继续响应，以及确认后 SIGKILL 恢复。原生测试覆盖 WAL
格式、残尾修复、检查点故障点、提交排序和 B12 管理命令。严格分发链还用同一
导出程序，在 base、argon2、tls、full 四环境分别以非 root、只读根文件系统和
独立可写持久卷执行 strict 写入、重启与 B12 管理验证。同一份 `evidence.txt`
须同时含四项 `runtime_<profile>_strict=PASS`。

`RELEASE_SOAK=1` 时，strict transport 门禁增加十分钟 QoS 1/2 混合负载
（默认 20,000 条，可用 `STRICT_SOAK_PUBLICATIONS` 调整），保存 JSON
延迟和接收计数。原有稳定性负载的默认 100,000 条保持独立。普通 push CI
不启用扩展负载。固定磁盘上的 off/snapshot/strict 配对性能测量没有合适的
GitHub 托管 runner，须按该提交的远端用户测试命令执行；普通 CI 已提交或短程
开发验证均不能提前算作正式 soak 或硬件性能验收。

远端固定硬件测量入口为 `scripts/run-p1-01-performance.sh`，通过
`PERF_EXPECTED_SHA` 固定完整提交号。正式运行在同一固定开发镜像、
2 CPU、512 MiB 和各自独立 Docker 数据卷上交错执行三轮配对测试。三种模式
均关闭内置全局与每 IP 发布限流，并保存实际 Broker 参数。每轮含低频、
八发布者、256 KiB 消息、八接收者扇出、QoS 2、离线积压；strict 再加按节奏
发送的检查点窗口。保留 ACK 与 QoS 2 PUBREC/PUBCOMP 原始延迟、fsync 跟踪、
WAL 批量大小、CPU/RSS、卷字节和带保留消息核验的重启时间。正式运行要求
每个 strict 轮次生成第二代检查点，并保留测试卷供排查。`PERF_QUICK=1`
只核对夹具，不能算正式测量。根据目标部署的磁盘与延迟预算审阅配对结果；
项目不虚构通用 P99 阈值。
