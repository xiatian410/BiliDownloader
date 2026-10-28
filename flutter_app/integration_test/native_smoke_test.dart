import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:bili_downloader/app.dart';
import 'package:bili_downloader/app_controller.dart';
import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/download_queue.dart';
import 'package:bili_downloader/platform/download_native.dart';

import '../test/support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native window renders and bundled FFmpeg muxes video plus audio',
    (tester) async {
      final dir = await Directory.systemTemp.createTemp('bili-native-smoke-');
      final api = BiliApi();
      final c = AppController(
        api: api,
        queue: DownloadQueue(CompletedRunner()),
        store: MemoryStore(directory: dir.path),
      );
      await c.initialize();
      try {
        await tester.pumpWidget(BiliDownloaderApp(controller: c));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('video-input')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('tab-2')));
        await tester.pumpAndSettle();
        expect(find.text('扫码登录'), findsOneWidget);
        final video = '${dir.path}/video.mp4';
        final audio = '${dir.path}/audio.m4a';
        final merged = '${dir.path}/merged.mp4';
        await mergeWithFfmpeg([
          '-f',
          'lavfi',
          '-i',
          'color=c=blue:s=160x90:r=10',
          '-t',
          '1',
          '-c:v',
          'mpeg4',
          video,
        ]);
        await mergeWithFfmpeg([
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:sample_rate=44100',
          '-t',
          '1',
          '-c:a',
          'aac',
          audio,
        ]);
        await mergeWithFfmpeg([
          '-i',
          video,
          '-i',
          audio,
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-c',
          'copy',
          merged,
        ]);
        // Require and decode both tracks. A missing or damaged track fails FFmpeg.
        await mergeWithFfmpeg([
          '-v',
          'error',
          '-i',
          merged,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0',
          '-f',
          'null',
          '-',
        ]);
        expect(await File(merged).length(), greaterThan(1000));
        final cancel = CancelToken();
        var updates = 0;
        final peer = mergeWithFfmpeg([
          '-re',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=600',
          '-t',
          '2',
          '-f',
          'null',
          '-',
        ]);
        final stopped = mergeWithFfmpeg(
          [
            '-re',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440',
            '-t',
            '4',
            '-f',
            'null',
            '-',
          ],
          cancel: cancel,
          onProgress: (progress) {
            updates++;
            if (progress.milliseconds > 0) cancel.cancel('pause');
          },
        );
        await Future.wait([
          peer,
          expectLater(
            stopped.timeout(const Duration(seconds: 10)),
            throwsA(isA<DioException>()),
          ),
        ]);
        expect(updates, greaterThan(0));
        expect(tester.takeException(), isNull);
      } finally {
        c.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
