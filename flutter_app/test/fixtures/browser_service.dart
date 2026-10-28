// Explicit local test fixture; never selected by the production entry point.
import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/server/web_service.dart';
import 'package:bili_downloader/server/access_policy.dart';
import 'package:bili_downloader/core/attachments.dart';
import 'package:bili_downloader/core/subtitles.dart';

class BrowserFixtureApi extends BiliApi {
  BrowserFixtureApi(this.origin);
  final String origin;
  bool failedOnce = false;
  bool failedCover = false;
  static bool failedEnglish = false;
  @override
  Future<List<SubtitleTrack>> subtitles(
    Episode episode, {
    CancelToken? cancel,
  }) async => [
    for (final language in ['zh-CN', 'ai-en'])
      SubtitleTrack(
        id: '${episode.cid}${language == 'zh-CN' ? '01' : '02'}',
        language: language,
        label: language == 'zh-CN' ? '中文' : '英语（自动生成）',
        automatic: language == 'ai-en',
        url:
            'https://aisubtitle.hdslb.com/${episode.cid}.json?token=fixture-transient',
      ),
  ];
  @override
  Future<String> fetchSubtitle(
    SubtitleTrack track, {
    CancelToken? cancel,
  }) async {
    stdout.writeln(
      'Fixture subtitle: ${jsonEncode({'id': track.id, 'language': track.language})}',
    );
    if (track.id == '100902' && !failedEnglish) {
      failedEnglish = true;
      throw const AppFailure('httpError', '503');
    }
    return subtitlesToSrt({
      'body': [
        {
          'from': .125,
          'to': .875,
          'content': '字幕 ${track.id} · ${track.language} & <sample>',
        },
      ],
    });
  }

  @override
  Future<CoverImage> fetchCover(String url, {CancelToken? cancel}) async {
    if (url.endsWith('/8.jpg') && !failedCover) {
      failedCover = true;
      throw const AppFailure('httpError', '503');
    }
    return CoverImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=',
      ),
    );
  }

  @override
  Future<VideoInfo> resolve(VideoId id, {CancelToken? cancel}) async {
    if (id.value == '412') throw const AppFailure('httpError', '412');
    return VideoInfo(
      title: '跨端下载验证 · ${id.label}',
      description: '本地媒体样本，验证解析、下载、合并与文件导出。',
      cover: '',
      id: id.label,
      author: 'Local fixture',
      episodes: [
        Episode(
          cid: 1000 + (int.tryParse(id.value) ?? 1),
          aid: int.tryParse(id.value) ?? 1,
          number: 1,
          name: '视频与音频合并',
          title: '跨端下载验证 · ${id.label}',
          bvid: id.kind == VideoKind.bv ? id.label : '',
          cover: 'https://i0.hdslb.com/${id.value}.jpg',
          description: '附件样本 & <xml>\n第二行',
          author: 'Local fixture',
        ),
      ],
    );
  }

  @override
  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) async {
    if (episode.aid == 5 && cancel != null && !failedOnce) {
      failedOnce = true;
      throw const AppFailure('httpError', '503');
    }
    return PlayableMedia(
      qualities: const [Quality(120, '4K'), Quality(80, '1080P')],
      video: [
        MediaStream(
          url: '$origin/video.mp4?aid=${episode.aid}',
          quality: 80,
          codec: 7,
        ),
      ],
      audio: [
        MediaStream(
          url: '$origin/audio.m4a?aid=${episode.aid}',
          bandwidth: 192000,
        ),
      ],
    );
  }

  @override
  Future<bool> checkLogin() async => cookies.isNotEmpty;
  @override
  Future<void> logout() async => cookies = {};
  @override
  Future<LoginQr> generateQr({CancelToken? cancel}) async =>
      const LoginQr('https://example.test/fixture-login', 'fixture-qr');
  @override
  Future<LoginResult> pollQr(LoginQr qr, {CancelToken? cancel}) async =>
      const LoginResult(0, {
        'SESSDATA': 'fixture-only',
        'bili_jct': 'fixture-only',
      });
  @override
  Future<String> danmaku(int cid, {CancelToken? cancel}) async =>
      '<i><d p="1,1,25,16777215">本地弹幕</d></i>';
}

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'bili-browser-fixture-',
  );
  for (final args in [
    [
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=320x180:rate=24',
      '-t',
      '1',
      '-pix_fmt',
      'yuv420p',
      '-c:v',
      'libx264',
      '${directory.path}/video.mp4',
    ],
    [
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440',
      '-t',
      '1',
      '-c:a',
      'aac',
      '${directory.path}/audio.m4a',
    ],
  ]) {
    final result = await Process.run('ffmpeg', [
      '-nostdin',
      '-v',
      'error',
      ...args,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Fixture generation failed: ${result.stderr}');
    }
  }
  final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final gates = <String, Completer<void>>{};
  final held = <String>{};
  media.listen((r) async {
    if (!['/video.mp4', '/audio.m4a'].contains(r.uri.path)) {
      r.response.statusCode = 404;
      await r.response.close();
      return;
    }
    final file = File('${directory.path}${r.uri.path}');
    final length = await file.length();
    r.response.headers.set('etag', 'fixture-${r.uri.path}');
    final range = r.headers.value('range');
    final match = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    final start = match == null ? 0 : int.parse(match[1]!);
    final end = match == null || match[2]!.isEmpty
        ? length - 1
        : int.parse(match[2]!);
    final aid = r.uri.queryParameters['aid'] ?? '';
    if (match != null) {
      r.response.statusCode = 206;
      r.response.headers.set('content-range', 'bytes $start-$end/$length');
    }
    r.response.contentLength = end - start + 1;
    // Small fixture chunks must reach the downloader before the injected stall.
    r.response.bufferOutput = false;
    try {
      if (range != 'bytes=0-0') {
        stdout.writeln(
          'Fixture media: ${jsonEncode({'aid': aid, 'path': r.uri.path, 'start': start})}',
        );
      }
      if (['4', '6', '101'].contains(aid) &&
          r.uri.path == '/video.mp4' &&
          start == 0 &&
          end > 0 &&
          held.add(aid)) {
        final gate = gates[aid] = Completer<void>();
        final half = length ~/ 2;
        await r.response.addStream(file.openRead(0, half));
        await r.response.flush();
        stdout.writeln('Fixture held: $aid');
        // Bound only the fixture's injected stall; no production delay is added.
        await gate.future.timeout(const Duration(seconds: 30));
        await r.response.addStream(file.openRead(half, end + 1));
      } else {
        await r.response.addStream(file.openRead(start, end + 1));
      }
      await r.response.close();
    } on SocketException {
      // Expected when the browser pauses a partly delivered stream.
    } on HttpException {
      // Expected when the downloader cancels the response.
    } on TimeoutException {
      await r.response.close().catchError((_) {});
    }
  });
  var clockOffset = Duration.zero;
  final accessKey = Platform.environment['BILI_FIXTURE_ACCESS_KEY'];
  WebService createService() => WebService(
    webRoot: 'build/web',
    downloadRoot: '${directory.path}/downloads',
    apiFactory: () => BrowserFixtureApi('http://127.0.0.1:${media.port}'),
    access: accessKey == null
        ? null
        : AccessPolicy(
            key: accessKey,
            publicOrigin: Uri.parse(
              Platform.environment['BILI_FIXTURE_PUBLIC_ORIGIN']!,
            ),
            now: () => DateTime.now().add(clockOffset),
          ),
  );
  var service = createService();
  await service.start(port: 18744);
  stdout.writeln('Fixture ready: ${service.origin}');
  ProcessSignal.sigterm.watch().listen((_) async {
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await service.close();
    await media.close(force: true);
    await directory.delete(recursive: true);
    exit(0);
  });
  await for (final command
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (command == 'restart') {
      await service.close();
      service = createService();
      await service.start(port: 18744);
      stdout.writeln('Fixture restarted: ${service.origin}');
    } else if (command == 'release') {
      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      stdout.writeln('Fixture released:');
    } else if (command == 'expire') {
      clockOffset += const Duration(hours: 13);
      stdout.writeln('Fixture expired:');
    }
  }
}
