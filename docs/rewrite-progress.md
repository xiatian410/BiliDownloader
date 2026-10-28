# 重构实施状态

目标：自主完成界面重写、Windows/Linux/Android 多端适配和可用的 Web 下载，并以功能测试、实际渲染和构建验证结果。

## 已落地，仍需最终回归

- Material 3 深浅主题，桌面侧栏、窄桌面导航栏、手机底部导航。
- 新建任务页支持多链接、逐项错误、分集搜索和选择、实际可用画质、保存路径预览；保留分集独立选项与封面保存。
- 多链接不再只取第一个；超过 100 个来源会明确拒绝；稳定视频/分集标识用于防止长标题碰撞。
- 任务筛选、限定当前结果的批量操作、清晰的实际画质名称。
- 平铺目录、仅弹幕任务；Android SAF 支持平铺导出。
- 可复用的纯 Dart 下载执行器及本机 Web 服务，Web 登录接口、任务事件、服务端 FFmpeg、按会话取回文件和页面刷新恢复。
- 原生队列与 Web 服务任务持久化：保留任务选项、文件身份和完成记录；进程重启后未完成任务暂停，手动继续；损坏记录回退并提示，无法读取时停止写入。
- 完成文件发布前记录大小与摘要，恢复时校验已有成品；清除记录与保存进度串行处理，避免已清除任务重新出现；Android 手动导出先保存新位置再删除暂存文件。
- 合并阶段可暂停，显示媒体时间和输出大小；两分钟没有实质进度时停止合并，保留原始音视频。后端确认退出前不允许启动同一任务的新执行器。
- Web 状态按版本处理，旧失败事件不覆盖新的继续结果；提交响应丢失后的重试返回原任务；首批媒体数据立即更新进度。错误提示补充可读的无障碍语义。

## Android 系统目录导出恢复增量

实际问题位于原生文件发布链路：创建 SAF 文档后直接复制，目标 URI 未在复制前持久化；进程被停止会留下部分文件，重试只能报告同名冲突。原先 Activity 各自持有执行器，也不能保证窗口替换期间只有一个写入者。这属于文件发布与生命周期问题，不是 B站接口、字段映射、页面渲染或缓存问题。

现将写入移到应用级串行执行器，以 `AtomicFile` 保存带校验和的导出记录，在写媒体字节前确认目标 URI 已提交。手动继续时核对源文件摘要、目标名称及已写前缀；完整内容吻合时复用原 URI，部分内容吻合时重新写入并读回校验。已完成文件发生变化、未知同名文件或记录损坏时停止，保留文件。Dart 仍先保存任务历史，再删除暂存原件；历史提交失败后再试可以复用原生完成记录。没有增加自动重试、轮询或延时。

主要文件：[恢复状态机](../flutter_app/android/app/src/main/kotlin/io/github/xiatian410/bili_downloader/RecoverableExport.kt)、[Android 存储适配器](../flutter_app/android/app/src/main/kotlin/io/github/xiatian410/bili_downloader/AndroidFileExports.kt)、`MainActivity.kt`、`platform_native.dart`、中英错误文案及 `persistence_test.dart`。

本地 114 项 Flutter 测试、静态分析、格式与差异检查通过；14 项 JVM 测试通过，包含独立进程在复制中、完成记录前后被强制终止，以及外部改动、源文件变化、提供方不执行截断、错误文件名、Unicode 与记录损坏；设备测试 APK 编译通过。新增 [CI 设备测试脚本](../scripts/test_android_device.py) 仅在 GitHub Actions 临时模拟器运行，不在开发机安装系统镜像。测试使用单独测试 APK 中的合成文档提供方，通过正常 URI 授权及实际 Binder/文件描述符调用，检查中断恢复、目标保护、16 KiB 环境的内置 FFmpeg 和 200% 字体界面。设备运行结果待本次 CI 验证，编译成功不等于设备通过。

仍有明确边界：若提供方已经创建文件，但进程在返回 URI 或保存 URI 前被停止，不能仅凭同名文件推断归属，仍要求用户检查目标或另选目录。读回校验不代表断电耐久性保证。导出记录保存在应用私有目录，仅含操作标识、文件名、URI、大小与摘要，不包含媒体正文或账号凭据。此增量不等于完成 Android 后台下载服务，也不能替代真机、第三方云盘提供方及实际系统目录选择器的验收。

Android 行为依据：[DocumentsProvider 权限与目录协议](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/provider/DocumentsProvider.java)、[AtomicFile](https://developer.android.com/reference/android/util/AtomicFile)、[16 KiB 页大小测试](https://developer.android.com/guide/practices/page-sizes)。

## CC 字幕与语言选择增量

此前任务只有弹幕 ASS，没有播放器 CC 字幕。现在“附加文件”提供字幕语言预览、单语言或全部语言选择，默认关闭，选项入队后冻结。预览标明首个已选分集；实际下载逐 CID 查询，校验返回分集身份，保留语言名称与自动生成标记。无字幕、所选语言缺失、空正文、需要登录和接口错误分别报告，字幕失败仍保留媒体成品。

上游正常字幕样本存在 `is_lock=true` 且提供资源地址，参考项目也不据此拒绝下载；已去掉将此字段视为下载权限的误判，以实际接口和资源响应为准。测试同时覆盖带该标记的可读字幕与 HTTP 403 响应，后者仍报告失败。

字段依据为 [播放器接口文档](https://github.com/Chilfish/bilibili-API/blob/master/docs/video/player.md)，并参考用户提供的 [Bili23 字幕处理入口](https://github.com/ScottSloan/Bili23-Downloader/blob/50594cd1f8ef7fe6845826f2642c3ef90fcee804/src/util/parse/additional/subtitles.py)。没有加入自动重试或轮询。任务首次发现字幕后冻结轨道 ID 与语言；手动重做会刷新临时 URL，只请求未完成轨道，原轨道消失时明确报错。已完成的视频、封面、NFO 和其他语言字幕不会再次下载。持久记录与 Web 接口都不包含签名字幕 URL。

外置 UTF-8 SRT 与媒体使用相同基本名，附语言代码；同语言多轨附加轨道 ID，已有文件不覆盖。CDN 下载沿用 HTTPS 域名检查、不带账号 Cookie、不跟随重定向，JSON 上限 4 MiB、最多 20,000 条字幕。时间和字段错误不做静默修正；保留重叠及原顺序，转义文本并规范换行。完整约束见 [Web 服务说明](web-service.md)。当前没有字幕内嵌、样式字幕转换或本地语音识别。

本地 112 项测试、静态分析和 Web/独立服务编译通过。新增测试覆盖大 ID、WBI/CID/EP 字段、登录与空数据区分、SRT 时间/Unicode/大小边界、跨快照单语言重做、原轨道消失、同语言多轨、已有文件保护、暂停与发布中断恢复。320–1440px、深浅主题、中英文及 200% 字体检查包含字幕控件与长语言标签。

Chrome 完整流程通过：预览两种语言且响应不含签名 URL；英语字幕首次失败，在服务重启后单独重做，媒体和中文字幕请求次数不增加；360px 下取回 SRT 并由 ffprobe 识别为 SubRip。关闭整个浏览器后，8 个任务及 32 个附件在服务端完成。截图及结果位于 `artifacts/rewrite/`。真实 B站字幕内容与账号权限仍需另行验证，本地接口样本不能作为实网下载证明。

主要实现位于 [字幕字段与 SRT 转换](../flutter_app/lib/core/subtitles.dart)、[附件执行与恢复](../flutter_app/lib/core/io_download_runner.dart)、[语言选项](../flutter_app/lib/ui/subtitle_options.dart)，并接入任务历史、设置、同源服务及中英文本。

功能提交 `b2a8806` 已推送到 `flutter/migration`，对应的 [Windows/Linux/Android/Web CI](https://github.com/xiatian410/BiliDownloader/actions/runs/40683682232) 四项全部成功。Linux 112 项测试、原生窗口/内置 FFmpeg 及独立密钥环检查通过；Windows 71 项测试通过、2 项平台相关检查跳过，内置 FFmpeg 的窗口集成另行通过。Web CI 完成字幕、附件、整批后台任务及 HTTPS 认证流程。此前 `65e5827` 的构建因修正字段误判而主动取消，不作为最终验收结果。

七个 CI 构建包已临时下载并验证：Windows ZIP/DLL、三个 tar.gz 完整性、三个 APK 签名/ZIP 16 KiB 对齐，以及 26 个 64 位原生库的 ELF LOAD/RELRO 检查通过。独立 Linux Web 服务包在不含 Flutter SDK 的 PATH 和其他工作目录下启动、生成私有密钥、授权、锁定、重启恢复与令牌轮换检查通过。新下载的完整包及解压目录均已删除，只新增约 32 KB 的 `artifacts/ci-b2a8806-validation/`，保存校验和、包验证报告及 CI 浏览器结果；构建包可从上述 Actions 运行下载。原有交付包与数据保留，磁盘可用约 8.2 GiB，没有安装新的大型环境。

本轮公开 B站视频信息接口探测仍返回 HTTP 412，真实账号及字幕下载尚未验收。Android 仍为开发签名，未新增真机或 16 KiB 设备运行证明；Windows DPI 实机验证和 Android 后台/存储恢复仍在待办。未合并 main、发布 Release 或部署服务，整体重构继续进行。

## 自动封面与 NFO 增量

此前封面只能手动保存，任务没有 NFO 或附件重做入口。现已将封面、简介、UP 主信息映射到分集模型并随任务持久化；“附加文件”选项提供自动封面和 NFO，默认关闭，入队后不随设置变化。附件分别报告生成成功、等待或失败。媒体完成后附件失败不会把已有视频判为下载失败；用户可以单独重做失败附件，已完成的媒体与附件不重新请求。

封面、手动保存和 Web 封面代理共用读取逻辑：已知图片域名的普通 HTTP 地址及协议相对地址规范为 HTTPS，不携带账号 Cookie、不跟随跳转，读取上限 16 MiB，按内容识别 JPEG/PNG/WebP/AVIF 后选择扩展名。其他来源与非标准端口不会因此放行。已有文件不覆盖。附件沿用带摘要的文件发布记录，恢复中断的发布时先核对已有内容，再完成导出；历史记录写入错误必须中止，不能作为普通附件错误忽略。

NFO 使用与视频相同的基本文件名和 `.nfo` 扩展名，封面为相同基本名加 `-poster` 和真实图片扩展名。命名依据为 [Kodi NFO 文档](https://kodi.wiki/view/NFO_files/Movies) 和 [本地图片文档](https://kodi.wiki/view/Movie_artwork)。每分集作为独立视频条目保存标题、简介、UP 主标签与 B站稳定标识，保留换行、转义 XML 特殊字符；不推测外部数据库 ID、评分、日期或季号。当前没有整部剧的 `tvshow.nfo`/季目录组织，音频任务的 NFO 仍描述来源视频，不能作为完整音乐资料库支持。未进行真实 Kodi 导入验证。

本地 101 项测试、静态分析及 Linux 原生窗口/FFmpeg 集成通过。新增检查覆盖 API 字段映射、错误格式与超限图片、附件失败后跨快照恢复、只重做失败附件、暂停恢复、同名文件不覆盖、发布中断和 SAF 导出提交顺序。320–1440px、深浅主题、中英文及 200% 字体覆盖展开后的附件选项。发现并修复了折叠区与滚动位置的状态存储标识冲突。

Chrome 完整流程已验证封面首次失败后的单独重做、媒体请求次数不增加、服务重启后同一任务取回 PNG/NFO，以及手机宽度下点击下载封面并解码。关闭整个浏览器后，8 项任务连同 16 个附件继续在服务端完成。独立 HTTPS 认证浏览器回归通过。结果与截图保留在 `artifacts/rewrite/` 和 `artifacts/access/`。

功能提交 `286897e` 已推送到 `flutter/migration`，对应的 [Windows/Linux/Android/Web CI](https://github.com/xiatian410/BiliDownloader/actions/runs/40678731894) 四项全部成功。Linux 101 项测试、原生窗口/FFmpeg 及密钥环检查通过；Windows 61 项测试通过、2 项平台相关检查跳过，内置 FFmpeg 的窗口集成另行通过。Web CI 完成上述附件、后台整批下载和 HTTPS 认证场景。

七个 CI 构建包已临时下载并验证：Windows ZIP/DLL 和三个 tar.gz 完整性、三个 APK 签名/ZIP 16 KiB 对齐，以及 26 个 64 位原生库的 ELF LOAD/RELRO 隔离检查通过。独立 Linux Web 服务在没有 Flutter SDK 的 PATH 和其他工作目录下启动、生成私有密钥、授权、锁定、重启恢复与令牌轮换检查通过。验证后完整临时包及解压目录均已删除，本地只新增约 28 KB 的 `artifacts/ci-286897e-validation/`，包含校验和、包验证报告和 CI 浏览器结果；构建包可从上述 Actions 运行下载。磁盘可用空间约 8.4 GB，没有安装新的大型环境。

公开 B站视频信息接口本轮探测仍返回 HTTP 412，真实账号下载仍未验收。Android 包仍为开发签名，没有新增真机运行证明；SAF 检查是文件发布回调样本，不能代替真实文档提供方。未合并 main、发布 Release 或部署服务。

## Web 访问认证增量

增加独立于 B站登录的服务访问密钥、12 小时授权、锁定与重新授权。HTTPS 远程模式仍由本机反向代理转发，服务端严格核对配置的 Host/Origin；Cookie 使用 Secure、HttpOnly、SameSite=Strict 和 `__Host-` 前缀。成功授权轮换令牌，原工作区保持不变；授权过期或锁定不停止后台任务。没有增加轮询或自动重连，事件连接通过每工作区一个有上限的到期计时器关闭。

浏览器只保存不具备授权能力的工作区标记。Cookie 丢失或失效后明确提示创建新工作区，原任务和文件不会被清除；锁定前的未提交输入可保留。锁定会关闭私有弹窗，隐藏工作区不参与焦点和无障碍导航。损坏记录回退到旧版本时要求重新授权，避免恢复旧记录中已撤销的访问权。密钥生成器不打印内容、不覆盖已有文件；POSIX 权限在写入内容前设为 0600。

本地 92 项测试、静态分析、格式与差异检查通过；Linux 原生窗口及 FFmpeg 集成通过。Chrome 本地 HTTPS 代理验证了错误密钥、授权下载解码、跨工作区拒绝文件访问、锁定/过期/服务重启后的原任务恢复、草稿保留以及清除 Cookie 后明确创建新工作区。原有本机浏览器完整流程和 8 项后台批量下载回归也通过。大字体登录页与隐藏工作区的无障碍隔离另由组件测试覆盖。认证样本不代表真实 B站账号验证，也未部署真实域名证书。

功能提交 `2a67b59` 已推送到 `flutter/migration`，对应的 [Windows/Linux/Android/Web CI](https://github.com/xiatian410/BiliDownloader/actions/runs/40674874367) 四项全部成功。Linux 92 项测试、原生窗口/FFmpeg 与独立密钥环检查通过；Windows 52 项测试通过、2 项平台相关检查跳过，内置 FFmpeg 的窗口集成另行通过。Web CI 完成 HTTPS 认证流程和原有完整下载流程，包含关闭浏览器后继续完成 8 项任务。

七个构建包保存在 `artifacts/ci-2a67b59/`，附 `SHA256SUMS.txt`、`validation.json` 和 `package-access.json`。Windows 必需 DLL、ZIP 与三个 tar.gz 完整性检查通过；三个 APK 的签名、ZIP 16 KiB 对齐及 26 个 64 位原生库的 ELF LOAD/RELRO 隔离检查通过。Android 仍为开发签名，尚无真机运行结果。

CI 生成的独立 Linux Web 服务包在不含 Flutter SDK 的 PATH 和其他工作目录下验证通过：密钥生成权限为 0600、拒绝覆盖已有密钥、配置的远程来源正常启动、错误 Host/密钥被拒绝、授权使用 Secure Cookie、服务重启及锁定后重新授权保留同一工作区、旧令牌失效。持久记录不包含原始密钥或令牌。该检查通过回环 HTTP 模拟代理转发，实际 TLS 浏览器行为由上述 HTTPS 浏览器测试覆盖。

配置与测试命令见 [Web 服务说明](web-service.md)。本地认证截图和结果位于 `artifacts/access/`，CI 对应结果在新构建包目录的 `access/`。本轮新增构建产物约 226 MB，临时解压目录已删除；没有安装新的大型运行环境，磁盘可用空间约 8.4 GB。未合并 main、发布 Release 或部署远程服务。

## Web 整批队列增量

此前 Web 使用浏览器本地队列控制提交，超过页面并发数的待下载项尚未发送给服务端，关闭页面会丢失这些排队项。现已改为服务端持有整批任务，浏览器通过单条事件连接观察队列；记录完整保存后才进入调度。服务端并发设置持久化并同步到各页面，排队项可以直接暂停。

连接中断保留最后收到的任务状态，提示后台状态暂时未知；重新连接使用服务端完整快照同步。关闭页面只释放连接，不暂停服务端工作。批量提交使用稳定提交标识，HTTP 响应丢失时可由事件确认；两个通道都未确认时，重试仍返回原任务。初始化期间关闭页面不会继续提交任务或设置。

本地验证：82 项 Flutter 测试、静态分析、格式与差异检查通过；Linux 原生窗口与内置 FFmpeg 集成通过。新增测试覆盖整批校验失败、历史写入失败、8 项任务跨服务重启恢复、并发设置响应乱序，以及关闭页面时的连接清理。Chrome 完整流程通过：8 项中有 1 项运行、7 项排队时关闭整个浏览器进程，服务端随后完成全部任务；重新打开 Flutter 页面取回最后一项，音视频解码通过。截图及 `browser-result.json` 保留在 `artifacts/rewrite/`。

功能提交 `5e79c2d` 已推送，新的 [Windows/Linux/Android/Web CI](https://github.com/xiatian410/BiliDownloader/actions/runs/40669497128) 四项全部成功。Linux 82 项测试、原生窗口/FFmpeg 集成及独立密钥环检查通过；Windows 44 项测试通过，2 项平台相关检查跳过，内置 FFmpeg 的窗口集成另行通过。Web CI 也完成上述 8 项后台批量场景。

七个构建包保留在 `artifacts/ci-5e79c2d/`，附 `SHA256SUMS.txt` 与 `validation.json`。Windows 必需 DLL 和 ZIP 校验通过，三个 tar.gz 完整性通过；CI 的独立 Linux Web 服务包在不含 Flutter SDK 的 PATH 和其他工作目录下启动成功，页面/会话返回 200，并发设置在重启后保留。三个 Android APK 的签名、ZIP 16 KiB 对齐以及 26 个 64 位原生库的 ELF LOAD/RELRO 隔离检查通过，仍为开发签名。Android 模拟器初始化因可用磁盘不足停止，本轮新增的模拟器及镜像已清理；没有 Android 设备运行结果，不能用包检查代替真机验证。未合并 main 或发布 Release。

## 已提交基线 bcc38a3 的证据

- 72 项 Flutter 测试通过，静态分析与差异检查通过；320/360/600/900/1440px、200% 字体、中文浅色及英文深色均覆盖。
- Web Release 与独立 Linux Web 服务编译通过；Chrome 本地样本完整链路通过，包含真实 FFmpeg 合并与成品解码、页面刷新、WebService 实例重启后字节一致、扫码登录接口样本、仅音频/弹幕、部分字节暂停恢复、失败重试、WebSocket 断线恢复，以及提交成功但响应丢失后的幂等重试。扫码样本不代表真实账号验证。
- 暂停样本实际发出从第 3469 字节开始的 Range 请求；重连和丢失响应后的继续操作保持原任务 ID，没有重复下载任务。原生执行器的合并取消测试确认两条源流保留，重做合并只探测身份，不重传完整正文。
- 独立 Dart 进程的文件锁与强制终止写入测试通过；覆盖单份/双份记录损坏、写入失败阻止下载、任务恢复需明确继续、文件生成与状态记录之间中断、现有成品变化拒绝覆盖。
- Web 未完成任务重启后保持原 ID、暂停后手动恢复测试通过。Android 导出提交顺序通过 MethodChannel 样本测试，不能代替真机文档提供方测试。
- 服务端接口测试验证完整字节下载、跨会话文件拒绝、同源写入约束和 Cookie 不返回浏览器。
- 本轮重新运行生产服务二进制，页面与会话接口返回 200；真实 B站请求仍返回 HTTP 412，未验证真实账号下载。
- 功能提交 `bcc38a3` 的 [Windows/Linux/Android/Web CI](https://github.com/xiatian410/BiliDownloader/actions/runs/40662260440) 全部成功。三个 Android ABI 的 APK 签名、ZIP 16 KiB 对齐检查通过，26 个 arm64/x86_64 原生库的 ELF LOAD 对齐和 RELRO 与后续可写区域隔离检查通过；检查依据见 [Android 官方说明](https://developer.android.com/guide/practices/page-sizes)。这些是静态检查，Android 尚无真机和 16 KiB 设备运行结果，APK 仍使用开发签名。
- 从本轮 CI 下载的独立 Linux Web 服务包，在不含 Flutter SDK 的 PATH 和其他工作目录下启动成功，页面与新会话接口返回 200。Windows ZIP 与三个 tar.gz 结构/完整性检查通过。
- Linux 原生集成测试通过：实际窗口加载，内置 FFmpeg 生成、合并并解码两条音视频轨道，以及取消单个 FFmpeg 会话而不影响并行会话。
- 本轮 Windows 的 34 项恢复/下载/合并检查通过，2 项跳过：Unix 符号链接与外部系统 FFmpeg；Windows 内置 FFmpeg 的实际合并、单会话取消及并行会话继续由原生窗口集成测试覆盖并通过。Linux 的 72 项测试、原生窗口/FFmpeg 集成和密钥环检查也通过。
- 七个构建包已下载到 `artifacts/ci-bcc38a3/`，附 `SHA256SUMS.txt` 与 `validation.json`。Web CI 保存 Chrome 流程结果、截图和测试成品。未合并 main 或发布 Release。

## 仍必须完成

1. 最终差异审查与剩余交互回归，继续覆盖不同浏览器和实际系统环境。
2. 合并停止与恢复能力的设备验证；原生库若未确认停止，任务保持等待并提示重启，不冒险并发写入。当前进程中断测试不能作为突然断电或硬件故障保证。
3. Web 认证配置在实际部署环境中的验证，以及真实接口和账号权限。当前已完成本地 HTTPS 代理与浏览器会话测试；服务重启后需重新登录 B站。
4. Android 后台下载/通知与真机存储体验，Windows DPI 实机验证。SAF 导出恢复已加入持久记录与内容校验，仍需本轮设备验证；在创建目标但 URI 尚未提交的狭小窗口被终止时，仍需人工核对，不能冒险接管未知文件。
5. 命名模板、完整媒体库组织，以及合集/UP 主/收藏夹等计划能力继续分阶段实现并验证；CC 字幕与语言选择、自动封面及基础 NFO 已落地，真实来源验证仍未完成。
6. 后续功能增量继续执行四平台构建、包验证和回归；正式 Android 签名与发布尚未配置。

本阶段作为独立增量提交到 `flutter/migration`，通过 GitHub Actions 继续检查 Windows/Linux/Android/Web 构建，不合并到 main。远程结果以实际运行记录为准。目标保持进行中；以上通过的窄范围检查不能作为整个重构完成的证明。
