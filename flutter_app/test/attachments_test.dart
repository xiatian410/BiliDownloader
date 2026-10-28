import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bili_downloader/core/attachments.dart';
import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/download_queue.dart';
import 'package:bili_downloader/core/io_download_runner.dart';
import 'package:bili_downloader/core/job_snapshot.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=',
);

class ImageAdapter implements HttpClientAdapter {
  int status = 200, calls = 0;
  Map<String, dynamic>? headers;
  Uri? uri;
  List<int> bytes = png;
  int? declaredLength;
  Stream<Uint8List> Function()? chunks;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    headers = options.headers;
    uri = options.uri;
    return ResponseBody(
      chunks?.call() ?? Stream.value(Uint8List.fromList(bytes)),
      status,
      headers: {
        'content-type': ['image/jpeg'],
        if (declaredLength != null) 'content-length': ['$declaredLength'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class AttachmentApi extends BiliApi {
  AttachmentApi(this.mediaUrl, this.adapter)
    : super(dio: Dio()..httpClientAdapter = adapter);
  final String mediaUrl;
  final ImageAdapter adapter;
  int mediaCalls = 0;
  @override
  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) async {
    mediaCalls++;
    return PlayableMedia(
      qualities: const [Quality(80, '1080P')],
      video: [MediaStream(url: mediaUrl, quality: 80)],
      audio: const [],
      mp4: true,
    );
  }
}

class CancellableCoverApi extends AttachmentApi {
  CancellableCoverApi(super.mediaUrl, super.adapter);
  final entered = Completer<void>();
  @override
  Future<CoverImage> fetchCover(String url, {CancelToken? cancel}) async {
    if (!entered.isCompleted) {
      entered.complete();
      throw await cancel!.whenCancel;
    }
    return super.fetchCover(url, cancel: cancel);
  }
}

Future<void> settled(
  DownloadQueue queue,
  DownloadJob job,
  void Function() action,
) async {
  final done = Completer<void>();
  void changed() {
    if ([
          JobState.completed,
          JobState.failed,
          JobState.paused,
        ].contains(job.state) &&
        !done.isCompleted) {
      done.complete();
    }
  }

  queue.addListener(changed);
  try {
    action();
    await done.future.timeout(const Duration(seconds: 10));
  } finally {
    queue.removeListener(changed);
  }
}

void main() {
  test(
    'source metadata reaches each episode for ordinary videos and series',
    () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final series = options.path.contains('/pgc/');
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'code': 0,
                    series ? 'result' : 'data': series
                        ? {
                            'title': 'Series',
                            'evaluate': 'Synopsis',
                            'cover': 'https://i0.hdslb.com/series.jpg',
                            'media_id': 2,
                            'episodes': [
                              {
                                'cid': 21,
                                'aid': 22,
                                'id': 23,
                                'title': '1',
                                'long_title': 'Part',
                                'cover': 'https://i0.hdslb.com/episode.png',
                              },
                            ],
                          }
                        : {
                            'title': 'Video',
                            'desc': 'Description',
                            'pic': 'http://i0.hdslb.com/video.webp',
                            'owner': {'name': 'Uploader'},
                            'aid': 12,
                            'bvid': 'BV1xx411c7mD',
                            'pages': [
                              {'cid': 11, 'page': 1, 'part': 'One'},
                              {'cid': 12, 'page': 2, 'part': 'Two'},
                            ],
                          },
                  },
                ),
              );
            },
          ),
        );
      final api = BiliApi(dio: dio);
      addTearDown(api.close);
      final regular = await api.resolve(const VideoId(VideoKind.av, '12'));
      expect(regular.cover, 'https://i0.hdslb.com/video.webp');
      expect(
        regular.episodes.every(
          (e) =>
              e.cover == regular.cover &&
              e.description == regular.description &&
              e.author == regular.author,
        ),
        true,
      );
      final series = await api.resolve(const VideoId(VideoKind.ep, '23'));
      expect(series.episodes.single.cover, 'https://i0.hdslb.com/episode.png');
      expect(series.episodes.single.description, 'Synopsis');
      expect(series.episodes.single.epId, 23);
    },
  );
  test('NFO escapes text, preserves identifiers, and remains valid XML', () {
    const episode = Episode(
      cid: 23,
      aid: 12,
      number: 2,
      title: 'A & B',
      name: '<Part> "two"',
      description: 'Text ]]> & <tag>\n\u0000end',
      author: 'UP & Name',
    );
    final document = XmlDocument.parse(videoNfo(episode));
    expect(document.rootElement.name.local, 'movie');
    expect(
      document.findAllElements('title').single.innerText,
      'A & B - 2. <Part> "two"',
    );
    expect(
      document.findAllElements('plot').single.innerText,
      'Text ]]> & <tag>\n�end',
    );
    expect(document.findAllElements('uniqueid').single.innerText, 'av12-23');
    expect(document.findAllElements('tag').single.innerText, 'UP: UP & Name');
    expect(document.findAllElements('season'), isEmpty);
  });

  test(
    'cover format follows bytes and CDN requests exclude cookies and redirects',
    () async {
      final adapter = ImageAdapter();
      final api = BiliApi(dio: Dio()..httpClientAdapter = adapter)
        ..cookies = {'SESSDATA': 'private'};
      addTearDown(api.close);
      final image = await api.fetchCover('//i0.hdslb.com/fake.jpg');
      expect(image.extension, 'png');
      expect(image.contentType, 'image/png');
      expect(adapter.headers!['Cookie'], isNull);
      expect(adapter.headers!['Referer'], biliHeaders['Referer']);
      await api.fetchCover('http://i0.hdslb.com:80/pic.jpg');
      expect(adapter.uri!.scheme, 'https');
      expect(adapter.uri!.port, 443);
      for (final url in [
        'http://i0.hdslb.com:8080/pic',
        'https://localhost/pic',
        'https://i0.hdslb.com.attacker.test/pic',
        'https://user@i0.hdslb.com/pic',
      ]) {
        await expectLater(api.fetchCover(url), throwsA(isA<AppFailure>()));
      }
      expect(adapter.calls, 2);
      adapter.status = 302;
      await expectLater(
        api.fetchCover('https://i0.hdslb.com/redirect'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.calls, 3);
      adapter.status = 200;
      adapter.bytes = utf8.encode('<html>Denied</html>');
      await expectLater(
        api.fetchCover('https://i0.hdslb.com/error.jpg'),
        throwsA(isA<AppFailure>()),
      );
    },
  );

  test(
    'cover limit cancels the stream with or without Content-Length',
    () async {
      for (final declared in [false, true]) {
        final adapter = ImageAdapter()
          ..declaredLength = declared ? 17 * 1024 * 1024 : null;
        var cancelled = false;
        adapter.chunks = () async* {
          try {
            for (var i = 0; i < 20; i++) {
              yield Uint8List(1024 * 1024);
            }
          } finally {
            cancelled = true;
          }
        };
        final api = BiliApi(dio: Dio()..httpClientAdapter = adapter);
        try {
          await expectLater(
            api.fetchCover('https://i0.hdslb.com/large'),
            throwsA(
              isA<AppFailure>().having((e) => e.key, 'key', 'requestTooLarge'),
            ),
          );
          // A declared oversized response is cancelled before iteration starts.
          if (!declared) expect(cancelled, true);
        } finally {
          api.close();
        }
      }
    },
  );

  group('attachments with real media file publication', () {
    late Directory dir;
    late HttpServer server;
    late AttachmentApi api;
    late NativeDownloadRunner runner;
    late ImageAdapter images;
    var mediaRequests = 0;
    final mediaBytes = List<int>.generate(8192, (i) => i % 251);
    const episode = Episode(
      cid: 7,
      aid: 1,
      number: 1,
      title: 'Title',
      name: 'Part',
      cover: 'https://i0.hdslb.com/pic.jpg',
      description: 'Description & <data>',
      author: 'Uploader',
    );
    DownloadJob task({String? destination}) => DownloadJob(
      episode,
      DownloadOptions(
        directory: destination ?? dir.path,
        quality: 80,
        flatDirectory: true,
        autoCover: true,
        nfo: true,
      ),
    );
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bili-attachments-');
      mediaRequests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        mediaRequests++;
        r.response.headers.set('etag', '"media"');
        if (r.headers.value('range') == 'bytes=0-0') {
          r.response.statusCode = 206;
          r.response.headers.set(
            'content-range',
            'bytes 0-0/${mediaBytes.length}',
          );
          r.response.add(mediaBytes.take(1).toList());
        } else {
          r.response.contentLength = mediaBytes.length;
          r.response.add(mediaBytes);
        }
        await r.response.close();
      });
      images = ImageAdapter();
      api = AttachmentApi('http://127.0.0.1:${server.port}/media', images);
      runner = NativeDownloadRunner(api);
    });
    tearDown(() async {
      runner.dispose();
      api.close();
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    test(
      'pausing an attachment preserves media and resumes only unfinished files',
      () async {
        final held = CancellableCoverApi(api.mediaUrl, images);
        final worker = NativeDownloadRunner(held);
        final queue = DownloadQueue(worker);
        addTearDown(() async {
          await queue.close();
          held.close();
        });
        final job = task();
        await queue.add([job]);
        await held.entered.future.timeout(const Duration(seconds: 10));
        final before = mediaRequests;
        await settled(queue, job, () => queue.pause(job));
        expect(job.state, JobState.paused);
        expect(job.attachments['cover']!.state, AttachmentState.pending);
        expect(job.mediaPrepared, true);
        await settled(queue, job, () => queue.resume(job));
        expect(job.state, JobState.completed);
        expect(job.outputs, hasLength(3));
        expect(mediaRequests, before);
        expect(held.mediaCalls, 1);
      },
    );

    test(
      'failed cover retries after history restore without media or NFO work',
      () async {
        images.status = 503;
        final original = task();
        final queue = DownloadQueue(runner);
        await settled(queue, original, () => queue.add([original]));
        expect(original.state, JobState.completed);
        expect(original.hasAttachmentFailures, true);
        expect(original.outputs, hasLength(2));
        expect(original.attachments['nfo']!.state, AttachmentState.completed);
        final saved = jsonDecode(
          jsonEncode(jobSnapshot(original)),
        ) as Map<String, dynamic>;
        final restored = restoreJob(saved);
        expect(restored.options.autoCover, true);
        expect(restored.episode.description, episode.description);
        expect(restored.canResume, true);
        final priorMediaRequests = mediaRequests;
        final nfo = File(
          restored.outputs.singleWhere((p) => p.endsWith('.nfo')),
        );
        final nfoBefore = await nfo.readAsString();
        images.status = 200;
        queue.jobs
          ..clear()
          ..add(restored);
        await settled(queue, restored, () => queue.resume(restored));
        expect(restored.state, JobState.completed);
        expect(restored.hasAttachmentFailures, false);
        expect(restored.outputs, hasLength(3));
        expect(mediaRequests, priorMediaRequests);
        expect(api.mediaCalls, 1);
        expect(images.calls, 2);
        expect(await nfo.readAsString(), nfoBefore);
        expect(
          await File(restored.outputs.singleWhere((p) => p.endsWith('.png')))
              .readAsBytes(),
          png,
        );
        expect(
          await File(restored.outputs.singleWhere((p) => p.endsWith('.mp4')))
              .readAsBytes(),
          mediaBytes,
        );
        await queue.close();
      },
    );

    test(
      'preexisting cover is preserved while video and metadata complete',
      () async {
        final old = File(p.join(dir.path, '${episode.filename()}-poster.png'));
        await old.writeAsString('user file');
        final job = task();
        await runner.run(job, () {});
        expect(job.attachments['cover']!.error!.key, 'fileExists');
        expect(await old.readAsString(), 'user file');
        expect(job.outputs, hasLength(2));
      },
    );

    test('interrupted attachment publication recovers without repeating media or cover', () async {
      final job = task();
      Map<String, dynamic>? saved;
      job.onCheckpoint = () async {
        if (job.pendingExports.any((p) => p.endsWith('.nfo'))) {
          throw StateError('storage interrupted');
        }
        saved =
            jsonDecode(jsonEncode(jobSnapshot(job))) as Map<String, dynamic>;
      };
      await expectLater(
        runner.run(job, () {}),
        throwsA(
          isA<AppFailure>().having((e) => e.key, 'key', 'historyWriteFailed'),
        ),
      );
      final restored = restoreJob(saved!);
      final requests = mediaRequests;
      await runner.run(restored, () {});
      expect(restored.outputs, hasLength(3));
      expect(restored.hasAttachmentFailures, false);
      expect(mediaRequests, requests);
      expect(images.calls, 1);
    });

    test('SAF exports include attachments and checkpoint destinations before deleting staging', () async {
      final job = task(destination: 'content://fixture/tree');
      final published = <String>[];
      final worker = NativeDownloadRunner(
        api,
        workingDirectory: (_) async => dir.path,
        publishFile: (file, destination, folder) async {
          expect(destination, 'content://fixture/tree');
          expect(folder, '');
          published.add(file);
          return 'content://fixture/${p.basename(file)}';
        },
      );
      addTearDown(worker.dispose);
      job.onCheckpoint = () async {
        for (final file in published) {
          if (!job.pendingExports.contains(file) &&
              job.exportedFiles[file] != null &&
              file == published.last) {
            expect(await File(file).exists(), true);
          }
        }
      };
      await worker.run(job, () {});
      expect(job.outputs, hasLength(3));
      expect(job.outputs.every((p) => p.startsWith('content://')), true);
      for (final file in published) {
        expect(await File(file).exists(), false);
      }
    });
  });
}
