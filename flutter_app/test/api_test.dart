import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/models.dart';

void main() {
  late HttpServer server;
  late BiliApi api;
  final seen = <Uri>[];
  var responseCode = 0;
  setUp(() async {
    responseCode = 0;
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      seen.add(r.uri);
      Object data = {};
      switch (r.uri.path) {
        case '/x/web-interface/view':
          data = {
            'title': 'Example',
            'desc': '',
            'bvid': 'BV1xx411c7mD',
            'aid': 170001,
            'pages': [
              {'cid': 42, 'page': 1, 'part': 'Part'},
            ],
          };
        case '/x/web-interface/nav':
          data = {
            'wbi_img': {
              'img_url': 'https://i.test/7cd084941338484aae1ad9425b84077c.png',
              'sub_url': 'https://i.test/4932caff0ff746eab6f01bf08b70ac45.png',
            },
          };
        case '/x/player/wbi/playurl':
          data = {
            'dash': {
              'video': [
                {'id': 80, 'baseUrl': 'https://cdn.test/v', 'codecid': 7},
              ],
              'audio': null,
            },
          };
        case '/pgc/review/user':
          data = {
            'media': {'season_id': 22},
          };
        case '/pgc/view/web/season':
          data = {
            'title': 'Series',
            'media_id': 33,
            'episodes': [
              {'cid': 1, 'id': 44, 'title': '1', 'bvid': 'BV1xx411c7mD'},
            ],
          };
        case '/pgc/player/web/v2/playurl':
          data = {
            'video_info': {
              'quality': 80,
              'durl': [
                {'url': 'https://cdn.test/v.mp4'},
              ],
            },
          };
        case '/x/passport-login/web/qrcode/generate':
          data = {
            'url': 'https://passport.bilibili.com/example',
            'qrcode_key': 'fixture-key',
          };
        case '/x/passport-login/web/qrcode/poll':
          data = {'code': 0};
          r.response.headers.add(
            'set-cookie',
            'SESSDATA=fixture; Path=/; HttpOnly',
          );
          r.response.headers.add('set-cookie', 'bili_jct=fixture-csrf; Path=/');
      }
      r.response.headers.contentType = ContentType.json;
      r.response.write(
        jsonEncode({
          'code': responseCode,
          'message': responseCode == 0 ? 'ok' : 'fixture failure',
          'data': data,
          'result': data,
        }),
      );
      await r.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    api = BiliApi(apiOrigin: base, passportOrigin: base);
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });
  test('video details feed WBI-signed playurl with selected quality', () async {
    final info = await api.resolve(VideoId.parse('av170001')!);
    expect(info.episodes.single.cid, 42);
    final media = await api.play(
      info.episodes.single,
      const DownloadOptions(directory: '/tmp', quality: 80),
    );
    expect(media.video.single.url, 'https://cdn.test/v');
    final request = seen.last;
    expect(request.path, '/x/player/wbi/playurl');
    expect(request.queryParameters['qn'], '80');
    expect(request.queryParameters['w_rid'], hasLength(32));
  });
  test('MD resolves season and retains episode ID for the PGC API', () async {
    final info = await api.resolve(VideoId.parse('md33')!);
    expect(info.episodes.single.epId, 44);
    final media = await api.play(
      info.episodes.single,
      const DownloadOptions(directory: '/tmp', quality: 80),
    );
    expect(media.mp4, true);
    expect(seen.last.queryParameters['ep_id'], '44');
  });
  test('QR login obtains cookies from separate Set-Cookie headers', () async {
    final qr = await api.generateQr();
    final result = await api.pollQr(qr);
    expect(result.cookies, {'SESSDATA': 'fixture', 'bili_jct': 'fixture-csrf'});
  });
  test(
    'API error remains distinguishable from mapping or rendering failures',
    () async {
      responseCode = -404;
      await expectLater(
        api.resolve(VideoId.parse('av170001')!),
        throwsA(
          isA<AppFailure>()
              .having((e) => e.key, 'key', 'apiError')
              .having((e) => e.detail, 'detail', contains('-404')),
        ),
      );
    },
  );
}
