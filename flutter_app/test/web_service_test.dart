import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/core/wire.dart';
import 'package:bili_downloader/server/web_service.dart';

class ServiceFixtureApi extends BiliApi {
  ServiceFixtureApi(this.mediaUrl);
  final String mediaUrl;
  @override
  Future<VideoInfo> resolve(VideoId id, {CancelToken? cancel}) async =>
      const VideoInfo(
        title: '测试下载',
        description: 'Fixture',
        cover: '',
        id: 'AV1',
        episodes: [
          Episode(cid: 1, aid: 1, number: 1, name: 'Part 1', title: '测试下载'),
        ],
      );
  @override
  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) async => PlayableMedia(
    qualities: const [Quality(80, '1080P')],
    video: [MediaStream(url: mediaUrl, quality: 80)],
    audio: const [],
    mp4: true,
  );
  @override
  Future<LoginQr> generateQr({CancelToken? cancel}) async =>
      const LoginQr('https://example.test/login', 'fixture-key');
  @override
  Future<LoginResult> pollQr(LoginQr qr, {CancelToken? cancel}) async =>
      const LoginResult(0, {
        'SESSDATA': 'fixture-private-cookie',
        'bili_jct': 'fixture-csrf',
      });
}

void main() {
  late Directory temp;
  late WebService service;
  late HttpServer media;
  late HttpClient client;
  var cookie = '';
  final payload = List.generate(8192, (i) => i % 255);
  Future<(int, Map<String, dynamic>, HttpHeaders)> post(
    String path,
    Map<String, dynamic> data, {
    String? session,
    String? origin,
    bool header = true,
  }) async {
    final req = await client.postUrl(Uri.parse('${service.origin}$path'));
    if (header) req.headers.set('X-Bili-Client', '1');
    req.headers.contentType = ContentType.json;
    req.headers.set('Cookie', session ?? cookie);
    if (origin != null) req.headers.set('Origin', origin);
    req.write(jsonEncode(data));
    final res = await req.close();
    return (
      res.statusCode,
      Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(res).join()),
      ),
      res.headers,
    );
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bili-service-test-');
    await File('${temp.path}/index.html').writeAsString('fixture');
    media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    media.listen((r) async {
      r.response.headers.set('etag', 'fixture');
      if (r.headers.value('range') == 'bytes=0-0') {
        r.response.statusCode = 206;
        r.response.headers.set('content-range', 'bytes 0-0/${payload.length}');
        r.response.contentLength = 1;
        r.response.add(payload.take(1).toList());
      } else {
        r.response.contentLength = payload.length;
        r.response.add(payload);
      }
      await r.response.close();
    });
    service = WebService(
      webRoot: temp.path,
      downloadRoot: '${temp.path}/downloads',
      apiFactory: () =>
          ServiceFixtureApi('http://127.0.0.1:${media.port}/video'),
    );
    await service.start(port: 0);
    client = HttpClient();
    cookie = '';
    final response = await post('/api/session', {});
    cookie = response.$3.value('set-cookie')!.split(';').first;
  });
  tearDown(() async {
    client.close(force: true);
    await service.close();
    await media.close(force: true);
    await temp.delete(recursive: true);
  });

  test('same-origin service resolves, streams task events and returns exact file bytes', () async {
    final resolved = await post('/api/resolve', {'input': 'av1'});
    expect(resolved.$1, 200);
    final episode = videoFromJson(resolved.$2).episodes.single;
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${service.port}/api/events',
      headers: {'Cookie': cookie, 'Origin': service.origin},
    );
    final done = socket
        .map((s) => Map<String, dynamic>.from(jsonDecode(s as String)))
        .firstWhere((j) => j['state'] == 'completed');
    final created = await post('/api/jobs', {
      'episode': episode.identity,
      'options': optionsToJson(
        const DownloadOptions(
          directory: '/must-not-use-client-path',
          quality: 80,
        ),
      ),
    });
    expect(created.$1, 200);
    final completed = await done.timeout(const Duration(seconds: 10));
    final url = (completed['outputs'] as List).single['url'] as String;
    final request = await client.getUrl(Uri.parse('${service.origin}$url'));
    request.headers.set('Cookie', cookie);
    final result = await request.close();
    expect(result.statusCode, 200);
    expect(await result.fold<List<int>>([], (a, b) => a..addAll(b)), payload);
    expect((await post('/api/session', {})).$2['jobs'], hasLength(1));
    final other = await post('/api/session', {}, session: '');
    final otherRequest = await client.getUrl(
      Uri.parse('${service.origin}$url'),
    );
    otherRequest.headers.set(
      'Cookie',
      other.$3.value('set-cookie')!.split(';').first,
    );
    final denied = await otherRequest.close();
    await denied.drain<void>();
    expect(denied.statusCode, 404);
    await post('/api/jobs/remove', {
      'ids': [completed['id']],
    });
    expect((await post('/api/session', {})).$2['jobs'], isEmpty);
    expect(
      await Directory('${temp.path}/downloads')
          .list(recursive: true)
          .where((f) => f is File)
          .length,
      1,
    );
    await socket.close();
  });
  test(
    'cross-origin mutations and arbitrary unparsed episodes are rejected',
    () async {
      expect(
        (await post('/api/session', {}, origin: 'https://other.invalid')).$1,
        403,
      );
      expect((await post('/api/session', {}, header: false)).$1, 403);
      expect(
        (await post('/api/jobs', {'episode': 'unknown', 'options': {}})).$1,
        422,
      );
      expect(
        (await post('/api/resolve', {'input': 'av1'}, session: '')).$1,
        401,
      );
    },
  );
  test(
    'QR credentials remain server-side and session cookie is HttpOnly',
    () async {
      final bootstrap = await post('/api/session', {}, session: '');
      expect(bootstrap.$3.value('set-cookie'), contains('HttpOnly'));
      expect(bootstrap.$3.value('set-cookie'), contains('SameSite=Strict'));
      final qr = await post('/api/login/generate', {});
      final login = await post('/api/login/poll', {'key': qr.$2['key']});
      expect(login.$2, {'code': 0});
      expect(jsonEncode(login.$2), isNot(contains('fixture-private-cookie')));
      expect((await post('/api/session', {})).$2['authenticated'], true);
    },
  );
}
