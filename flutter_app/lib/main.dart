import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'app_controller.dart';
import 'platform/api_factory.dart';
import 'platform/platform.dart' as platform;
import 'core/download_queue.dart';
import 'platform/download_runner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = createBiliApi();
  final controller = AppController(
    api: api,
    queue: DownloadQueue(createDownloadRunner(api)),
    store: LocalAppStore(),
    openHistory: platform.openHistoryStore,
  );
  runApp(BiliDownloaderApp(controller: controller));
  unawaited(controller.initialize());
}
