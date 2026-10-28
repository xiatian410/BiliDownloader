import 'dart:async';

import 'package:dio/dio.dart';

import 'bili_api.dart';
import 'models.dart';
import 'wire.dart';
import 'service_access.dart';
import 'subtitles.dart';

class RemoteBiliApi extends BiliApi implements ServiceAccess {
  RemoteBiliApi({Dio? client, Uri? origin})
    : origin = origin ?? Uri.base,
      super(dio: client);
  final Uri origin;
  bool _authenticated = false;
  @override
  bool get authenticated => _authenticated;
  List<dynamic> restoredJobs = [];
  int serverConcurrency = 4;
  int serverSettingsRevision = 0;
  bool recoveredHistory = false;
  final _accessChanges = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get accessChanges => _accessChanges.stream;
  @override
  bool serviceLocked = false;
  @override
  bool requiresServiceKey = false;
  @override
  bool serviceSessionLost = false;
  @override
  String? workspaceId;
  @override
  void rememberWorkspace(String? id) => workspaceId = id;

  void requireServiceAccess({bool lost = false}) {
    if (_accessChanges.isClosed) return;
    serviceLocked = true;
    serviceSessionLost = lost;
    _authenticated = false;
    if (!_accessChanges.isClosed) _accessChanges.add(null);
  }

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
        if (e.response?.statusCode == 401) {
          requiresServiceKey = data['accessRequired'] == true;
          requireServiceAccess(lost: data['error'] == 'serviceSessionExpired');
        }
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
    final data = await call('/api/session', {
      'existingWorkspace': workspaceId != null,
    });
    _acceptSession(data);
  }

  void _acceptSession(Map<String, dynamic> data) {
    requiresServiceKey = data['accessRequired'] == true;
    if (data['accessGranted'] == false) {
      requireServiceAccess();
      throw const AppFailure('serviceAccessRequired');
    }
    serviceLocked = false;
    serviceSessionLost = false;
    workspaceId = data['workspace'] as String?;
    _authenticated = data['authenticated'] == true;
    restoredJobs = data['jobs'] as List? ?? [];
    serverConcurrency = data['concurrency'] as int? ?? 4;
    serverSettingsRevision = data['settingsRevision'] as int? ?? 0;
    recoveredHistory = data['recovered'] == true;
    _accessChanges.add(null);
  }

  @override
  Future<void> unlockService(String key, {bool newWorkspace = false}) async =>
      _acceptSession(
        await call('/api/access/unlock', {
          'key': key,
          'newWorkspace': newWorkspace,
        }),
      );

  @override
  Future<void> lockService() async {
    await call('/api/access/lock');
    requireServiceAccess();
  }

  @override
  void close() {
    unawaited(_accessChanges.close());
    super.close();
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
  Future<List<SubtitleTrack>> subtitles(
    Episode episode, {
    CancelToken? cancel,
  }) async {
    final data = await call('/api/subtitles', {
      'episode': episode.identity,
    }, cancel);
    return (data['tracks'] as List)
        .map((m) => SubtitleTrack.fromJson(m as Map))
        .toList();
  }

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
