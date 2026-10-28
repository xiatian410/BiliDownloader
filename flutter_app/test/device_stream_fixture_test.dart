import 'dart:async';
import 'dart:io';

import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/io_download_runner.dart';
import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/fixtures/held_http.dart';

void main() {
  test('held HTTP fixture exposes its first chunk before completion', () async {
    final bytes = List<int>.generate(65536, (i) => i % 251);
    final progress = Completer<void>();
    final server = await HeldHttpFixture.open(bytes);
    final dir = await Directory.systemTemp.createTemp('bili-fixture-');
    final api = BiliApi();
    final runner = NativeDownloadRunner(api, retryDelay: Duration.zero);
    addTearDown(() async {
      runner.dispose();
      api.close();
      await server.close();
      await dir.delete(recursive: true);
    });
    final job = DownloadJob(
      const Episode(cid: 1, number: 1, name: 'x', title: 'x'),
      DownloadOptions(directory: dir.path, quality: 80),
    );
    final done = runner.downloadStream(
      server.url,
      File('${dir.path}/part'),
      'video',
      job,
      (n, total) {
        if (n > 0 && !progress.isCompleted) progress.complete();
      },
    );
    await progress.future.timeout(const Duration(seconds: 3));
    server.release();
    await done;
    expect(await File('${dir.path}/part').readAsBytes(), bytes);
  });
}
