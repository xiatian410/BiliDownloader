import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'app_controller.dart';
import 'core/bili_api.dart';
import 'core/download_queue.dart';
import 'platform/download_runner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = BiliApi();
  final controller = AppController(
    api: api,
    queue: DownloadQueue(createDownloadRunner(api)),
    store: LocalAppStore(),
  );
  runApp(BiliDownloaderApp(controller: controller));
  unawaited(controller.initialize());
}
