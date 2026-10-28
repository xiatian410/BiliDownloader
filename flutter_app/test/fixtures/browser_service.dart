// Explicit local test fixture; never selected by the production entry point.
import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/server/web_service.dart';

class BrowserFixtureApi extends BiliApi {
  BrowserFixtureApi(this.origin);
  final String origin;
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
          cid: 1001,
          aid: 1,
          number: 1,
          name: '视频与音频合并',
          title: '跨端下载验证',
          bvid: id.kind == VideoKind.bv ? id.label : '',
        ),
      ],
    );
  }

  @override
  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) async => PlayableMedia(
    qualities: const [Quality(120, '4K'), Quality(80, '1080P')],
    video: [MediaStream(url: '$origin/video.mp4', quality: 80, codec: 7)],
    audio: [MediaStream(url: '$origin/audio.m4a', bandwidth: 192000)],
  );
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
    if (range == 'bytes=0-0') {
      r.response.statusCode = 206;
      r.response.headers.set('content-range', 'bytes 0-0/$length');
      r.response.contentLength = 1;
      await r.response.addStream(file.openRead(0, 1));
    } else {
      r.response.contentLength = length;
      await r.response.addStream(file.openRead());
    }
    await r.response.close();
  });
  WebService createService() => WebService(
    webRoot: 'build/web',
    downloadRoot: '${directory.path}/downloads',
    apiFactory: () => BrowserFixtureApi('http://127.0.0.1:${media.port}'),
  );
  var service = createService();
  await service.start(port: 18744);
  stdout.writeln('Fixture ready: ${service.origin}');
  ProcessSignal.sigterm.watch().listen((_) async {
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
    }
  }
}
