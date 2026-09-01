# Archive Password Recovery

Windows 本地离线压缩包密码恢复工具。

- Fully offline / local only
- Windows PowerShell 5.1 + WPF
- ZIP / 7z / supported RAR subtype support
- CPU + single GPU
- Dynamic GPU enumeration
- Hashcat GPU backend
- John Jumbo CPU bulk backend
- NanaZip final verification
- Five recovery levels
- Pause / Stop / saved jobs
- Multi-volume recognition, first-volume normalization, and per-volume resume identity checks
- No cloud cracking, telemetry, or archive/password upload

This tool is intended for recovering passwords for archives you own or are authorized to access.

License: GPL-3.0-or-later

This license applies only to this project's original source code; bundled third-party components retain their own licenses.

The bundled John Windows runtime uses `tools\extractors\cygwin1.dll`, whose local file and product version is `3.5.6`; the bundled John build reports Cygwin `3.5.6-1.x86_64`. Cygwin is the Windows runtime dependency for the bundled John/`zip2john` executables. Its official licensing terms are documented at <https://cygwin.com/licensing.html> and the repository copy is in `third_party/licenses/cygwin/`.

## Support matrix

| Archive / encryption type | GPU Hashcat | CPU John bulk | CPU NanaZip verifier | Status |
| --- | --- | --- | --- | --- |
| ZIP WinZip AES (`$zip2$`) | ASCII-compatible candidates | Supported; ZIP uses Windows ACP bytes | Supported | Supported; Unicode route is format-aware |
| ZIP ZipCrypto (`$pkzip$`) | Unsupported | Supported | Supported | Supported |
| 7z AES (`$7z$`) | ASCII-compatible candidates | Supported when the bundled build accepts the extracted record; Unicode uses explicit UTF-8 | Supported | Supported; Unicode route is format-aware |
| RAR5（`$rar5$`，Hashcat mode 13000） | Supported | Supported（John format `RAR5`） | Supported | Supported |
| RAR3-hp（`$RAR3$*0*`，Hashcat mode 12500） | Supported | Supported（John format `rar`） | Supported | Supported |
| RAR3-p compressed（Hashcat mode 23800） | Supported | Bundled John does not accept this record | Supported | GPU verified; CPU/NanaZip fallback |
| RAR3-p uncompressed（Hashcat mode 23700） | Adapter ready; real fixture not verified | Bundled John does not accept this record | Supported | Not verified; CPU/NanaZip fallback |
| Other RAR records | Unsupported | Unsupported | Supported | CPU fallback only |
| Other NanaZip-recognized formats | Unsupported | Unsupported | Supported | CPU fallback only |
| 7z split (`name.7z.001`, `.002`, ...), ZIP split (`name.zip.001`, `.002`, ...) | Current split extractors not accepted | Current split extractors not accepted | Supported when the complete set is present | Supported through first-volume CPU verification; GPU/John extractor fallback is explicit |
| RAR modern/old split naming (`name.part1.rar` / `name.rar`, `name.r00`, ...) | Not verified | Not verified | Not verified without a real RAR set | Naming recognition and missing-volume diagnostics only; no local RAR creator |
| Quick exact candidates | Not used | Not used | Supported | CPU only by design |
| Hybrid with `?w` in the middle | Unsupported | Unsupported | Supported | CPU fallback only |

Bundled third-party components and their accompanying license texts are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). NanaZip / 7-Zip is a locally installed runtime prerequisite and is not bundled in this repository.

## Detailed implementation status

这是一个 Windows 原生、本地运行的压缩包密码恢复工具的第一阶段实现。界面使用系统自带的 Windows PowerShell 5.1 + WPF；Worker 保留本机 NanaZip/7-Zip 兼容命令行验证，并为受支持的 ZIP AES、7z AES、RAR5、RAR3-hp 和真实夹具已验收的 RAR3-p compressed 接入完全本地的 Hashcat OpenCL 和 John Jumbo CPU bulk。项目没有网络客户端、在线破解 API、账号体系、遥测、分析或崩溃上传逻辑。

请只用于自己拥有或已得到授权恢复的压缩包。

## 当前已经实现

- 选择本地 ZIP、7z、RAR 及 NanaZip 可识别的其他压缩文件；也可选择 `.7z.001`、`.zip.001`、`.part1.rar` 或旧式 `.r00` 等分卷文件。
- 通过文件签名和本地 NanaZip 元数据识别格式、加密状态与可见加密方法信息。
- 分卷文件按同目录、同归档基名和同命名方案识别；选择中间卷时自动归一化到首卷，缺少 `.003` 等明显序号会在检查和恢复前阻断。当前真实 7z/ZIP 分卷已验证首卷 NanaZip CPU 检查与加密密码验证；本地 `7z2hashcat`/`zip2john` 对分卷首卷未产生可用记录，因此不会把分卷宣称为 GPU 或 John bulk 支持。RAR modern/old 目前只有命名识别夹具，未宣称真实 RAR 分卷恢复。
- 五级累计式本地恢复等级：1 级快速尝试、2 级常用密码、3 级增强恢复、4 级深度搜索、5 级完整搜索；选择 N 级会按顺序执行前 N 个既有底层策略，找到并经本机验证后立即停止。每个覆盖项有稳定的 CoverageId；已完成项只作完成记账，不会被写进 `SkippedStages`，也不会清除后续覆盖项的断点。
  - `Quick`：用户给出的精确候选密码，可先测试空密码。
  - `Dictionary`：逐行测试本地字典。
  - `Rules`：对本地字典分别生成大小写族（全小写、全大写）与追加族（`+1`、`+123`、`+!`、固定任务年份前一年、固定任务年份、重复最后一个字符）；不会在任务执行中读取动态当前年份。
  - `Mask`：支持 `?l ?u ?d ?s ?a` 和 `??`；一个 `?w` 可将本地字典词与 mask 组合成 hybrid 搜索。
  - `BruteForce`：按用户选择的字符集和最小/最大长度逐步枚举；L5 对标准字符集使用互不重复的 mask 分区，不生成巨型候选数据库或密码文件。
- 内置字符集由应用统一定义：小写 26、大写 26、数字 10、符号 24、总计 86 个字符；GPU mask 会显式传递 Hashcat custom charset，字面量 `?` 会按 Hashcat 规则转义。
- Unicode 输入约定：用户字典必须是严格 UTF-8（可带 BOM），无效字节会在准备阶段明确拒绝，不做替换解码；Quick 是精确候选，只过滤真正的空行，ASCII 空格、全角空格和其他 Unicode 空白都会保留。CPU 候选生成按 Unicode 标量处理补充字符。
- 非 ASCII 字典、Unicode mask 字面量和非 ASCII 自定义字符集会选择 Unicode-safe CPU 路径，不把未经真实端到端验证的 GPU Unicode 结果宣称为成功。7z/RAR 的 John 路径使用显式 UTF-8；当前 NanaZip ZIP 解码器使用 Windows 活动 ANSI 代码页，因此 ZIP John 路径用严格 ACP 字节字典与 John 的 raw `ISO-8859-1` 输入模式，无法由当前 ACP 表示的 ZIP 候选会保留本地 fallback 并给出明确结果。
- L4 的第一个覆盖项是用户自定义 Mask/Hybrid（若填写）；不含 `?w` 时精确计算候选数，含 `?w` 时必须填写本地字典，`?w` 位于首尾可走 GPU，位于中间保持 CPU。其后才是 global/zh 字典覆盖项和首字母大写加 1–4 位数字覆盖项；后者只保留首字母确实发生变化的唯一词，再乘以 1–4 位数字空间。L4/L5 的 ID、数量和累计进度按实际规划计算，重复的年份/混合范围不会重复计数。
- L4 的日期范围与“字典词 + 常见符号”都使用统一的有限生成集适配器：CPU 流式验证与 GPU 临时字典来自同一个候选顺序。常见符号固定为 `@`、`#`、`$`、`_`、`-`，不再生成 `!`；每个语言的候选总量是 L1 字典条目数的 5 倍。旧版已经完成的 `hybrid:L4-word-symbol-*:v2` 是包含新版 v3 的严格超集，只作显式兼容记账，不会反向把 v3 当成 v2。
- Stage 3 的 Rules 明确拆成大小写族和追加族，CPU 与 GPU 使用同一组变形语义；Quick 和自定义 Mask 的覆盖修订号会随配置变化递增，避免复用旧断点。
- GPU 兼容的内置小型、确定性 Coverage 可按原有逻辑顺序组成连续的 MaterializedDictionaryBatch；批次只减少 Hashcat 初始化次数，不改变 CoverageId、候选顺序、候选空间、断点或界面进度。
- CPU 路径始终可用：Quick/少量精确候选和不支持的归档/策略继续由本机 NanaZip 逐候选验证；受支持的 ZIP/7z bulk 字典、规则和有限生成集先交给一次长生命周期的本地 John Jumbo，再只对其报告的候选执行一次 NanaZip `7z t` 最终验证。Unicode bulk 会记录实际使用的 `UTF-8` 或 `WINDOWS_ACP` 编码模式。
- 已接入真实的本地 GPU 执行链：**ZIP WinZip AES → `zip2john` 本地提取 → Hashcat 7.1.2 OpenCL → 单块本机 GPU → NanaZip 最终验证**、**7z AES → `7z2hashcat` 本地提取 → Hashcat mode 11600 → 单块本机 GPU → NanaZip 最终验证**，以及 **RAR → `rar2john` 本地提取 → RAR5 mode 13000 / RAR3-hp mode 12500 / RAR3-p compressed mode 23800 → 单块本机 GPU → NanaZip 最终验证**。RAR3-p uncompressed 的 mode 23700 适配器已按 Hashcat 记录约束接入，但当前真实夹具集没有有效样本，因此明确保持未验收状态。
- Hashcat 只在实际初始化成功的本机 OpenCL 设备上运行，不按“RTX 4070”“780M”等型号字符串硬编码。界面逐块显示真实设备 `<Name> (#<DeviceId>)`；任务以 Hashcat OpenCL 的 Vendor + Name 保存精确 GPU 身份，打开任务时重新枚举，设备消失则明确回退 CPU；未被 Backend 初始化的显卡不会被加入选择框。
- `Auto` 对 `Quick` 保持 CPU；对适合的 ZIP AES 或 7z AES 字典、规则、部分 Mask/Hybrid 和 BruteForce，优先选择实际初始化的 NVIDIA GPU，其次 AMD GPU；格式/加密方式/Backend/策略不支持时会诚实回退 CPU。
- 界面以拖入压缩包、选择 1–5 级、保持 Auto、开始恢复为首屏主线；高级候选参数和设备技术细节默认折叠。运行中显示当前阶段（X/N）、Backend、实际计算设备、已测试/总候选、平滑速度、运行时间、预计剩余、当前范围最坏时间、真实进度条和本地验证结果。
- WPF 主窗口使用 `assets\ArchivePasswordRecovery_Primary.ico` 作为应用图标。
- Worker 的 `pause.flag` / `stop.flag` 控制保留。CPU 在进程内暂停；GPU 使用重定向 stdin 向 Hashcat 发送 `q`，等待它退出并在本地 restore 文件实际存在时保存断点；如果本次退出没有产生 restore，继续操作会重新开始当前 GPU 覆盖项，而不会宣称已保存最新断点。停止同样只在可用时保留本地 Hashcat restore 数据。通过“Open saved job...”可以重新打开保存的任务目录；继续前会校验归档首卷和每个分卷的规范化路径、大小及 UTC 修改时间，缺卷、大小变化或修改时间变化都会明确阻断。升级恢复等级时保留 JobId、归档身份、完整分卷身份、创建时间、任务年份和 UI 文化，暂停/停止且有当前覆盖断点时续跑该覆盖项，Exhausted 时从新增覆盖项开始；Recovered 和 NotEncrypted 会阻止升级。
- 成功候选直接用本机 `7z t` 验证。只有本地验证返回成功时，Worker 才写入 `Recovered` 状态。
- 当前实机已验证到 NVIDIA GeForce RTX 4070 与 AMD Radeon 780M Graphics；两者均由 Hashcat OpenCL 实际执行 ZIP AES、RAR5、RAR3-hp 以及已具备真实夹具的 RAR3-p compressed 候选计算，之后由 NanaZip 本地复验。RAR5 与 RAR3-hp 另有 John Jumbo CPU bulk 实测；RAR3-p 记录不被当前 bundled John 接受时会回退到 NanaZip CPU 路径。

## 运行

双击 [Start-ArchivePasswordRecovery.cmd](Start-ArchivePasswordRecovery.cmd)，或在 Windows PowerShell 中运行：

```powershell
& .\Start-ArchivePasswordRecovery.cmd
```

运行前需要本机可用的 `7z.exe`（NanaZip 或兼容的 7-Zip CLI）。GPU 路径使用项目 `tools\hashcat`、`tools\extractors\zip2john.exe`、`tools\extractors\rar2john.exe` 和 `tools\extractors\7z2hashcat.exe` 中的本地组件；CPU bulk 路径使用项目 `tools\extractors\john.exe` 启动器。程序运行时不会安装、下载或更新任何组件。

操作建议是先使用 `Quick`，再尝试自己的小字典、规则和明确的 mask/hybrid；只有确实需要时才使用限定范围的 brute force。受支持的字典、规则和有限生成集 CPU 搜索会由 John Jumbo 批量处理；不完全可表达的 mask/hybrid/brute-force 仍使用 NanaZip 逐候选 fallback，不会生成巨型临时字典。

## 隐私与本地数据边界

- 归档本体、文件名、路径、提取到的元数据、字典、候选密码和找到的密码都不会上传；程序没有任何 HTTP、云、遥测或在线查询代码。
- Worker 只在当前用户的 `%LOCALAPPDATA%\ArchivePasswordRecovery\Jobs\<任务 ID>` 保存 `job.json`、`progress.json` 和可恢复的 Hashcat restore 数据，以支持暂停/继续。`job.json` 可能包含恢复等级、固定 `RecoveryPlanYear` 与 Quick 候选，`progress.json` 会记录当前阶段、覆盖项断点、累计候选数和被跳过覆盖项的真实原因，并在恢复成功后包含找到的密码。每个 Worker Run 的 GPU/John 归档派生 hash、生成字典、规则文件、John pot/session/status/临时 wordlist、Hashcat 状态流和临时结果都放在 `%LOCALAPPDATA%\ArchivePasswordRecovery\Runtime\<任务 ID>\<RunId>`；John 使用显式 app-owned config、pot、session 与 `--no-log`，不会写入用户 Home、项目源目录或全局 `john.pot`/`john.log`。一个 Run 最多生成一次 ZIP/7z 归档工件（失败也缓存），终态清理该 Run 的临时内容，Jobs 下的持久化任务与 restore 不受影响。Hashcat executable、依赖、device-specific kernel cache 和 dictionary statistics 使用 `%LOCALAPPDATA%\ArchivePasswordRecovery\Cache\HashcatRuntime\<RuntimeKey>` 作为版本化、不可变的工作目录持久保留；内置解压字典使用 `%LOCALAPPDATA%\ArchivePasswordRecovery\Cache\BuiltinDerived\<ResourceVersion>`，内置确定性批次使用 `%LOCALAPPDATA%\ArchivePasswordRecovery\Cache\BuiltinBatches`，不保存用户字典或归档/密码数据。这样可复用编译结果且不写入正式 `tools\hashcat`；`--logfile-disable` 关闭日志，当前 Hashcat 7.1.2 不提供 `--dictstat-disable`，所以 dictstat 只会落在 app-local cache。启动时只清理已无活动进程的应用自有 Hashcat `.log`/`.pid` 残留；终态任务超过 7 天才会自动清理，暂停、停止和失败任务不会被自动删除。
- NanaZip fallback 验证时，候选密码会作为本地 `7z.exe` 的一次命令行参数传递；John bulk 的候选只写入应用自有 Runtime wordlist/pot，并不会写入应用日志或上传。具有本机管理员/进程查看权限的其他软件理论上可在进程运行期间观察本地进程，因此不要在不受信任的本机环境中运行密码恢复任务。
- 程序在完全断网时可运行；网络不是运行组件。

## GPU Backend、格式范围与 Auto

本轮采用 **Hashcat 7.1.2 的 Windows OpenCL Backend**。项目从 `tools\hashcat\hashcat.exe` 调用本地二进制，并通过 `tools\extractors\zip2john.exe`、`tools\extractors\rar2john.exe` 和 `tools\extractors\7z2hashcat.exe` 提取各格式所需的本地恢复记录。RAR 使用 Hashcat 的 mode 12500、13000、23700、23800 模块；RAR3-p 的实际模式由提取记录中的 method 字段分类。发布树只保留实际运行所需的 Windows 模块、OpenCL 源码与提取链，不携带上游压缩包、Linux 模块或无关格式工具。运行时没有下载、更新或联网行为。

`tools\extractors\7z2hashcat.exe` 已与上游 [philsmd/7z2hashcat Version 2.0 Windows 64-bit release](https://github.com/philsmd/7z2hashcat/releases/tag/2.0) 的 `7z2hashcat64-2.0.exe` 做直接字节比对，结果一致；其 Public Domain、署名与免责声明保存在 `tools\licenses\7z2hashcat\`，来源记录也保留在那里。

当前 GPU 范围刻意很窄：

| 归档/加密类型 | GPU 状态 | 说明 |
| --- | --- | --- |
| ZIP WinZip AES（`$zip2$`，Hashcat mode 13600） | 已支持（ASCII-compatible） | ASCII-compatible Dictionary、Rules、普通 Mask、`?w` 位于首尾的 Hybrid、BruteForce，以及可表达的 L4/L5 mask 分区，可使用单块实际初始化的 GPU；非 ASCII 候选选择 format-aware CPU 路径。 |
| ZIP 传统 ZipCrypto（`$pkzip$`） | CPU John | 由本地 `zip2john` 提取后交给 John Jumbo；John 报告的候选必须再经 NanaZip `7z t` 验证。 |
| 7z AES（NanaZip 显示 `7zAES`，`$7z$`，Hashcat mode 11600） | 已支持（ASCII-compatible） | 通过本地 `7z2hashcat` 提取。已实机验收 LZMA2 + 7zAES 且加密文件头的 Dictionary；ASCII-compatible Rules、普通 Mask、`?w` 位于首尾的 Hybrid、BruteForce 共用同一 Hashcat attack-plan 路径，Unicode 候选走显式 UTF-8 的 CPU John/fallback。 |
| 7z 记录无法被本地 extractor / John/Hashcat 接受 | CPU | Worker 显示真实原因并保留现有 NanaZip 五层 CPU fallback；不会伪装为 bulk 支持。 |
| RAR5（`$rar5$`，mode 13000） | 已支持 | `rar2john` 提取后走 Hashcat；John 也支持 `RAR5` bulk；两条成功候选都必须经 NanaZip `7z t`。 |
| RAR3-hp（`$RAR3$*0*`，mode 12500） | 已支持 | `rar2john` 提取后走 Hashcat；John 也支持 `rar` bulk；两条成功候选都必须经 NanaZip `7z t`。 |
| RAR3-p compressed（mode 23800） | 已支持 | 真实 `p1-comment.rar` 夹具已在 NVIDIA/AMD 上验收；当前 bundled John 不接受该记录，CPU 走 NanaZip fallback。 |
| RAR3-p uncompressed（mode 23700） | 未验收 | 记录分类与模块门槛已接入，但当前真实夹具集没有有效 uncompressed 样本；不会把 synthetic 记录写成集成通过。 |
| 其他 RAR 记录、其他格式 | CPU | 保留格式识别和全部五层策略；记录不被本地 extractor/Hashcat/John 接受时显示真实原因并回退 NanaZip。 |
| `Quick` | CPU | 少量精确候选不支付 GPU 启动成本。 |
| `?w` 位于 mask 中间 | CPU | 当前 Hashcat adapter 不伪装支持这类 hybrid。 |

`Auto` 不做基准评分引擎：少量 Quick 选 CPU；可用 GPU backend 且策略支持时只选择一块已实际初始化的 NVIDIA、AMD 或 Other GPU（同级按稳定 DeviceId/Name 排序）；格式/加密/策略不支持时选 CPU。手动 GPU 选择按保存的 Vendor + Name 精确恢复，设备不可用时 UI 会显示原因并使用 CPU fallback，不会把 CPU 工作写成 GPU。

Unicode 端到端回归可用 `JohnUnicodeDictionarySmokeTest.ps1`：测试在本机临时目录生成严格 UTF-8 字典、标准 WinZip AES-256 AE-2 夹具和 NanaZip 7z AES 夹具，验证正确/错误密码、本地 NanaZip 复验、John 的实际编码模式和 Worker 结果；测试不会输出密码、hash 或字典内容。`HashcatRestoreUnicodeRegressionTest.ps1` 另外验证包含 Unicode runtime 路径的 Hashcat restore checkpoint 能在新 Run 中被安全重写。

本机通过 Hashcat OpenCL 实际初始化并验收的设备是：

- NVIDIA GeForce RTX 4070（Hashcat OpenCL device #1）；
- AMD Radeon 780M Graphics（Hashcat OpenCL device #2）。

此机器没有把 CUDA/HIP SDK 当作运行前提；已验收链使用 OpenCL。实际可用性由 Hashcat 初始化结果决定，而非显卡名称。

## 进度与时间估算

- 当当前策略有可靠总搜索空间时，进度是实际的 `tested_candidates / total_candidates`。BruteForce、L4/L5 mask 分区和无词典 mask 在启动前即可计算；Hashcat 的 Dictionary/Rules/Hybrid 进度通过增量读取的本地状态流填入，不会每次轮询重新扫描整份历史文件。
- 总量不可靠时，界面使用不确定进度条，只显示已测试数、当前速度和阶段；不会伪造百分比。
- 速度是本地最近采样的平滑有效速度：新采样权重 35%，此前有效速度权重 65%，降低 Hashcat autotune 或短周期波动造成的跳变。
- “预计剩余”和“当前范围最坏情况”均以当前剩余候选除以该平滑速度计算。它表示**搜完当前已配置范围**的时间；密码若不在该范围内，最终仍会失败，并不承诺一定能恢复密码。

## 架构

```text
WPF UI (ArchivePasswordRecovery.ps1)
  -> local job.json + pause/stop flags
  -> RecoveryWorker.ps1
     -> format inspection / strategy candidate generator / finite generated-set adapter
     -> CPU Quick/unsupported: local NanaZip verifier
     -> CPU supported bulk: one local John Jumbo process -> one NanaZip final verifier
     -> GPU ZIP AES: one cached local zip2john artifact -> local Hashcat OpenCL -> local NanaZip verifier
     -> GPU RAR: one cached local rar2john artifact -> local Hashcat RAR mode -> local NanaZip verifier
     -> GPU 7z AES: one cached local 7z2hashcat artifact -> local Hashcat OpenCL -> local NanaZip verifier
     -> per-Run Runtime directory cleanup
     -> progress.json / local verification result
```

- [src/RecoveryCore.psm1](src/RecoveryCore.psm1)：格式识别、NanaZip 调用、候选生成、设备探测与本地 JSON checkpoint。
- [src/RecoveryWorker.ps1](src/RecoveryWorker.ps1)：后台恢复循环、暂停/停止/继续与结果验证。
- [src/ArchivePasswordRecovery.ps1](src/ArchivePasswordRecovery.ps1)：Windows WPF 主界面。

没有插件市场、数据库服务、账户系统、AI 模块、云端服务或分布式调度。

`ArchiveVolumeSetRegressionTest.ps1` 会在系统临时目录生成真实 7z/ZIP 普通与加密分卷，验证中间卷归一化、首卷 NanaZip 检查、正确/错误密码、Worker CPU 恢复、缺卷阻断、分卷身份 JSON 往返及尺寸变化/缺卷恢复阻断；同时只对 modern/old RAR 做命名识别验证，不伪造 RAR 真实夹具。

## 本地验证

在 Windows PowerShell 中运行：

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\SmokeTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\ArchiveVolumeSetRegressionTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\StrategySmokeTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\ControlSmokeTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\GpuZipBackendSmokeTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\GpuSevenZipBackendSmokeTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\RarBackendSmokeTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\RarControlSmokeTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\GpuControlProgressSmokeTest.ps1 -ArchiveFormat 7z
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\ValidateUi.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\CorrectnessRegressionTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\CumulativeRecoveryRegressionTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\CommonSymbolsGeneratedEquivalenceTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\CommonSymbolsBackendIntegrationTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\ExactGpuSelectionRegressionTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\JohnCpuBackendSmokeTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\JohnPauseResumeRegressionTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\LevelUpgradeResumeRegressionTest.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\RuntimeCacheGitCleanRegressionTest.ps1
```

`ExactGpuSelectionRegressionTest.ps1` 验证真实 Hashcat OpenCL GPU 的 Vendor+Name 精确匹配、旧设备 ID 迁移、Auto 单 GPU 选择与缺失设备 CPU 回退。`JohnCpuBackendSmokeTest.ps1` 验证 ZIP AES、ZipCrypto、7z AES 的 John Jumbo CPU bulk 路径、一次性 NanaZip 最终复验、Quick 旧回退以及 5,000 候选的进程启动次数对比。`JohnPauseResumeRegressionTest.ps1` 验证当前 John 构建暂停后的诚实 `UNSUPPORTED` 恢复声明、无伪造进度，以及从当前 coverage 起点重新开始。

`SmokeTest.ps1` 会在系统临时目录生成一个小型加密 ZIP，验证格式识别、错误密码拒绝、正确密码确认和 Worker 本地验证链路，随后删除测试目录。`StrategySmokeTest.ps1` 覆盖 Quick、Dictionary、Rules、Mask 和 BruteForce 五种策略；`ControlSmokeTest.ps1` 覆盖 CPU 暂停、停止和从 checkpoint 恢复。`CorrectnessRegressionTest.ps1` 覆盖归档身份、固定年份、canonical charset、CommonSymbols v3、L4/L5 去重计数、增量状态解析和 7 天终态任务清理。`TargetedCorrectnessRegressionTest.ps1` 覆盖自定义 Mask/Hybrid、首字母大写数字、Rules 分族、Job 升级冻结字段以及修订号。`CumulativeRecoveryRegressionTest.ps1` 覆盖跨 L1/L2/L3 连续推进、Coverage A→B→C，以及前一/前两项已完成时保留后续二/三项断点的暂停续跑。`CommonSymbolsGeneratedEquivalenceTest.ps1` 验证 CPU 生成顺序与 GPU 临时字典逐项一致，并确认不生成 `!`；`CommonSymbolsBackendIntegrationTest.ps1` 以正式 L4 计划分别验证 CPU 与真实 GPU。`DateRangeGeneratedDictionaryEquivalenceTest.ps1` 和 `DateRangeStopResumeRegressionTest.ps1` 覆盖日期有限生成集、真实 Hashcat 停止、restore 与新 Run 续跑。`LevelUpgradeResumeRegressionTest.ps1` 覆盖 Paused/Stopped 的当前覆盖续跑、Exhausted 的首个新增覆盖、Recovered/NotEncrypted 升级硬阻断。`RuntimeCacheGitCleanRegressionTest.ps1` 验证应用自有 log/pid 清理、运行时 Hashcat 依赖隔离、单次归档工件缓存，以及 GPU Run 前后 Git 状态与项目 kernel 文件保持不变。`GpuZipBackendSmokeTest.ps1` 在临时目录生成 AES ZIP，以 NVIDIA 和 AMD 各执行一次真实 Hashcat OpenCL Dictionary 恢复，并验证最终 NanaZip 结果。`GpuSevenZipBackendSmokeTest.ps1` 在临时目录创建 LZMA2 + 7zAES（加密文件头）归档，先验证 CPU Quick，再以 NVIDIA、AMD 和 Auto 各执行一次真实 Hashcat mode 11600 Dictionary 恢复并完成 NanaZip 复验。`RarBackendSmokeTest.ps1` 使用 `test-fixtures` 中的官方 RAR5、RAR3-hp 和 RAR3-p compressed 夹具，验证本地 `rar2john` 记录解析、Hashcat mode 13000/12500/23800、John RAR5/rar CPU bulk、NVIDIA/AMD GPU 实际执行和每次 NanaZip `t` 最终复验；mode 23700 若没有真实 uncompressed 夹具会明确报告 `NOT_VERIFIED`。`RarControlSmokeTest.ps1` 使用真实 RAR5 夹具验证 GPU 运行、暂停、恢复、停止、打开保存任务后的新 Worker 继续运行，以及可用时的 Hashcat restore。`GpuControlProgressSmokeTest.ps1 -ArchiveFormat ZIP/7z` 以一个临时、不匹配的受限任务验证 NVIDIA GPU 的实际进度采样、停止后旧 Worker 退出、restore resume 启动新 Worker 与 stop；它会短暂占用 GPU，但不会读取用户归档。`ValidateUi.ps1` 只装载 WPF XAML 与必需控件，不会显示界面或读取任何用户归档。

`JohnIncrementalOutputRegressionTest.ps1` 验证 John stdout/stderr 的字节级增量读取、UTF-8 跨 buffer/append 边界、未完成末行以及 truncate/recreate；`JohnDirectWordlistRegressionTest.ps1` 验证内置最终 plaintext stream 直接交给 John 后候选总数、CoverageId、阶段/整体进度与 NanaZip 结果保持一致；`JohnUnicodeDictionarySmokeTest.ps1` 使用标准 WinZip AES 与本地 7z 夹具实测 Unicode 字典路径；`HashcatRestoreUnicodeRegressionTest.ps1` 验证 Unicode runtime 路径的 restore rewrite；`JohnMixedZipSmokeTest.ps1` 验证 bundled John 对混合 `$zip2$`/`$pkzip$` 输入按 format 分组处理。混合格式的单一真实 ZIP 若本机工具无法稳定构造，测试会明确标记 `NOT_VERIFIED`，不会把 synthetic extractor-output 结果写成真实集成通过。
