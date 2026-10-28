# Flutter 迁移与验证记录

本文件保留最初迁移阶段的验证结果。最新功能、构建及设备测试状态请看 [重构实施状态](rewrite-progress.md)。

本地验证日期：2026-10-28（北京时间）。原始代码基线：`6ec4d8871ead88fd73efb555856087c4c90c9d62`。Flutter 源码位于 `flutter_app/`，原 Python/PySide 源码 `src/` 保留。

## 改动范围

- `flutter_app/lib/app.dart`、`app_controller.dart`：四个主标签、四步下载流程、设置、二维码登录、中英双语和窄屏布局。
- `flutter_app/lib/core/`：BV/AV/MD/EP 解析、B站响应映射、WBI 签名、下载队列和普通 ASS 弹幕转换。
- `flutter_app/lib/platform/`：原生流式下载、断点资源校验、FFmpeg 合并、文件保存与 Web 条件导入。
- `flutter_app/android/`：Android 工程和系统目录授权/导出桥接。
- `flutter_app/linux/`、`windows/`、`web/`：各平台启动工程、资源和构建配置；Linux 包含可取消的异步系统密钥环桥接。
- `flutter_app/test/`、`integration_test/`：接口、本地 HTTP 下载、队列、界面、真实 FFmpeg 测试。
- `scripts/build_flutter.*`、`.github/workflows/flutter-build.yml`：本地构建和四平台 CI；`scripts/test_flutter_web.cjs`：真实浏览器验证。

## 已验证与待验证

| 项目 | 结果与范围 |
| --- | --- |
| Dart 格式与静态检查 | 通过，`flutter analyze` 无问题 |
| 单元和组件测试 | 27 项通过；接口使用本地 HTTP 服务，未冒充真实 B站联调 |
| Linux FFmpeg 集成 | 真实 Flutter 窗口中生成视频/音频、合并并强制解码两条轨道，通过 |
| Linux 凭据集成 | 独立 D-Bus 和临时系统密钥环中，实际写入、读取、删除测试通过；未操作用户原有凭据 |
| Linux Release | x64 发布包构建通过；真实发布程序启动、显示完整界面及密钥环超时提示通过 |
| Android | arm64-v8a、armeabi-v7a、x86_64 三种 Release APK 在本地和 CI 均构建通过；本地 APK 开发签名验证和 ZIP 16 KiB 对齐检查通过；最低 API 24、目标 API 36；尚无设备运行验证 |
| Windows | `windows-2022` runner 上原生窗口、FFmpeg 音视频合并与双轨解码测试通过；x64 Release ZIP 已生成并下载，ZIP CRC、PE 架构、exe/DLL/资源完整性检查通过 |
| Web | Release 编译通过；Chrome 桌面/360px 窄屏可渲染，无 JavaScript 异常；原生下载和扫码登录在预览中禁用 |
| B站真实请求 | 当前出口对公开视频接口返回 HTTP 412；浏览器接口请求另被 CORS 拒绝，未完成真实账号登录/视频下载验证 |
| GitHub | `flutter/migration` 已推送；源码提交 `dcea31b94254cef3af8890b0e6b01f8f91ae23ed`；Windows/Linux/Android/Web 四个 CI 任务全部通过 |

## 已定位并修复的实际问题

1. Linux FFmpeg 插件自带动态库缺少相对搜索路径，实际执行时无法加载。安装阶段对 FFmpeg 相关库设置 `$ORIGIN`，真实合并/解码测试通过。
2. 系统密钥环无响应时，原先等待凭据读取再 `runApp` 会导致窗口不出现。Linux 上已改为 libsecret 异步系统调用，4 秒后取消，避免插件同步调用阻塞 GTK 主线程；Dart 先绘制加载界面并对存储设置 5 秒上限。迟到的旧登录读取不会覆盖新登录。没有明文凭据降级，也没有清空原会话文件。
3. Android 首次并行构建时，其他 Flutter 命令重写共享插件注册文件，导致 Release 引用测试插件。改为同一工作区串行执行后，三种 APK 编译通过；CI 各平台使用独立任务。
4. 恢复下载先校验长度及 ETag/Last-Modified，检查 Content-Range；服务器忽略 Range 时从头写入，避免错误拼接。已有目标文件不会直接覆盖。
5. Android 通过 Storage Access Framework 选择目录并导出，使用 app 私有目录暂存；导出失败保留文件，可以重试导出。

下载重试沿用原版有限重试策略，最多 3 次；失效媒体链接仅刷新 1 次。二维码状态查询间隔沿用原版 1.2 秒，最多 150 次，关闭窗口会取消请求。队列由任务状态变化触发，没有新增后台轮询。

## Web 结论

可以制作 Flutter Web 界面；当前纯静态预览不能完成完整下载流程。真实 Chrome 从本地站点访问视频信息、nav、二维码生成三个接口，均报告缺少 `Access-Control-Allow-Origin`，`fetch` 返回 `TypeError: Failed to fetch`。这证明当前访问条件受浏览器跨域限制，不能解释成 Flutter 字段或渲染故障，也不能保证 B站在其他出口的响应相同。

完整 Web 版需要后端负责 B站请求、服务端会话、受限的媒体转发/下载和 FFmpeg 合并，然后把成品提供给浏览器。浏览器不能直接复用原生 Cookie/Referer/Set-Cookie、文件路径与 FFmpeg 插件。当前未搭建或部署该后端。

复验：

```sh
# 终端一，在仓库根目录
python3 -m http.server 18743 --bind 127.0.0.1 --directory flutter_app/build/web
# 终端二
cd scripts
npm ci
npx playwright install chromium
npm run test:web
# 已装 Chrome 时可用 CHROME_PATH=/usr/bin/google-chrome npm run test:web
```

脚本保存 `artifacts/web-probe.json` 和桌面/手机截图；不会关闭浏览器跨域安全检查。

## 交付限制

- Android APK 使用开发签名，适合安装测试，正式分发前需配置自己的发布签名。
- Android 尚未验证真机上的扫码、系统目录授权、合并和文件导出；下载需要应用在前台。APK 静态校验不能替代 16 KiB 页大小设备实测。
- Windows 已完成 CI 原生集成测试与 Release 编译；真实用户设备上的扫码登录和 B站下载仍待验证。解压时必须保留完整目录中的 DLL 和 `data/`。
- Linux 本地包在 Ubuntu 26.04 x64 上构建/验证；CI 的 Ubuntu 24.04 构建与原生测试也已通过。运行需要 GTK 3、libsecret、JSON-GLib；尚未证明兼容更旧发行版。
- 当前没有跨重启恢复队列，也没有复用旧版私有自动更新服务；高级定位/脚本弹幕未迁移，普通滚动/顶部/底部弹幕已实现。

平台边界依据：[Flutter 桌面支持](https://docs.flutter.dev/platform-integration/desktop)、[Windows 构建环境](https://docs.flutter.dev/platform-integration/windows/setup)、[Flutter Web FAQ](https://docs.flutter.dev/platform-integration/web/faq)。

## 本地产物

产物在根目录 `artifacts/`，不纳入 Git：

- `BiliDownloader-windows-x64.zip`：Windows x64 发布包，解压完整目录后运行 `bili_downloader.exe`。
- `BiliDownloader-linux-x64-ubuntu24.tar.gz`：Ubuntu 24.04 CI 构建并通过原生测试的 Linux x64 包。
- `BiliDownloader-linux-x64.tar.gz`：解压完整目录后运行 `./bili_downloader`，不能只复制可执行文件。
- `app-arm64-v8a-release.apk`：常见 64 位 Android 设备。
- `app-armeabi-v7a-release.apk`：32 位 ARM Android 设备。
- `app-x86_64-release.apk`：x86_64 Android 环境。
- `BiliDownloader-web-preview.tar.gz`：静态 Web 可行性预览。
- `SHA256SUMS`：本地发布产物的 SHA-256 校验值。
- `android-validation.json`、`windows-validation.json`、`web-probe.json` 和 `*-desktop.png` / `web-mobile.png`：本次静态校验与浏览器/桌面截图证据。

远程源码：[flutter/migration](https://github.com/xiatian410/BiliDownloader/tree/flutter/migration)。构建记录：[Actions #40543068783](https://github.com/xiatian410/BiliDownloader/actions/runs/40543068783)，对应源码提交 `dcea31b94254cef3af8890b0e6b01f8f91ae23ed`，四个平台均通过。CI 产物按工作流配置保留 14 天；Android 的 CI 测试包使用 runner 生成的开发签名，与本地测试包签名可能不同，不应当作正式更新包。GitHub 授权已完成，分支已成功推送；没有合并到 main 或发布 Release。
