import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/job_snapshot.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/platform/download_native.dart';

class DirectMediaApi extends BiliApi {
  DirectMediaApi(this.url);
  final String url;
  @override
  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) async => PlayableMedia(
    qualities: const [Quality(80, '1080P')],
    video: [MediaStream(url: url, quality: 80, extension: 'mp4')],
    audio: const [],
    mp4: true,
  );
}

class CommentsOnlyApi extends BiliApi {
  @override
  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) => throw StateError('Comments must not request media');
  @override
  Future<String> danmaku(int cid, {CancelToken? cancel}) async =>
      '<i><d p="1,1,25,16777215">test comment</d></i>';
}

void main() {
  late HttpServer server;
  late Directory dir;
  late NativeDownloadRunner runner;
  late BiliApi api;
  final bytes = List<int>.generate(65536, (i) => i % 251);
  var ignoreRange = false, badRange = false, tag = '"v1"';
  final ranges = <String?>[];
  setUp(() async {
    ignoreRange = false;
    badRange = false;
    tag = '"v1"';
    ranges.clear();
    dir = await Directory.systemTemp.createTemp('bili-download-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value('range');
      ranges.add(range);
      request.response.headers.set('etag', tag);
      var start = 0, end = bytes.length - 1;
      if (range != null && (!ignoreRange || range == 'bytes=0-0')) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        if (range == 'bytes=0-0') end = 0;
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes ${badRange && start > 0 ? start + 1 : start}-$end/${bytes.length}',
        );
      }
      request.response.contentLength = end - start + 1;
      request.response.add(bytes.sublist(start, end + 1));
      await request.response.close();
    });
    api = BiliApi();
    runner = NativeDownloadRunner(api, retryDelay: Duration.zero);
  });
  tearDown(() async {
    runner.dispose();
    api.close();
    await server.close(force: true);
    await dir.delete(recursive: true);
  });
  DownloadJob task() => DownloadJob(
    const Episode(cid: 1, number: 1, name: 'part', title: 'video'),
    DownloadOptions(directory: dir.path, quality: 80),
  );
  String url() => 'http://127.0.0.1:${server.port}/stream';

  test(
    'resumes partial bytes only after identity and Content-Range validation',
    () async {
      final file = File('${dir.path}/partial');
      await file.writeAsBytes(bytes.take(1000).toList());
      final j = restoreJob(
        jobSnapshot(
          task()..streams['video'] = StreamIdentity(url(), bytes.length, tag),
        ),
      );
      await runner.downloadStream(url(), file, 'video', j, (_, _) {});
      expect(ranges, ['bytes=0-0', 'bytes=1000-']);
      expect(await file.readAsBytes(), bytes);
    },
  );
  test('server ignoring Range restarts file instead of appending', () async {
    ignoreRange = true;
    final file = File('${dir.path}/partial');
    await file.writeAsBytes(bytes.take(1000).toList());
    final j = task()
      ..streams['video'] = StreamIdentity(url(), bytes.length, tag);
    await runner.downloadStream(url(), file, 'video', j, (_, _) {});
    expect(await file.readAsBytes(), bytes);
  });
  test(
    'changed ETag invalidates old bytes before requesting the body',
    () async {
      final file = File('${dir.path}/partial');
      await file.writeAsBytes([7, 7, 7]);
      final j = task()
        ..streams['video'] = StreamIdentity(url(), bytes.length, '"old"');
      await runner.downloadStream(url(), file, 'video', j, (_, _) {});
      expect(ranges.last, isNull);
      expect(await file.readAsBytes(), bytes);
    },
  );
  test('invalid resume range fails before corrupting partial data', () async {
    badRange = true;
    final partial = bytes.take(1000).toList();
    final file = File('${dir.path}/partial');
    await file.writeAsBytes(partial);
    final j = task()
      ..streams['video'] = StreamIdentity(url(), bytes.length, tag);
    await expectLater(
      runner.downloadStream(url(), file, 'video', j, (_, _) {}),
      throwsA(isA<AppFailure>().having((e) => e.key, 'key', 'invalidRange')),
    );
    expect(await file.readAsBytes(), partial);
  });
  test('comments-only flat output skips media and FFmpeg', () async {
    final comments = CommentsOnlyApi();
    final worker = NativeDownloadRunner(
      comments,
      merge: (_) => throw StateError('No merge expected'),
    );
    addTearDown(() {
      worker.dispose();
      comments.close();
    });
    final j = DownloadJob(
      task().episode,
      DownloadOptions(
        directory: dir.path,
        quality: 80,
        onlyDanmaku: true,
        flatDirectory: true,
      ),
    );
    await worker.run(j, () {});
    expect(j.outputs, hasLength(1));
    final file = File(j.outputs.single);
    expect(file.parent.path, dir.path);
    expect(await file.readAsString(), contains('test comment'));
    expect(ranges, isEmpty);
  });
  test('cancelled jobs do not issue network requests', () async {
    final j = task()..token.cancel();
    await expectLater(
      runner.downloadStream(
        url(),
        File('${dir.path}/partial'),
        'video',
        j,
        (_, _) {},
      ),
      throwsA(isA<DioException>()),
    );
    expect(ranges, isEmpty);
  });
  test(
    'complete direct download publishes exact bytes and never overwrites',
    () async {
      final mediaApi = DirectMediaApi(url());
      final worker = NativeDownloadRunner(mediaApi);
      addTearDown(() {
        worker.dispose();
        mediaApi.close();
      });
      final j = task();
      await worker.run(j, () {});
      expect(j.outputs, hasLength(1));
      expect(j.pendingExports, isEmpty);
      expect(await File(j.outputs.single).readAsBytes(), bytes);
      await expectLater(
        worker.run(task(), () {}),
        throwsA(isA<AppFailure>().having((e) => e.key, 'key', 'fileExists')),
      );
      expect(await File(j.outputs.single).readAsBytes(), bytes);
    },
  );
  test(
    'retry after export failure reuses completed files without downloading',
    () async {
      final file = File('${dir.path}/ready.mp4');
      await file.writeAsBytes(bytes);
      final j = task()..pendingExports.add(file.path);
      await runner.run(j, () {});
      expect(j.outputs, [file.path]);
      expect(j.pendingExports, isEmpty);
      expect(ranges, isEmpty);
    },
  );
  for (final tamper in [false, true]) {
    test(
      'recovery after rename ${tamper ? 'rejects changed output' : 'reuses verified output'}',
      () async {
        final mediaApi = DirectMediaApi(url());
        final worker = NativeDownloadRunner(mediaApi);
        final noNetworkApi = CommentsOnlyApi();
        final recoveryWorker = NativeDownloadRunner(noNetworkApi);
        addTearDown(() {
          worker.dispose();
          recoveryWorker.dispose();
          mediaApi.close();
          noNetworkApi.close();
        });
        final j = task();
        Map<String, dynamic>? committed;
        j.onCheckpoint = () async {
          // Simulate exit after moving the file, before recording its new location.
          if (j.pendingExports.isNotEmpty) {
            throw const AppFailure('historyWriteFailed');
          }
          committed = jobSnapshot(j);
        };
        await expectLater(worker.run(j, () {}), throwsA(isA<AppFailure>()));
        final output = File(j.publications.keys.single);
        expect(await output.readAsBytes(), bytes);
        expect(committed!['pendingExports'], isEmpty);
        final requests = ranges.length;
        final restored = restoreJob(committed!);
        if (tamper) {
          await output.writeAsBytes([9, 8, 7]);
          await expectLater(
            recoveryWorker.run(restored, () {}),
            throwsA(
              isA<AppFailure>().having((e) => e.key, 'key', 'fileExists'),
            ),
          );
          expect(await output.readAsBytes(), [9, 8, 7]);
        } else {
          await recoveryWorker.run(restored, () {});
          expect(restored.outputs, [output.path]);
          expect(await output.readAsBytes(), bytes);
        }
        expect(ranges.length, requests);
      },
    );
  }
}
