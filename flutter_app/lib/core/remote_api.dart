import 'package:dio/dio.dart';

import 'bili_api.dart';
import 'models.dart';
import 'wire.dart';

class RemoteBiliApi extends BiliApi {
  RemoteBiliApi({Dio? client, Uri? origin})
    : origin = origin ?? Uri.base,
      super(dio: client);
  final Uri origin;
  bool _authenticated = false;
  @override
  bool get authenticated => _authenticated;
  List<dynamic> restoredJobs = [];
  Future<Map<String, dynamic>> call(
    String path, [
    Map<String, dynamic> body = const {},
    CancelToken? cancel,
  ]) async {
    try {
      final r = await dio.post<dynamic>(
        origin.resolve(path).toString(),
        data: body,
        cancelToken: cancel,
        options: Options(headers: {'X-Bili-Client': '1'}),
      );
      if (r.data is! Map) throw const AppFailure('serviceUnavailable');
      return Map<String, dynamic>.from(r.data);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      final data = e.response?.data;
      if (data is Map && data['error'] is String) {
        throw AppFailure(
          data['error'] as String,
          data['detail'] as String? ?? '',
        );
      }
      throw const AppFailure('serviceUnavailable');
    }
  }

  @override
  Future<void> initializeSession() async {
    final data = await call('/api/session');
    _authenticated = data['authenticated'] == true;
    restoredJobs = data['jobs'] as List? ?? [];
  }

  @override
  Future<VideoInfo> resolve(VideoId id, {CancelToken? cancel}) async =>
      videoFromJson(await call('/api/resolve', {'input': id.label}, cancel));
  @override
  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) async => mediaFromJson(
    await call('/api/play', {
      'episode': episode.identity,
      'options': optionsToJson(options),
    }, cancel),
  );
  @override
  Future<LoginQr> generateQr({CancelToken? cancel}) async {
    final data = await call('/api/login/generate', {}, cancel);
    return LoginQr(data['url'] as String, data['key'] as String);
  }

  @override
  Future<LoginResult> pollQr(LoginQr qr, {CancelToken? cancel}) async {
    final data = await call('/api/login/poll', {'key': qr.key}, cancel);
    final code = data['code'] as int;
    if (code == 0) _authenticated = true;
    return LoginResult(code, const {});
  }

  @override
  Future<bool> checkLogin() async {
    _authenticated = (await call('/api/login/check'))['authenticated'] == true;
    return _authenticated;
  }

  @override
  Future<void> logout() async {
    await call('/api/login/logout');
    _authenticated = false;
  }
}
