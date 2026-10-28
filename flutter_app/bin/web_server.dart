import 'dart:io';

import 'package:bili_downloader/server/web_service.dart';

Future<void> main(List<String> args) async {
  final service = WebService(
    webRoot: Platform.environment['BILI_WEB_ROOT'] ?? 'build/web',
    downloadRoot: Platform.environment['BILI_DOWNLOAD_ROOT'] ?? 'web-downloads',
  );
  await service.start(
    port: int.parse(Platform.environment['BILI_WEB_PORT'] ?? '18743'),
  );
  stdout.writeln('BiliDownloader: ${service.origin}');
  ProcessSignal.sigint.watch().listen((_) async {
    await service.close();
    exit(0);
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await service.close();
      exit(0);
    });
  }
}
