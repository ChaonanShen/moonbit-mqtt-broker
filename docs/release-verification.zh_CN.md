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

所有命令在 Linux 上的仓库根目录运行。本项目的维护工作在远端唯一工作区进行；不要为了测试而在 Windows 本地创建源码副本或安装另一套 MoonBit。

| 项目 | 当前约定 |
| --- | --- |
| 系统与架构 | Ubuntu 24.04 / Linux amd64（x86_64） |
| 编译后端 | `native` |
| MoonBit 编译器 | Dockerfile 中的 `0.10.10+f8a486b6f` |
| Node.js | Dockerfile 中的 `22.23.1` |
| 开发镜像 | `moonbit-mqtt-broker-dev` |
| 依赖版本 | `moon.mod` 和各 `package-lock.json` |
| CI | `release-native` job；45 分钟超时 |

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

## 3. 三个使用层次

### 3.1 开发时：快速检查尚未提交的改动

```bash
scripts/moon-docker.sh fmt --check
scripts/moon-docker.sh check --target native --deny-warn
scripts/moon-docker.sh test --target native --deny-warn
scripts/moon-docker.sh build --target native
```

`check` 检查类型与警告，不执行测试；`build` 验证生成程序和链接；`test` 才会执行测试行为。`--deny-warn` 把警告也视为失败。

若修改了密码认证，可先缩小范围：

```bash
scripts/moon-docker.sh test src/security/security_test.mbt src/server/broker_runtime_security_test.mbt --target native --deny-warn
```

独立的 fixture 与缺库回归检查在开发容器中运行：

```bash
docker run --rm --platform linux/amd64 --entrypoint bash \
  --volume "$PWD:/workspace" --workdir /workspace \
  moonbit-mqtt-broker-dev tests/integration/argon2_environment.sh
```

该脚本会调用 `scripts/check-argon2.sh`，将内嵌密码哈希与参考 CLI 比较，再对子进程模拟缺库。它不会覆盖预期哈希。不要通过删除断言、跳过认证测试或使用 `moon test --update` 接受错误结果来“修好”fixture；生成方法见 [安全文档](security.zh_CN.md)。

### 3.2 发布或验收前：提交候选代码，再严格验证

先审阅并提交本次候选内容。严格入口只验证 HEAD，不会替你提交、推送、打标签或发布。

```bash
git status --short --branch
git log -1 --oneline
scripts/verify-distribution-docker.sh
```

以下情况会在进入正式验证前被拒绝：

- 已跟踪文件存在未提交修改，包括暂存区修改。
- 存在尚未提交或忽略的候选文件。

根目录未跟踪的 `AGENTS.md`、`AGENTS.local.md` 是明确例外，用于保留维护环境的本地指令。它们仍不会进入 HEAD 归档。不要把源码放进忽略目录来绕过检查，也不要把其他文件改名为指令文件来逃避验证。

终端关闭前需要让长任务继续运行时，可在远端使用一个未占用的 tmux 会话名：

```bash
mkdir -p .local
repo_root="$PWD"
tmux new-session -d -s mqtt-release-verify -c "$repo_root" \
  'scripts/verify-distribution-docker.sh >.local/release-launch.log 2>&1'
```

`.local/release-launch.log` 是本次启动输出，重复使用该命令会覆盖它；每次正式验证的证据另外保存在唯一的结果目录。可用 `tail -n 80 .local/release-launch.log` 查看结果路径。会话退出不等于成功，应检查退出记录；若已有同名会话，使用新名字，不要中断他人的任务。

### 3.3 高负载或重要发布：增加 soak

```bash
RELEASE_SOAK=1 scripts/verify-distribution-docker.sh
```

默认扩展参数为 `RELEASE_SOAK_SECONDS=600` 和 `RELEASE_SOAK_PUBLICATIONS=100000`，实际负载断言由既有稳定性脚本执行。`RELEASE_SOAK=1` 会运行整条严格流程并启用扩展负载，不是仅重跑压力部分。

如改变这两个参数，必须在发布记录中写明数值；不能把较短的自定义试跑称为“默认十分钟 soak 通过”。默认入口不启用 soak；查看 `evidence.txt` 中的 `soak` 值，不凭印象判断。

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
| `source.tar`、`runtime/broker` | HEAD 源码归档、从包中源码构建的 Release 程序 | 否 |
| `runtime/server.key`、证书、测试密码文件 | 本次运行专用的临时测试材料 | 否 |

CI artifact 名称是 `distribution-evidence`，默认保留 7 天。CI 不上传 `runtime/broker`，所以下载 CI artifact 后可单独核对候选包：在对应运行目录执行 `awk '$2 == "package.zip" { print }' artifacts.sha256 | sha256sum --check -`。不要因缺少未上传的可执行文件而误认为包哈希损坏。

原始结果按项目约定留在远端，不把整个结果目录同步到 Windows。保存发布记录时引用结果目录、提交号、候选包哈希和 CI run；需要长期保留时，应在 CI 过期前留存允许保存的证据。测试私钥也不应混入源码、正式包或交付给评审的材料；测试数据不能替代生产凭据。

## 7. 失败后怎样处理

| 表现 | 先看什么 | 处理与重跑要求 |
| --- | --- | --- |
| 提示提交改动或发现未跟踪候选文件 | Git 状态；启动日志 | 审阅后提交应包含的内容，重新运行；不要绕过守卫 |
| 缺少开发镜像或工具链不符合约定 | `docker image inspect`、`version --all` | 按 Dockerfile 准备镜像；不能只改标签冒充固定环境 |
| 原生测试提示 `libargon2.so.1` | 运行位置、镜像 ID、库清单 | 使用开发镜像或安装声明依赖；保留测试断言 |
| fixture 不一致 | 参考生成命令、密码是否意外带换行、`$` 是否被 shell 展开 | 修正数据或实现，独立核验后提交并全量复测 |
| 编译/断言失败、panic、SIGABRT | 首个实际错误与对应源码；不是仅看最后一行 | 修复代码/测试根因，新增有意义的回归用例，再验证新提交 |
| 运行 profile 的库清单与预期不符 | `libraries-*.txt`、镜像构建日志 | 修正测试环境；不能放宽断言把错误环境算成已覆盖 |
| 权限、只读目录、证书或配置错误 | 对应运行日志和声明的操作边界 | 核对需要写入的位置和文件权限；不要直接改为 root 或关闭 TLS 校验 |
| 下载索引/包、npm 或镜像仓库超时 | 日志里的 URL、阶段和连接错误 | 记作基础设施导致本次验证失败/未完成；恢复后从入口重跑 |
| 没有完成记录、任务中断或 CI 超时 | 启动日志、运行进程、`evidence.txt` | 不算通过；保留日志后重新运行 |
| 提交号或 SHA-256 不一致 | 当前 HEAD、该次 evidence、实际文件 | 将新内容作为新候选重新验证，不能复用旧报告 |

不能仅凭数字退出码归类故障。例如 255 既可能出现在下载失败时，也曾用于报告原生测试进程崩溃。要结合实际错误文本和阶段判断。

网络恢复后的重试仍须运行全部检查；不能把失败阶段标成通过，也不能为了成功而换成未记录的本机依赖。正常退出会尝试清理本次临时卷和容器；强制中断若留下资源，只检查和清理本次精确命名的对象，不要在共享服务器上批量 prune。

## 8. 什么改动必须重新验证

以下任一内容变化，都需要先提交，再为新候选生成完整成功记录：

- 生产代码、测试、C FFI、构建脚本、依赖声明或 lock 文件。
- 版本号、模块元信息、发布文件范围，以及进入 ZIP 的文档或示例。
- Dockerfile、运行镜像、编译器、Node、系统库或测试负载配置。
- 支持的平台/架构/后端，或者新增了要动态加载的库。

新增外部库时，应同时补充：库名称与支持版本、安装说明、正常功能用例、缺库负向用例，以及相关 profile 的实际库清单断言。若开始声称支持新的系统或工具链，应扩展矩阵，而不是沿用 Ubuntu 24.04 的通过结论。

当前脚本中仍有针对 `0.1.0` 的文件名、版本断言和旧标签检查。准备下一版本时，应一起核对 `moon.mod`、CLI 版本常量、CHANGELOG、文档和这些断言，例如：

```bash
git grep -n '0\.1\.0' -- moon.mod src/cmd/broker scripts tests/integration README.md README.zh_CN.md CHANGELOG.md
```

不要盲目替换测试数据或第三方版本字符串。版本号更新本身也改变候选包，因此不能在验证成功后再临时改版本发布。

## 9. 交付与实际发布

提交给评审或准备发布时，记录：候选完整提交号、声明支持的环境、复现命令、最终成功结果目录、候选包 SHA-256，以及是否启用了默认 soak。若网络故障或某项检查未完成，要明确说明。

本流程只验证候选，不会检查完所有外部评审隐藏用例，也不会替另一台机器安装系统库。评审应使用声明的环境；若对方环境不同，应取得版本/命令/堆栈后按差异复现。

发布必须保持候选内容与成功记录一致。若发布工具重新生成 ZIP，不应未经核对就把另一个 ZIP 当作已经测试的产物；候选内容或打包结果变化后需要重新验证。脚本产生 `package.zip` 不代表它已经上传，也不代表能覆盖注册表中的同版本模块。

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
| [release-check.sh](../scripts/release-check.sh) | 旧版人工发布预检；有 `0.1.0`、标签和旧记录格式约束，不能直接读取新的 evidence 当作旧记录 |

CI 在 push、pull request 和手动触发时运行；手动触发可选择 soak。修改 CI 或这些脚本时，应同步本手册，并以完整退出结果判断完成，不能仅凭 artifact 被上传判断 job 成功。

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


## P0-02 资源门禁

独立入口 `scripts/verify-resource-limits-docker.sh` 包含 Native 全量测试和资源网络矩阵。累计 `verify-release.sh` 已调用 `verify-resource-limits.sh`，严格 distribution/CI 因而覆盖该门禁。矩阵保持限流开启，覆盖原子 retained/fanout、QoS2 重复与持久桶、真实 Argon2 尝试、TLS 前 IP 门禁、raw 字节单次计费、慢消费者、低预算恢复不改文件及最后快照失败退出。负载用例只对其专用高流量 profile 显式关闭 rate/IP 策略，字节预算持续有效。

日志输出 `RESOURCE_RESULTS` 保存逻辑占用断言、RSS 峰值和 PING 延迟；RSS 不与逻辑预算直接等同。快照 FIFO 负向测试同时设置终止和强制结束超时，超时退出不是通过。


## 使用已验证的运行环境缓存

当 Docker registry/代理暂不可用且已有本机成功的四环境记录时，可为单次运行显式设置 `DISTRIBUTION_RUNTIME_REFERENCE`，值为本仓库 `test-results/distribution/` 内的成功结果目录。默认不设置此变量，仍构建运行镜像。

```bash
DISTRIBUTION_RUNTIME_REFERENCE=/absolute/repo/test-results/distribution/<successful-run> \
  RELEASE_SOAK=1 scripts/verify-distribution-docker.sh
```

该模式首先校验参考记录的完成/退出码、四项 PASS、完整提交号、镜像 SHA-256 与 Linux/amd64 平台，并要求参考提交与候选的整个 `tests/runtime` Git tree 完全相同。任一条件不符即拒绝，不能用旧镜像掩盖运行环境配方变化。镜像按不可变摘要选取，映射写入 `runtime-reference.json`，结束时再次验证其哈希。

源码仍只取当前已提交 HEAD，重新构建/打包/解包测试；四环境工具与库清单、真实收发、缺库失败、最终制品哈希检查全部执行。结果标记 `runtime_image_mode=verified-cache-reference` 并保存参考来源；它不表示重新拉取了最新系统包，也不把此前失败的运行改写成通过。恢复后必须从严格入口完整重跑，不能拼接失败运行与旧结果。
