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
import 'package:bili_downloader/core/subtitles.dart';
import 'package:bili_downloader/core/wire.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'attachments_test.dart' show settled;

const episode = Episode(
  cid: 7,
  aid: 1,
  epId: 4,
  number: 1,
  name: 'Part',
  title: 'Title',
);
Map<String, dynamic> track(String language, String id) => {
  'id_str': id,
  'lan': language,
  'lan_doc': language == 'zh-CN' ? '中文' : language,
  'is_lock': true,
  'subtitle_url': '//aisubtitle.hdslb.com/$id.json?token=transient',
};
Matcher failure(String key) =>
    isA<AppFailure>().having((e) => e.key, 'key', key);

class SubtitleAdapter implements HttpClientAdapter {
  List<Map<String, dynamic>> tracks = [
    track('zh-CN', '123456789012345678'),
    track('en', '2'),
  ];
  final requests = <RequestOptions>[];
  final counts = <String, int>{};
  final errors = <String, int>{};
  bool loginRequired = false;
  List<int>? body;
  int? declaredLength;
  Stream<Uint8List> Function()? chunks;
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(o);
    if (o.uri.host == 'api.bilibili.com') {
      final nav = o.path.endsWith('/nav');
      return ResponseBody.fromString(
        jsonEncode({
          'code': nav ? -101 : 0,
          'data': nav
              ? {
                  'wbi_img': {
                    'img_url': 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                    'sub_url': 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
                  },
                }
              : {
                  'cid': int.parse(o.queryParameters['cid'].toString()),
                  'aid': 1,
                  'need_login_subtitle': loginRequired,
                  'subtitle': {'subtitles': tracks},
                },
        }),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    final id = o.uri.pathSegments.last.split('.').first;
    counts[id] = (counts[id] ?? 0) + 1;
    return ResponseBody(
      chunks?.call() ??
          Stream.value(
            Uint8List.fromList(
              body ??
                  utf8.encode(
                    jsonEncode({
                      'body': [
                        {
                          'from': 0.125,
                          'to': 1.5,
                          'content': '字幕 $id & <text>',
                        },
                      ],
                    }),
                  ),
            ),
          ),
      errors[id] ?? 200,
      headers: {
        'content-type': ['application/json'],
        if (declaredLength != null) 'content-length': ['$declaredLength'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class SubtitleApi extends BiliApi {
  SubtitleApi(this.mediaUrl, SubtitleAdapter adapter)
    : super(dio: Dio()..httpClientAdapter = adapter);
  final String mediaUrl;
  int mediaCalls = 0;
  Completer<void>? entered;
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

  @override
  Future<String> fetchSubtitle(
    SubtitleTrack track, {
    CancelToken? cancel,
  }) async {
    if (entered != null && !entered!.isCompleted) {
      entered!.complete();
      throw await cancel!.whenCancel;
    }
    return super.fetchSubtitle(track, cancel: cancel);
  }
}

void main() {
  test('player mapping preserves language, large IDs and AI without treating is_lock as a download ban', () {
    Map<String, dynamic> data(List<dynamic> rows) => {
      'cid': 7,
      'aid': 1,
      'subtitle': {'subtitles': rows},
    };
    final parsed = playerSubtitles(
      data([
        track('zh-CN', '123456789012345678'),
        {...track('ai-en', '2'), 'ai_type': 1},
        track('ja', '3'),
      ]),
      episode,
    );
    expect(parsed.first.id, '123456789012345678');
    expect(parsed[1].automatic, true);
    expect(parsed[2].url, contains('/3.json'));
    expect(
      jsonEncode(parsed.map((t) => t.toJson()).toList()),
      isNot(contains('token=')),
    );
    expect(playerSubtitles({'cid': 7, 'subtitle': null}, episode), isEmpty);
    expect(
      () => playerSubtitles({'cid': 8}, episode),
      throwsA(failure('subtitleIdentityMismatch')),
    );
    expect(
      () => playerSubtitles({'cid': 7, 'need_login_subtitle': true}, episode),
      throwsA(failure('subtitleLoginRequired')),
    );
    for (final value in [false, 'bad', 3]) {
      expect(
        () => playerSubtitles({'cid': 7, 'subtitle': value}, episode),
        throwsA(failure('invalidSubtitle')),
      );
    }
    expect(
      () => playerSubtitles(
        data([
          {'lan': 'en', 'id': 1},
        ]),
        episode,
      ),
      throwsA(failure('invalidSubtitle')),
    );
    expect(
      () => playerSubtitles(
        data(List.generate(33, (i) => track('en', '$i'))),
        episode,
      ),
      throwsA(failure('requestTooLarge')),
    );
    expect(
      playerSubtitles(data([track('en', '1'), track('EN', '1')]), episode),
      hasLength(1),
    );
    for (final value in ['../en', 'en.srt', '', 'en/us']) {
      expect(
        () => optionsFromJson({'directory': '', 'subtitles': value}),
        throwsA(failure('invalidSubtitleSelection')),
      );
    }
    expect(
      optionsFromJson(
        optionsToJson(
          const DownloadOptions(directory: '', quality: 80, subtitles: 'zh-CN'),
        ),
      ).subtitles,
      'zh-CN',
    );
  });

  test('SRT conversion retains cue order, overlap, Unicode and explicit millisecond precision', () {
    expect(
      subtitlesToSrt({
        'body': [
          {'from': 1.0004, 'to': 61.2346, 'content': '中文 & <b>\r\n\r\n第二行'},
          {'from': 0, 'to': 3600.1, 'content': 'Overlap'},
        ],
      }),
      '1\n00:00:01,000 --> 00:01:01,235\n中文 &amp; &lt;b&gt;\n\u00a0\n第二行\n\n2\n00:00:00,000 --> 01:00:00,100\nOverlap\n\n',
    );
    expect(
      () => subtitlesToSrt({'body': []}),
      throwsA(failure('subtitleEmpty')),
    );
    for (final (from, to) in [
      (-1, 2),
      (2, 2),
      (3, 2),
      (0, double.infinity),
      (double.nan, 1),
      (0, 604801),
      (0, .0001),
    ]) {
      expect(
        () => subtitlesToSrt({
          'body': [
            {'from': from, 'to': to, 'content': 'x'},
          ],
        }),
        throwsA(failure('invalidSubtitle')),
      );
    }
    for (final data in [
      null,
      {'body': 'bad'},
      {
        'body': [
          {'from': 0, 'to': 1, 'content': 1},
        ],
      },
      {
        'body': [
          {'from': 0, 'to': 1, 'content': '\u0000'},
        ],
      },
    ]) {
      expect(() => subtitlesToSrt(data), throwsA(failure('invalidSubtitle')));
    }
    expect(
      () => subtitlesToSrt({'body': List.filled(20001, null)}),
      throwsA(failure('requestTooLarge')),
    );
  });

  test('signed player lookup is per CID; CDN omits credentials and rejects redirects or unsafe locations', () async {
    final adapter = SubtitleAdapter();
    final api = BiliApi(dio: Dio()..httpClientAdapter = adapter)
      ..cookies = {'SESSDATA': 'private'};
    addTearDown(api.close);
    final tracks = await api.subtitles(episode);
    final player = adapter.requests.last;
    expect(player.queryParameters['cid'], '7');
    expect(player.queryParameters['ep_id'], '4');
    expect(player.queryParameters['w_rid'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(player.headers['Cookie'], contains('SESSDATA=private'));
    expect(
      await api.fetchSubtitle(tracks.first),
      contains('字幕 123456789012345678'),
    );
    final cdn = adapter.requests.last;
    expect(cdn.uri.scheme, 'https');
    expect(cdn.headers['Cookie'], isNull);
    expect(cdn.followRedirects, false);
    for (final url in [
      'https://localhost/a',
      'https://aisubtitle.hdslb.com.evil.test/a',
      'http://aisubtitle.hdslb.com:8080/a',
      'https://user@aisubtitle.hdslb.com/a',
    ]) {
      await expectLater(
        api.fetchSubtitle(
          SubtitleTrack(id: '1', language: 'en', label: 'en', url: url),
        ),
        throwsA(failure('invalidSubtitle')),
      );
    }
    adapter.errors[tracks.first.id] = 302;
    await expectLater(
      api.fetchSubtitle(tracks.first),
      throwsA(isA<DioException>()),
    );
    adapter.errors[tracks.first.id] = 403;
    await expectLater(
      api.fetchSubtitle(tracks.first),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          403,
        ),
      ),
    );
    adapter.errors.clear();
    adapter.body = [255];
    await expectLater(
      api.fetchSubtitle(tracks.first),
      throwsA(failure('invalidSubtitle')),
    );
    adapter.body = utf8.encode(
      '\ufeff{"body":[{"from":0,"to":1,"content":"BOM"}]}',
    );
    expect(await api.fetchSubtitle(tracks.first), contains('BOM'));
  });

  test(
    'subtitle download enforces 4 MiB for declared and streamed payloads',
    () async {
      for (final declared in [true, false]) {
        final adapter = SubtitleAdapter()
          ..declaredLength = declared ? 5 * 1024 * 1024 : null;
        var cancelled = false;
        adapter.chunks = () async* {
          try {
            for (var i = 0; i < 6; i++) {
              yield Uint8List(1024 * 1024);
            }
          } finally {
            cancelled = true;
          }
        };
        final api = BiliApi(dio: Dio()..httpClientAdapter = adapter);
        try {
          final tracks = await api.subtitles(episode);
          await expectLater(
            api.fetchSubtitle(tracks.first),
            throwsA(failure('requestTooLarge')),
          );
          if (!declared) expect(cancelled, true);
        } finally {
          api.close();
        }
      }
    },
  );

  group('subtitle publication with real media and durable tasks', () {
    late Directory dir;
    late HttpServer server;
    late SubtitleAdapter adapter;
    late SubtitleApi api;
    late NativeDownloadRunner runner;
    var mediaRequests = 0;
    DownloadJob task({String mode = 'all'}) => DownloadJob(
      episode,
      DownloadOptions(
        directory: dir.path,
        quality: 80,
        flatDirectory: true,
        subtitles: mode,
      ),
    );
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bili-subtitles-');
      mediaRequests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        mediaRequests++;
        r.response.headers.set('etag', '"media"');
        if (r.headers.value('range') == 'bytes=0-0') {
          r.response.statusCode = 206;
          r.response.headers.set('content-range', 'bytes 0-0/8192');
          r.response.add([0]);
        } else {
          r.response.contentLength = 8192;
          r.response.add(List.filled(8192, 0));
        }
        await r.response.close();
      });
      adapter = SubtitleAdapter();
      api = SubtitleApi('http://127.0.0.1:${server.port}/media', adapter);
      runner = NativeDownloadRunner(api);
    });
    tearDown(() async {
      runner.dispose();
      api.close();
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    test('failed language retries after restart using fresh URL without repeating media or successful language', () async {
      adapter.errors['2'] = 503;
      final queue = DownloadQueue(runner);
      addTearDown(queue.close);
      final original = task();
      await settled(queue, original, () => queue.add([original]));
      expect(original.state, JobState.completed);
      expect(original.hasAttachmentFailures, true);
      expect(original.outputs, hasLength(2));
      final saved = jsonEncode(jobSnapshot(original));
      expect(saved, isNot(contains('token=')));
      expect(saved, isNot(contains('hdslb.com')));
      final restored = restoreJob(jsonDecode(saved));
      final before = mediaRequests;
      adapter.errors.clear();
      adapter.tracks[1]['subtitle_url'] =
          '//aisubtitle.hdslb.com/2.json?token=renewed';
      queue.jobs
        ..clear()
        ..add(restored);
      await settled(queue, restored, () => queue.resume(restored));
      expect(restored.outputs, hasLength(3));
      expect(restored.hasRetryableAttachments, false);
      expect(mediaRequests, before);
      expect(api.mediaCalls, 1);
      expect(adapter.counts, {'123456789012345678': 1, '2': 2});
      expect(adapter.requests.last.uri.queryParameters['token'], 'renewed');
      expect(
        await File(restored.outputs.singleWhere((f) => f.endsWith('.en.srt')))
            .readAsString(),
        contains('&amp; &lt;text&gt;'),
      );
    });

    test('missing language, no subtitles and login requirement remain distinct and manually recheckable', () async {
      final queue = DownloadQueue(runner);
      addTearDown(queue.close);
      final job = task(mode: 'ja');
      await settled(queue, job, () => queue.add([job]));
      final before = mediaRequests;
      expect(job.attachments['subtitles']!.state, AttachmentState.unavailable);
      expect(
        job.attachments['subtitles']!.error!.key,
        'subtitleLanguageUnavailable',
      );
      adapter.tracks = [];
      await settled(queue, job, () => queue.resume(job));
      expect(job.attachments['subtitles']!.error!.key, 'noSubtitles');
      adapter.loginRequired = true;
      await settled(queue, job, () => queue.resume(job));
      expect(job.attachments['subtitles']!.error!.key, 'subtitleLoginRequired');
      expect(job.attachments['subtitles']!.state, AttachmentState.failed);
      adapter.loginRequired = false;
      adapter.tracks = [track('ja', '3')];
      await settled(queue, job, () => queue.resume(job));
      expect(job.outputs, hasLength(2));
      expect(job.outputs.last, endsWith('.ja.srt'));
      expect(mediaRequests, before);
    });

    test(
      'retry never silently replaces a vanished track with a new ID',
      () async {
        adapter.errors['2'] = 503;
        final job = task();
        await runner.run(job, () {});
        adapter.errors.clear();
        adapter.tracks = [
          track('zh-CN', '123456789012345678'),
          track('en', '3'),
        ];
        await runner.run(job, () {});
        expect(
          job.attachments['subtitle:en:2']!.error!.key,
          'subtitleSourceChanged',
        );
        expect(adapter.counts['3'], isNull);
        expect(job.outputs, hasLength(2));
      },
    );

    test('duplicate languages have separate filenames and existing files are preserved', () async {
      adapter.tracks = [track('en', '1'), track('en', '2')];
      final existing = File(p.join(dir.path, '${episode.filename()}.en.1.srt'));
      await existing.writeAsString('user file');
      final job = task();
      await runner.run(job, () {});
      expect(job.attachments['subtitle:en:1']!.error!.key, 'fileExists');
      expect(await existing.readAsString(), 'user file');
      expect(job.outputs.last, endsWith('.en.2.srt'));
    });

    test(
      'pause cancels subtitle request; resume preserves completed media',
      () async {
        api.entered = Completer<void>();
        final job = task();
        final queue = DownloadQueue(runner);
        addTearDown(queue.close);
        await queue.add([job]);
        await api.entered!.future.timeout(const Duration(seconds: 10));
        final before = mediaRequests;
        await settled(queue, job, () => queue.pause(job));
        expect(job.state, JobState.paused);
        expect(job.attachments.values.first.state, AttachmentState.pending);
        await settled(queue, job, () => queue.resume(job));
        expect(job.outputs, hasLength(3));
        expect(mediaRequests, before);
      },
    );

    test(
      'publication checkpoint failure stops work and recovers the exact SRT',
      () async {
        final job = task();
        Map<String, dynamic>? saved;
        job.onCheckpoint = () async {
          if (job.pendingExports.any((f) => f.endsWith('.srt'))) {
            throw StateError('interrupted');
          }
          saved = jsonDecode(jsonEncode(jobSnapshot(job)));
        };
        await expectLater(
          runner.run(job, () {}),
          throwsA(failure('historyWriteFailed')),
        );
        final restored = restoreJob(saved!);
        final before = mediaRequests;
        await runner.run(restored, () {});
        expect(restored.outputs, hasLength(3));
        expect(adapter.counts.values, everyElement(1));
        expect(mediaRequests, before);
      },
    );
  });
}
