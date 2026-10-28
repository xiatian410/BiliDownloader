import 'dart:convert';

import 'package:dio/dio.dart';

import 'models.dart';
import 'decode.dart';
import 'wbi.dart';
import 'attachments.dart';

const biliHeaders = <String, String>{
  'Referer': 'https://www.bilibili.com/',
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/132.0.0.0 Safari/537.36',
};

const _browser = bool.fromEnvironment('dart.library.js_interop');

class LoginQr {
  const LoginQr(this.url, this.key);
  final String url, key;
}

class LoginResult {
  const LoginResult(this.code, this.cookies);
  final int code;
  final Map<String, String> cookies;
}

class BiliApi {
  BiliApi({
    Dio? dio,
    this.apiOrigin = 'https://api.bilibili.com',
    this.passportOrigin = 'https://passport.bilibili.com',
  }) : dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 20),
               sendTimeout: const Duration(seconds: 15),
             ),
           );
  final Dio dio;
  final String apiOrigin, passportOrigin;
  Map<String, String> cookies = {};
  bool get authenticated => cookies.isNotEmpty;
  Future<void> initializeSession() async {}
  (String, String)? _wbi;

  Map<String, String> get headers => _browser
      ? {}
      : {
          ...biliHeaders,
          if (cookies.isNotEmpty)
            'Cookie': cookies.entries
                .map((e) => '${e.key}=${e.value}')
                .join('; '),
        };

  Future<Response<dynamic>> _request(
    String path, {
    Map<String, dynamic>? query,
    bool passport = false,
    CancelToken? cancel,
    Object? body,
    String method = 'GET',
  }) async {
    try {
      return await dio.request(
        '${passport ? passportOrigin : apiOrigin}$path',
        queryParameters: query,
        data: body,
        cancelToken: cancel,
        options: Options(
          method: method,
          headers: headers,
          contentType: method == 'POST'
              ? Headers.formUrlEncodedContentType
              : null,
        ),
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      if (e.response != null) {
        throw AppFailure('httpError', '${e.response!.statusCode}');
      }
      throw AppFailure(
        _browser ? 'webNetworkError' : 'networkError',
        e.type.name,
      );
    }
  }

  Map<String, dynamic> _json(dynamic data, {bool allowAnonymous = false}) {
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        throw const AppFailure('invalidResponse');
      }
    }
    if (data is! Map) throw const AppFailure('invalidResponse');
    final result = Map<String, dynamic>.from(data);
    final code = result['code'];
    if (code != 0 && !(allowAnonymous && code == -101)) {
      throw AppFailure(
        'apiError',
        '$code: ${result['message'] ?? result['msg'] ?? ''}',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancel,
    String key = 'data',
    bool allowAnonymous = false,
  }) async {
    final root = _json(
      (await _request(path, query: query, cancel: cancel)).data,
      allowAnonymous: allowAnonymous,
    );
    if (root[key] is! Map) throw const AppFailure('invalidResponse');
    return Map<String, dynamic>.from(root[key]);
  }

  Future<VideoInfo> resolve(VideoId id, {CancelToken? cancel}) async {
    if (id.kind == VideoKind.bv || id.kind == VideoKind.av) {
      final data = await get(
        '/x/web-interface/view',
        query: {
          if (id.kind == VideoKind.bv) 'bvid': id.label else 'aid': id.value,
        },
        cancel: cancel,
      );
      final title = data['title'].toString();
      final pages = data['pages'] as List? ?? [];
      if (pages.isEmpty) throw const AppFailure('noEpisodes');
      return VideoInfo(
        title: title,
        description: data['desc']?.toString() ?? '',
        cover: normalizeCoverUrl(data['pic']?.toString() ?? ''),
        author: data['owner']?['name']?.toString() ?? '',
        id: data['bvid'].toString(),
        episodes: pages
            .map(
              (p) => Episode(
                cid: p['cid'] as int,
                number: p['page'] as int,
                name: p['part'].toString(),
                title: title,
                bvid: data['bvid'].toString(),
                aid: data['aid'] as int,
                cover: normalizeCoverUrl(data['pic']?.toString() ?? ''),
                description: data['desc']?.toString() ?? '',
                author: data['owner']?['name']?.toString() ?? '',
              ),
            )
            .toList(),
      );
    }
    final query = <String, dynamic>{};
    if (id.kind == VideoKind.md) {
      final review = await get(
        '/pgc/review/user',
        query: {'media_id': id.value},
        key: 'result',
        cancel: cancel,
      );
      query['season_id'] = review['media']['season_id'];
    } else {
      query['ep_id'] = id.value;
    }
    final data = await get(
      '/pgc/view/web/season',
      query: query,
      key: 'result',
      cancel: cancel,
    );
    final title = data['title'].toString();
    final episodes = (data['episodes'] as List? ?? []).indexed
        .map(
          (p) => Episode(
            cid: p.$2['cid'] as int,
            number: p.$1 + 1,
            name: '${p.$2['title']} ${p.$2['long_title'] ?? ''}'.trim(),
            title: title,
            bvid: p.$2['bvid']?.toString() ?? '',
            aid: (p.$2['aid'] ?? 0) as int,
            epId: p.$2['id'] as int,
            cover: normalizeCoverUrl(
              (p.$2['cover'] ?? data['cover'])?.toString() ?? '',
            ),
            description: data['evaluate']?.toString() ?? '',
          ),
        )
        .toList();
    if (episodes.isEmpty) throw const AppFailure('noEpisodes');
    return VideoInfo(
      title: title,
      description: '${data['evaluate'] ?? ''}\n\n${data['staff'] ?? ''}'.trim(),
      cover: normalizeCoverUrl(data['cover']?.toString() ?? ''),
      id: 'MD${data['media_id']}',
      episodes: episodes,
    );
  }

  Future<CoverImage> fetchCover(String url, {CancelToken? cancel}) async {
    if (url.isEmpty) throw const AppFailure('coverUnavailable');
    final uri = Uri.tryParse(normalizeCoverUrl(url));
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        !(uri.host.endsWith('.hdslb.com') ||
            uri.host.endsWith('.bilibili.com'))) {
      throw const AppFailure('invalidCover');
    }
    // Never forward account cookies to the CDN or follow an unvalidated redirect.
    final response = await dio.get<ResponseBody>(
      uri.toString(),
      cancelToken: cancel,
      options: Options(
        headers: biliHeaders,
        responseType: ResponseType.stream,
        followRedirects: false,
        validateStatus: (s) => s == 200,
      ),
    );
    const limit = 16 * 1024 * 1024;
    if ((int.tryParse(response.headers.value('content-length') ?? '') ?? 0) >
        limit) {
      await response.data!.stream.listen(null).cancel();
      throw const AppFailure('requestTooLarge');
    }
    final bytes = <int>[];
    await for (final chunk in response.data!.stream) {
      if (cancel?.isCancelled ?? false) throw cancel!.cancelError!;
      if (bytes.length + chunk.length > limit) {
        throw const AppFailure('requestTooLarge');
      }
      bytes.addAll(chunk);
    }
    return CoverImage(bytes);
  }

  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) async {
    var params = <String, dynamic>{
      'cid': episode.cid,
      'qn': options.quality,
      'fnval': options.fnval,
      'fnver': 0,
      'fourk': 1,
    };
    if (episode.isBangumi) {
      params['ep_id'] = episode.epId;
      return PlayableMedia.fromJson(
        await get(
          '/pgc/player/web/v2/playurl',
          query: params,
          key: 'result',
          cancel: cancel,
        ),
      );
    }
    params[episode.bvid.isNotEmpty ? 'bvid' : 'avid'] = episode.bvid.isNotEmpty
        ? episode.bvid
        : episode.aid;
    if (options.language.isNotEmpty) params['cur_language'] = options.language;
    if (_wbi == null) {
      final nav = await get(
        '/x/web-interface/nav',
        allowAnonymous: true,
        cancel: cancel,
      );
      String key(dynamic url) =>
          Uri.parse(url.toString()).pathSegments.last.split('.').first;
      final images = nav['wbi_img'];
      if (images is! Map) throw const AppFailure('invalidResponse');
      _wbi = (key(images['img_url']), key(images['sub_url']));
    }
    params = signWbi(params, _wbi!.$1, _wbi!.$2);
    return PlayableMedia.fromJson(
      await get('/x/player/wbi/playurl', query: params, cancel: cancel),
    );
  }

  Future<LoginQr> generateQr({CancelToken? cancel}) async {
    if (_browser) throw const AppFailure('webLoginUnsupported');
    final data = _json(
      (await _request(
        '/x/passport-login/web/qrcode/generate',
        passport: true,
        cancel: cancel,
      )).data,
    )['data'];
    return LoginQr(data['url'].toString(), data['qrcode_key'].toString());
  }

  Future<LoginResult> pollQr(LoginQr qr, {CancelToken? cancel}) async {
    final response = await _request(
      '/x/passport-login/web/qrcode/poll',
      passport: true,
      query: {'qrcode_key': qr.key},
      cancel: cancel,
    );
    final data = _json(response.data)['data'];
    final code = data['code'] as int;
    final result = <String, String>{};
    if (code == 0) {
      for (final raw in response.headers['set-cookie'] ?? <String>[]) {
        final first = raw.split(';').first;
        final index = first.indexOf('=');
        if (index > 0) {
          result[first.substring(0, index).trim()] = first.substring(index + 1);
        }
      }
      if (!result.containsKey('SESSDATA') || !result.containsKey('bili_jct')) {
        throw const AppFailure('invalidLogin');
      }
    }
    return LoginResult(code, result);
  }

  Future<bool> checkLogin() async {
    final nav = await get('/x/web-interface/nav', allowAnonymous: true);
    return nav['isLogin'] == true;
  }

  Future<void> logout() async {
    if (cookies.isNotEmpty) {
      _json(
        (await _request(
          '/login/exit/v2',
          passport: true,
          method: 'POST',
          body: {'biliCSRF': cookies['bili_jct']},
        )).data,
      );
    }
    cookies = {};
    _wbi = null;
  }

  Future<String> danmaku(int cid, {CancelToken? cancel}) async {
    final r = await dio.get<List<int>>(
      '$apiOrigin/x/v1/dm/list.so',
      queryParameters: {'oid': cid},
      cancelToken: cancel,
      options: Options(headers: headers, responseType: ResponseType.bytes),
    );
    final text = r.data == null ? '' : decodeDanmaku(r.data!);
    if (!text.contains('<i>')) {
      throw const AppFailure('invalidResponse');
    }
    return text;
  }

  void close() => dio.close(force: true);
}
