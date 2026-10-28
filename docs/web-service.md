# Flutter Web 下载服务

Web 界面通过同源服务调用 B站接口、下载媒体和执行 FFmpeg。浏览器通过 WebSocket 接收任务进度，完成后通过带会话校验的文件接口取回成品。B站 Cookie 保留在服务端内存中，不返回给前端。

## 本机运行

需要 Flutter/Dart 和 PATH 中的 FFmpeg。从仓库执行：

```bash
cd flutter_app
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn
dart run bin/web_server.dart
```

打开 `http://127.0.0.1:18743`。可通过 `BILI_WEB_PORT`、`BILI_WEB_ROOT`、`BILI_DOWNLOAD_ROOT` 设置端口、前端目录和下载根目录。默认根目录为 `flutter_app/web-downloads`，已经加入 Git 忽略规则。

独立可执行文件可用 `dart build cli -t bin/web_server.dart` 构建，产物位于 `build/cli/linux_x64/bundle/`（按构建系统变化）。使用 `dart build cli` 是为了正确处理依赖中的原生构建钩子。Linux 独立程序已经通过启动、页面与会话接口检查；运行时仍需安装 FFmpeg。

`bash scripts/build_flutter.sh web` 会在 Linux 上打包静态界面和完整的本机服务包。服务包解压后执行 `./run.sh`；脚本会从包内读取前端，并默认把下载文件放在包目录的 `downloads/`。仅静态界面包需要另行配套服务。

当前服务绑定本机回环地址；远程部署、访问认证与持久化仍在实现范围内，当前不能作为公网多用户服务发布。服务进程保持运行时，刷新页面可以恢复队列。服务端会话与任务目前保存在内存中，服务重启后的恢复尚待实现；成品文件不会因此自动删除。

## 已有约束

- 浏览器请求需要同源，写操作需要指定请求头；会话 Cookie 使用 HttpOnly 和 SameSite=Strict。
- 文件访问按会话检查任务归属；调用方不能指定服务器任意路径或提交任意媒体 URL。
- 仅下载已在当前会话解析过的分集，下载并发最多 4；会话最多 32 个，每会话最多 200 个任务。清空完成记录不删除成品文件。
- 封面代理只接受解析结果中的 B站图片地址，拒绝跨域跳转，限制为 16 MiB。
- 未增加任务状态轮询；连接中断会显示错误，由用户点击继续连接已有任务。

## 验证

```bash
cd flutter_app
flutter test
dart run test/fixtures/browser_service.dart
# 另开终端，从仓库执行：
npm --prefix scripts ci --ignore-scripts
node scripts/test_flutter_web_flow.cjs
```

测试服务只用于本地样本，生产入口不会加载。样本会通过真实 FFmpeg 生成音视频，Chrome 操作解析、画质选择、下载、取回文件，随后用 ffprobe 和 FFmpeg 验证成品的两条轨道以及解码结果。还检查部分解析失败、刷新恢复和手机布局。截图与结果位于 `artifacts/rewrite/`。

2026-10-28 当前网络出口经生产服务访问公开视频接口仍返回 HTTP 412。该错误已独立于浏览器跨域问题确认；当前不能声称真实 B站登录与下载端到端验证通过。
