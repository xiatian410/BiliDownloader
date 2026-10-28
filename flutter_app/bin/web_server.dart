import 'dart:io';

import 'package:bili_downloader/server/web_service.dart';
import 'package:bili_downloader/server/access_policy.dart';

Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == '--generate-access-key') {
    await AccessPolicy.generateKey(args[1]);
    stdout.writeln('Access key file created. Its contents are not printed.');
    return;
  }
  if (args.isNotEmpty) {
    throw ArgumentError('Usage: web_server [--generate-access-key FILE]');
  }
  final root = Platform.environment['BILI_WEB_ROOT'] ?? 'build/web';
  final keyFile = Platform.environment['BILI_ACCESS_KEY_FILE'];
  final publicOrigin = Platform.environment['BILI_PUBLIC_ORIGIN'];
  if (publicOrigin != null && keyFile == null) {
    throw ArgumentError('BILI_PUBLIC_ORIGIN requires BILI_ACCESS_KEY_FILE');
  }
  final service = WebService(
    webRoot: root,
    downloadRoot: Platform.environment['BILI_DOWNLOAD_ROOT'] ?? 'web-downloads',
    access: keyFile == null
        ? null
        : await AccessPolicy.load(
            keyFile: keyFile,
            webRoot: root,
            publicOrigin: publicOrigin,
          ),
  );
  await service.start(
    port: int.parse(Platform.environment['BILI_WEB_PORT'] ?? '18743'),
  );
  stdout.writeln(
    'BiliDownloader: ${service.access?.publicOrigin?.origin ?? service.origin}',
  );
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
