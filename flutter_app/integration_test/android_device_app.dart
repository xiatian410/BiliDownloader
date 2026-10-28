// CI debug target only. Release builds use lib/main.dart and contain no fixture channel.
import 'dart:async';
import 'dart:io';

import 'fixtures/held_http.dart';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:bili_downloader/app.dart';
import 'package:bili_downloader/app_controller.dart';
import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/platform/download_native.dart';
import 'package:bili_downloader/platform/platform_native.dart' as platform;

class DeviceApi extends BiliApi {
  String fixtureUrl = '';
  @override
  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) async => PlayableMedia(
    qualities: const [Quality(80, '1080P')],
    video: [MediaStream(url: fixtureUrl, quality: 80, extension: 'mp4')],
    audio: const [],
    mp4: true,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = DeviceApi();
  final queue = createDownloadQueue(api);
  final controller = AppController(
    api: api,
    queue: queue,
    store: LocalAppStore(),
    openHistory: platform.openHistoryStore,
  );
  runApp(BiliDownloaderApp(controller: controller));
  final initialized = controller.initialize();
  HeldHttpFixture? server;
  Directory? fixtureDirectory;
  DownloadJob? current;
  List<int> bytes = [];

  Future<void> until(bool Function() condition) async {
    if (condition()) return;
    final ready = Completer<void>();
    void changed() {
      if (condition() && !ready.isCompleted) ready.complete();
    }

    queue.addListener(changed);
    try {
      await ready.future.timeout(const Duration(seconds: 35));
    } finally {
      queue.removeListener(changed);
    }
  }

  const channel = MethodChannel('bili_downloader/device_fixture');
  channel.setMethodCallHandler((call) async {
    await initialized;
    switch (call.method) {
      case 'start':
        await server?.close();
        fixtureDirectory = await Directory.systemTemp.createTemp(
          'bili-device-queue-',
        );
        final source = '${fixtureDirectory!.path}/fixture.mp4';
        await mergeWithFfmpeg([
          '-y',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=320x240:rate=30',
          '-t',
          '3',
          '-c:v',
          'mpeg4',
          '-q:v',
          '2',
          source,
        ]);
        bytes = await File(source).readAsBytes();
        if (bytes.length < 8192) throw StateError('Fixture too short');
        server = await HeldHttpFixture.open(bytes);
        api.fixtureUrl = server!.url;
        current = DownloadJob(
          const Episode(
            cid: 701,
            number: 1,
            name: '后台下载',
            title: 'Device fixture',
          ),
          DownloadOptions(
            directory: '${fixtureDirectory!.path}/output',
            quality: 80,
          ),
        );
        await queue.add([current!]);
        await until(() => current!.received > 0 || !current!.active);
        if (!current!.active || current!.received == 0) {
          throw StateError('Download failed: ${current!.error?.key}');
        }
        return {
          'id': current!.id,
          'queue': identityHashCode(queue),
          'received': current!.received,
        };
      case 'finish':
        server!.release();
        await until(() => !current!.active);
        if (current!.state != JobState.completed) {
          throw StateError(
            'Not complete: ${current!.state} ${current!.error?.key}',
          );
        }
        final output = File(current!.outputs.single);
        final verified =
            sha256.convert(await output.readAsBytes()).toString() ==
            sha256.convert(bytes).toString();
        await mergeWithFfmpeg([
          '-v',
          'error',
          '-i',
          output.path,
          '-f',
          'null',
          '-',
        ]);
        return {
          'verified': verified,
          'decoded': true,
          'id': current!.id,
          'queue': identityHashCode(queue),
          'rangeResumed': server!.rangeResumed,
        };
      case 'paused':
        await until(() => !current!.active);
        return {
          'state': current!.state.name,
          'error': current!.error?.key,
          'id': current!.id,
          'received': current!.received,
        };
      case 'resume':
        queue.resume(current!);
        return null;
      case 'identity':
        return {'queue': identityHashCode(queue), 'id': current?.id};
      default:
        throw MissingPluginException();
    }
  });
}
