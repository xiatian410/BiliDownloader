import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/bili_api.dart';
import '../core/download_job.dart';
import '../core/io_download_runner.dart';
import '../core/models.dart';
import '../core/wire.dart';
import '../core/file_state_store.dart';
import '../core/job_snapshot.dart';
import 'access_policy.dart';

class _Session {
  _Session(this.id, this.api, this.store)
    : tokenHash = id,
      runner = NativeDownloadRunner(api);
  final String id;
  final BiliApi api;
  final NativeDownloadRunner runner;
  final FileStateStore store;
  bool recovered = false;
  AppFailure? storageError;
  Future<void> persistenceTail = Future.value();
  final episodes = <String, Episode>{};
  final covers = <String, String>{};
  final jobs = <String, DownloadJob>{};
  final sockets = <WebSocket>{};
  final qrKeys = <String>{};
  DateTime used = DateTime.now();
  int concurrency = 4;
  int settingsRevision = 0;
  String tokenHash;
  String? accessFingerprint;
  DateTime? accessUntil;
  Timer? accessTimer;
}

/// Same-origin host bound to loopback. Remote mode requires an HTTPS proxy.
class WebService {
  WebService({
    required String webRoot,
    required String downloadRoot,
    BiliApi Function()? apiFactory,
    this.access,
  }) : apiFactory = apiFactory ?? BiliApi.new,
       webRoot = p.normalize(p.absolute(webRoot)),
       downloadRoot = p.normalize(p.absolute(downloadRoot));
  final String webRoot, downloadRoot;
  late final String _realWebRoot, _realDownloadRoot;
  final BiliApi Function() apiFactory;
  final AccessPolicy? access;
  final _sessions = <String, _Session>{};
  final _random = Random.secure();
  HttpServer? _server;
  int _active = 0;
  bool _closed = false;
  FileStateStore? _lease;
  final _running = <Future<void>>{};
  int get port => _server!.port;
  String get origin => 'http://127.0.0.1:$port';

  Future<void> start({int port = 18743}) async {
    if (webRoot == downloadRoot || p.isWithin(webRoot, downloadRoot)) {
      throw const AppFailure('invalidDirectory');
    }
    await Directory(downloadRoot).create(recursive: true);
    // Both sides of containment checks must resolve Windows short names and symlinks.
    _realWebRoot = await Directory(webRoot).resolveSymbolicLinks();
    _realDownloadRoot = await Directory(downloadRoot).resolveSymbolicLinks();
    if (_realWebRoot == _realDownloadRoot ||
        p.isWithin(_realWebRoot, _realDownloadRoot)) {
      throw const AppFailure('invalidDirectory');
    }
    _lease = FileStateStore(p.join(downloadRoot, '.state', 'service'));
    await _lease!.read();
    final directory = Directory(p.join(downloadRoot, '.state'));
    final ids = <String>{};
    await for (final file in directory.list()) {
      final match = RegExp(r'^([a-f0-9]{64})\.[01]\.json$')
          .firstMatch(p.basename(file.path));
      if (match != null) ids.add(match[1]!);
    }
    try {
      for (final id in ids) {
        final store = FileStateStore(p.join(directory.path, id));
        final session = _Session(id, apiFactory(), store);
        _sessions[id] = session;
        final snapshot = await store.read();
        if (snapshot.data['version'] != 1) {
          throw const AppFailure('historyCorrupt');
        }
        session.recovered = snapshot.recovered;
        session.tokenHash = snapshot.data['tokenHash'] as String? ?? id;
        session.accessFingerprint =
            snapshot.data['accessFingerprint'] as String?;
        session.accessUntil = DateTime.tryParse(
          snapshot.data['accessUntil'] as String? ?? '',
        );
        // A fallback record can predate a lock or revocation. Require the key
        // again instead of restoring the fallback's previous authorization.
        if (snapshot.recovered) {
          session.accessFingerprint = null;
          session.accessUntil = null;
        }
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(session.tokenHash)) {
          throw const AppFailure('historyCorrupt');
        }
        session.concurrency = snapshot.data['concurrency'] as int? ?? 4;
        session.settingsRevision =
            snapshot.data['settingsRevision'] as int? ?? 0;
        if (session.concurrency < 1 || session.concurrency > 4) {
          throw const AppFailure('historyCorrupt');
        }
        session.used =
            DateTime.tryParse(snapshot.data['used'] as String? ?? '') ??
            DateTime.now();
        for (final raw in snapshot.data['jobs'] as List? ?? []) {
          final job = restoreJob(Map<String, dynamic>.from(raw));
          final root = p.join(downloadRoot, id);
          final paths = [
            ...job.outputs,
            ...job.pendingExports,
            ...job.expectedMediaOutputs,
            ...job.publications.keys,
            ...job.publications.values.map((v) => v.source),
            ...job.exportedFiles.keys,
            ...job.exportedFiles.values,
          ];
          if (job.options.directory != root ||
              paths.any((path) => !p.isWithin(root, p.normalize(path)))) {
            throw const AppFailure('historyCorrupt');
          }
          job.onCheckpoint = () => _persist(session);
          if (session.jobs.containsKey(job.id)) {
            throw const AppFailure('historyCorrupt');
          }
          session.jobs[job.id] = job;
          session.episodes[job.episode.identity] = job.episode;
        }
      }
    } catch (_) {
      await close();
      rethrow;
    }
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server!.listen((request) => unawaited(_handle(request)));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  String _sessionKey(String token) =>
      sha256.convert(utf8.encode(token)).toString();
  Future<void> _transaction(_Session s, Future<void> Function() action) {
    final next = s.persistenceTail.then((_) => action());
    s.persistenceTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _persist(_Session s) => _transaction(s, () => _writeSession(s));

  Future<void> _writeSession(_Session s, {Iterable<DownloadJob>? jobs}) async {
    try {
      await s.store.write({
        'version': 1,
        'used': s.used.toIso8601String(),
        'concurrency': s.concurrency,
        'settingsRevision': s.settingsRevision,
        'tokenHash': s.tokenHash,
        'accessFingerprint': s.accessFingerprint,
        'accessUntil': s.accessUntil?.toIso8601String(),
        'jobs': (jobs ?? s.jobs.values).map(jobSnapshot).toList(),
      });
      s.storageError = null;
    } catch (e) {
      s.storageError = e is AppFailure
          ? e
          : const AppFailure('historyWriteFailed');
      rethrow;
    }
  }

  String _id() => List.generate(
    32,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  void _json(HttpRequest r, Object value, {int status = 200}) {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(value));
  }

  Future<Map<String, dynamic>> _body(HttpRequest r) async {
    final bytes = <int>[];
    await for (final part in r.timeout(const Duration(seconds: 15))) {
      bytes.addAll(part);
      if (bytes.length > 262144) throw const AppFailure('requestTooLarge');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map) throw const AppFailure('invalidResponse');
    return Map<String, dynamic>.from(data);
  }

  String get _cookieName =>
      access?.secure == true ? '__Host-bili_session' : 'bili_session';
  String? _token(HttpRequest r) {
    final values = r.cookies.where((c) => c.name == _cookieName).toList();
    return values.length == 1
        ? values.single.value
        : values.isEmpty
        ? null
        : '';
  }

  _Session? _session(HttpRequest r) {
    final token = _token(r);
    if (token == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      return null;
    }
    final hash = _sessionKey(token);
    for (final session in _sessions.values) {
      if (session.tokenHash == hash) {
        session.used = DateTime.now();
        return session;
      }
    }
    return null;
  }

  bool _authorized(_Session s) =>
      access == null ||
      (s.accessFingerprint == access!.fingerprint &&
          s.accessUntil != null &&
          access!.now().isBefore(s.accessUntil!));

  void _closeAccessSockets(_Session s) {
    s.accessTimer?.cancel();
    s.accessTimer = null;
    for (final socket in s.sockets.toList()) {
      unawaited(socket.close(4001, 'serviceAccessRequired'));
    }
    s.sockets.clear();
  }

  void _watchAccessExpiry(_Session s) {
    s.accessTimer?.cancel();
    if (access == null) return;
    // One bounded expiry timer per active workspace, never a polling loop.
    final remaining = s.accessUntil!.difference(access!.now());
    s.accessTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => _closeAccessSockets(s),
    );
  }

  void _setCookie(HttpRequest r, String token) => r.response.headers.add(
    'set-cookie',
    '$_cookieName=$token; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000${access?.secure == true ? '; Secure' : ''}',
  );

  Map<String, dynamic> _sessionData(_Session s) => {
    'accessRequired': access != null,
    'accessGranted': true,
    'workspace': s.id,
    'authenticated': s.api.cookies.isNotEmpty,
    'jobs': s.jobs.values.map(_job).toList(),
    'recovered': s.recovered,
    'concurrency': s.concurrency,
    'settingsRevision': s.settingsRevision,
  };

  Future<_Session> _newSession(String token) async {
    for (final old in _sessions.values.toList()) {
      if (DateTime.now().difference(old.used) > const Duration(days: 30) &&
          old.jobs.isEmpty &&
          old.sockets.isEmpty) {
        _sessions.remove(old.id);
        old.accessTimer?.cancel();
        old.runner.dispose();
        old.api.close();
        await old.store.close();
      }
    }
    if (_sessions.length >= 32) throw const AppFailure('serviceBusy');
    final id = _sessionKey(token);
    final store = FileStateStore(p.join(downloadRoot, '.state', id));
    final s = _Session(id, apiFactory(), store);
    _sessions[id] = s;
    try {
      await store.read();
    } catch (_) {
      _sessions.remove(id);
      s.api.close();
      s.runner.dispose();
      await store.close();
      rethrow;
    }
    return s;
  }

  Future<void> _discardNewSession(_Session s) async {
    _sessions.remove(s.id);
    s.api.close();
    s.runner.dispose();
    await s.store.close();
  }

  Map<String, dynamic> _job(DownloadJob j) => {
    'id': j.id,
    'requestId': j.submissionKey,
    'revision': j.revision,
    'state': j.state.name,
    'stage': j.stage,
    'detail': j.detail,
    'received': j.received,
    'total': j.total,
    'actualQuality': j.actualQuality,
    'merge': j.mergeProgress?.toJson(),
    'attachments': j.attachments.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'error': j.error == null
        ? null
        : {'key': j.error!.key, 'detail': j.error!.detail},
    'episode': episodeToJson(j.episode),
    'options': optionsToJson(j.options)..remove('directory'),
    'outputs': [
      for (var i = 0; i < j.outputs.length; i++)
        {'name': p.basename(j.outputs[i]), 'url': '/api/files/${j.id}/$i'},
    ],
  };
  void _emit(_Session s, DownloadJob j) {
    j.revision++;
    _broadcast(s, _job(j));
  }

  void _broadcast(_Session s, Map<String, dynamic> event) {
    if (!_authorized(s)) {
      _closeAccessSockets(s);
      return;
    }
    final data = jsonEncode(event);
    for (final socket in s.sockets.toList()) {
      if (socket.readyState == WebSocket.open) socket.add(data);
    }
  }

  void _schedule() {
    if (_closed) return;
    for (final s in _sessions.values) {
      if (s.storageError != null) continue;
      for (final j in s.jobs.values) {
        if (_active >= 4) return;
        if (s.jobs.values.where((j) => j.active).length >= s.concurrency) break;
        if (j.state != JobState.queued) continue;
        // Serialise identical destinations even across simultaneous submissions.
        if (s.jobs.values.any(
          (other) =>
              other.active && other.episode.identity == j.episode.identity,
        )) {
          continue;
        }
        _active++;
        j.state = JobState.running;
        j.token = CancelToken();
        final future = _run(s, j);
        _running.add(future);
        unawaited(future.whenComplete(() => _running.remove(future)));
      }
    }
  }

  Future<List<DownloadJob>> _createJobs(
    _Session s,
    List<Map<String, dynamic>> entries, {
    bool requireKeys = false,
  }) async {
    if (entries.isEmpty || entries.length > 200) {
      throw const AppFailure('serviceBusy');
    }
    final result = <DownloadJob>[];
    await _transaction(s, () async {
      final additions = <DownloadJob>[];
      final keys = <String>{};
      for (final body in entries) {
        final episode = s.episodes[body['episode']];
        if (episode == null) throw const AppFailure('noEpisodes');
        final requestId = body['requestId'];
        if ((requestId == null && requireKeys) ||
            (requestId != null &&
                (requestId is! String ||
                    !RegExp(r'^[a-zA-Z0-9_-]{1,96}$').hasMatch(requestId) ||
                    !keys.add(requestId)))) {
          throw const AppFailure('invalidResponse');
        }
        final options = optionsFromJson(
          Map<String, dynamic>.from(body['options']),
          directory: p.join(downloadRoot, s.id),
        );
        DownloadJob? previous;
        if (requestId != null) {
          for (final job in s.jobs.values) {
            if (job.submissionKey == requestId) {
              previous = job;
              break;
            }
          }
        }
        if (previous != null) {
          if (previous.episode.identity != episode.identity ||
              jsonEncode(optionsToJson(previous.options)) !=
                  jsonEncode(optionsToJson(options))) {
            throw const AppFailure('invalidResponse');
          }
          result.add(previous);
        } else {
          final job = DownloadJob(episode, options)
            ..submissionKey = requestId as String?;
          job.onCheckpoint = () => _persist(s);
          additions.add(job);
          result.add(job);
        }
      }
      if (s.jobs.length + additions.length > 200) {
        throw const AppFailure('serviceBusy');
      }
      // Publish only after the entire batch is durable. An unrelated task can
      // finish (and call _schedule) while this write is awaiting the filesystem.
      await _writeSession(s, jobs: [...s.jobs.values, ...additions]);
      for (final job in additions) {
        s.jobs[job.id] = job;
      }
    });
    for (final job in result) {
      _emit(s, job);
    }
    return result;
  }

  Future<void> _run(_Session s, DownloadJob j) async {
    try {
      j.error = null;
      await _persist(s);
      await s.runner.run(j, () => _emit(s, j));
      j.state = JobState.completed;
      j.stage = 'completed';
      await _persist(s);
    } on DioException catch (e) {
      j.state = CancelToken.isCancel(e) ? JobState.paused : JobState.failed;
      if (!CancelToken.isCancel(e)) {
        j.error = AppFailure(
          'networkError',
          e.response?.statusCode.toString() ?? e.type.name,
        );
      }
    } catch (e) {
      j.state = JobState.failed;
      j.error = e is AppFailure ? e : const AppFailure('downloadFailed');
    } finally {
      if (s.storageError == null) {
        try {
          await _persist(s);
        } catch (_) {
          j.state = JobState.failed;
          j.error = s.storageError;
        }
      }
      _active--;
      _emit(s, j);
      _schedule();
    }
  }

  Future<void> _handle(HttpRequest r) async {
    var upgraded = false;
    try {
      final host = r.headers.value('host');
      final expected =
          access?.publicOrigin?.origin ??
          (host == 'localhost:$port' ? 'http://localhost:$port' : origin);
      final hostAllowed = access?.publicOrigin != null
          ? host == access!.publicOrigin!.authority
          : host == '127.0.0.1:$port' || host == 'localhost:$port';
      if (!hostAllowed) {
        _json(r, {'error': 'forbidden'}, status: 403);
        return;
      }
      final requestOrigin = r.headers.value('origin');
      if (requestOrigin != null && requestOrigin != expected) {
        _json(r, {'error': 'forbidden'}, status: 403);
        return;
      }
      r.response.headers.set('X-Content-Type-Options', 'nosniff');
      r.response.headers.set('Referrer-Policy', 'no-referrer');
      r.response.headers.set('X-Frame-Options', 'DENY');
      final route = r.uri.path;
      if (!route.startsWith('/api/')) {
        await _static(r);
        return;
      }
      r.response.headers.set('Cache-Control', 'no-store');
      if (r.method == 'POST' && r.headers.value('x-bili-client') != '1') {
        _json(r, {'error': 'forbidden'}, status: 403);
        return;
      }
      if (route == '/api/access/unlock' && r.method == 'POST') {
        final body = await _body(r);
        if (access != null && !access!.accepts(body['key'])) {
          _json(r, {'error': 'invalidServiceKey'}, status: 403);
          return;
        }
        var s = _session(r);
        if (s == null && _token(r) != null && body['newWorkspace'] != true) {
          _json(r, {
            'error': 'serviceSessionExpired',
            'accessRequired': access != null,
          }, status: 401);
          return;
        }
        final token = _id();
        final isNew = s == null;
        s ??= await _newSession(token);
        final session = s;
        final originalHash = session.tokenHash;
        try {
          await _transaction(session, () async {
            if (session.tokenHash != originalHash) {
              throw const AppFailure('serviceAccessRequired');
            }
            final previous = (
              session.tokenHash,
              session.accessFingerprint,
              session.accessUntil,
            );
            session.tokenHash = _sessionKey(token);
            session.accessFingerprint = access?.fingerprint;
            session.accessUntil = access == null
                ? null
                : access!.now().toUtc().add(access!.lifetime);
            try {
              await _writeSession(session);
            } catch (_) {
              session.tokenHash = previous.$1;
              session.accessFingerprint = previous.$2;
              session.accessUntil = previous.$3;
              rethrow;
            }
          });
        } catch (_) {
          if (isNew) await _discardNewSession(session);
          rethrow;
        }
        _closeAccessSockets(s);
        _setCookie(r, token);
        _json(r, _sessionData(s));
        return;
      }
      if (route == '/api/session' && r.method == 'POST') {
        final body = await _body(r);
        var s = _session(r);
        if (s == null &&
            (_token(r) != null || body['existingWorkspace'] == true)) {
          _json(r, {
            'error': 'serviceSessionExpired',
            'accessRequired': access != null,
          }, status: 401);
          return;
        }
        if (access != null && (s == null || !_authorized(s))) {
          if (s != null) _closeAccessSockets(s);
          _json(r, {'accessRequired': true, 'accessGranted': false});
          return;
        }
        final token = _token(r) ?? _id();
        final isNew = s == null;
        s ??= await _newSession(token);
        try {
          await _persist(s);
        } catch (_) {
          if (isNew) await _discardNewSession(s);
          rethrow;
        }
        // A concurrent unlock may have rotated the cookie while saving.
        if (s.tokenHash == _sessionKey(token)) _setCookie(r, token);
        _json(r, _sessionData(s));
        return;
      }
      final s = _session(r);
      if (s == null) {
        _json(r, {
          'error': 'serviceSessionExpired',
          'accessRequired': access != null,
        }, status: 401);
        return;
      }
      if (!_authorized(s)) {
        _closeAccessSockets(s);
        _json(r, {
          'error': 'serviceAccessRequired',
          'accessRequired': true,
        }, status: 401);
        return;
      }
      if (route == '/api/access/lock' && r.method == 'POST') {
        await _transaction(s, () async {
          final previous = (s.accessFingerprint, s.accessUntil);
          s.accessFingerprint = null;
          s.accessUntil = null;
          try {
            await _writeSession(s);
          } catch (_) {
            s.accessFingerprint = previous.$1;
            s.accessUntil = previous.$2;
            rethrow;
          }
        });
        _closeAccessSockets(s);
        _json(r, {'ok': true});
        return;
      }
      if (route == '/api/events' && WebSocketTransformer.isUpgradeRequest(r)) {
        if (s.sockets.length >= 8) {
          _json(r, {'error': 'serviceBusy'}, status: 429);
          return;
        }
        final socket = await WebSocketTransformer.upgrade(r);
        upgraded = true;
        s.sockets.add(socket);
        _watchAccessExpiry(s);
        socket.listen(
          (_) {},
          onDone: () => s.sockets.remove(socket),
          onError: (_) => s.sockets.remove(socket),
        );
        socket.add(
          jsonEncode({
            'type': 'snapshot',
            'jobs': s.jobs.values.map(_job).toList(),
            'concurrency': s.concurrency,
            'settingsRevision': s.settingsRevision,
          }),
        );
        return;
      }
      if (route.startsWith('/api/cover/') && r.method == 'GET') {
        final url = s.covers[r.uri.pathSegments.last];
        if (url == null) {
          _json(r, {'error': 'notFound'}, status: 404);
          return;
        }
        final image = await s.api.fetchCover(url);
        r.response.headers.set('Content-Type', image.contentType);
        if (r.uri.queryParameters['download'] == '1') {
          r.response.headers.set(
            'Content-Disposition',
            'attachment; filename="cover.${image.extension}"',
          );
        }
        r.response.add(image.bytes);
        return;
      }
      if (route.startsWith('/api/files/') && r.method == 'GET') {
        final parts = r.uri.pathSegments;
        final job = parts.length == 4 ? s.jobs[parts[2]] : null;
        final index = parts.length == 4 ? int.tryParse(parts[3]) : null;
        if (job == null ||
            index == null ||
            index < 0 ||
            index >= job.outputs.length) {
          _json(r, {'error': 'notFound'}, status: 404);
          return;
        }
        final file = File(job.outputs[index]);
        if (!await file.exists() ||
            !p.isWithin(
              p.join(_realDownloadRoot, s.id),
              await file.resolveSymbolicLinks(),
            )) {
          _json(r, {'error': 'notFound'}, status: 404);
          return;
        }
        r.response.headers.contentType = ContentType.binary;
        r.response.headers.set(
          'Content-Disposition',
          "attachment; filename*=UTF-8''${Uri.encodeComponent(p.basename(file.path))}",
        );
        r.response.contentLength = await file.length();
        await r.response.addStream(file.openRead());
        return;
      }
      if (r.method != 'POST') {
        _json(r, {'error': 'notFound'}, status: 404);
        return;
      }
      final body = await _body(r);
      switch (route) {
        case '/api/resolve':
          final id = VideoId.parse(body['input'] as String? ?? '');
          if (id == null) throw const AppFailure('invalidBatch');
          final info = await s.api.resolve(id);
          if (s.episodes.length + info.episodes.length > 10000) {
            throw const AppFailure('serviceBusy');
          }
          for (final e in info.episodes) {
            s.episodes[e.identity] = e;
          }
          final result = videoToJson(info);
          if (info.cover.isNotEmpty) {
            final key = sha256.convert(utf8.encode(info.cover)).toString();
            s.covers[key] = info.cover;
            result['cover'] = '/api/cover/$key';
          }
          _json(r, result);
        case '/api/play':
          final episode = s.episodes[body['episode']];
          if (episode == null) throw const AppFailure('noEpisodes');
          final options = optionsFromJson(
            Map<String, dynamic>.from(body['options']),
            directory: '',
          );
          _json(r, mediaToJson(await s.api.play(episode, options)));
        case '/api/login/generate':
          final qr = await s.api.generateQr();
          s.qrKeys.clear();
          s.qrKeys.add(qr.key);
          _json(r, {'url': qr.url, 'key': qr.key});
        case '/api/login/poll':
          final key = body['key'] as String? ?? '';
          if (!s.qrKeys.contains(key)) throw const AppFailure('invalidLogin');
          final result = await s.api.pollQr(LoginQr('', key));
          if (result.code == 0) {
            s.api.cookies = result.cookies;
            s.qrKeys.clear();
          }
          _json(r, {'code': result.code});
        case '/api/login/check':
          _json(r, {'authenticated': await s.api.checkLogin()});
        case '/api/login/logout':
          await s.api.logout();
          _json(r, {'ok': true});
        case '/api/jobs':
          final jobs = await _createJobs(s, [body]);
          _json(r, _job(jobs.single));
          _schedule();
        case '/api/jobs/batch':
          final raw = body['jobs'];
          if (raw is! List) throw const AppFailure('invalidResponse');
          final jobs = await _createJobs(
            s,
            raw.map((j) => Map<String, dynamic>.from(j)).toList(),
            requireKeys: true,
          );
          _json(r, {'jobs': jobs.map(_job).toList()});
          _schedule();
        case '/api/settings':
          final value = body['concurrency'];
          if (value is! int || value < 1 || value > 4) {
            throw const AppFailure('invalidConcurrency');
          }
          await _transaction(s, () async {
            final previous = s.concurrency;
            final previousRevision = s.settingsRevision;
            s.concurrency = value;
            s.settingsRevision++;
            try {
              await _writeSession(s);
            } catch (_) {
              s.concurrency = previous;
              s.settingsRevision = previousRevision;
              rethrow;
            }
          });
          final data = {
            'type': 'settings',
            'concurrency': s.concurrency,
            'revision': s.settingsRevision,
          };
          _broadcast(s, data);
          _json(r, data);
          _schedule();
        case '/api/jobs/remove':
          final ids = body['ids'];
          if (ids is! List || ids.length > 200) {
            throw const AppFailure('invalidResponse');
          }
          final removed = <String, DownloadJob>{};
          await _transaction(s, () async {
            for (final id in ids) {
              final job = s.jobs[id];
              if (job?.state == JobState.completed) {
                removed[job!.id] = job;
                s.jobs.remove(id);
              }
            }
            try {
              await _writeSession(s);
            } catch (_) {
              s.jobs.addAll(removed);
              rethrow;
            }
          });
          _broadcast(s, {'type': 'removed', 'ids': removed.keys.toList()});
          _json(r, {'ok': true});
        case '/api/jobs/control':
          final j = s.jobs[body['id']];
          if (j == null) throw const AppFailure('notFound');
          if (body['action'] == 'pause') {
            if (j.state == JobState.queued) {
              j.state = JobState.paused;
            } else if ([JobState.running, JobState.merging].contains(j.state)) {
              j.state = JobState.pausing;
              j.stage = 'pausing';
              j.token.cancel('pause');
            }
          } else if (body['action'] == 'resume' && j.canResume) {
            j.state = JobState.queued;
          }
          await _persist(s);
          _schedule();
          _emit(s, j);
          _json(r, _job(j));
        default:
          _json(r, {'error': 'notFound'}, status: 404);
      }
    } on AppFailure catch (e) {
      _json(r, {
        'error': e.key,
        'detail': e.detail,
        if (e.key == 'serviceAccessRequired') 'accessRequired': access != null,
      }, status: e.key == 'serviceAccessRequired' ? 401 : 422);
    } on FileSystemException {
      _json(r, {'error': 'saveFailed'}, status: 500);
    } catch (_) {
      _json(r, {'error': 'invalidResponse'}, status: 400);
    } finally {
      if (!upgraded) await r.response.close();
    }
  }

  Future<void> _static(HttpRequest r) async {
    if (!['GET', 'HEAD'].contains(r.method)) {
      r.response.statusCode = 405;
      return;
    }
    final root = p.normalize(p.absolute(webRoot));
    final relative = r.uri.path == '/' ? 'index.html' : r.uri.path.substring(1);
    final path = p.normalize(p.join(root, relative));
    if (!p.isWithin(root, path)) {
      r.response.statusCode = 403;
      return;
    }
    final file = File(path);
    if (!await file.exists() ||
        !p.isWithin(_realWebRoot, await file.resolveSymbolicLinks())) {
      r.response.statusCode = 404;
      return;
    }
    final types = {
      '.html': 'text/html; charset=utf-8',
      '.js': 'text/javascript',
      '.wasm': 'application/wasm',
      '.json': 'application/json',
      '.css': 'text/css',
      '.png': 'image/png',
      '.svg': 'image/svg+xml',
      '.ttf': 'font/ttf',
    };
    r.response.headers.set(
      'Content-Type',
      types[p.extension(path)] ?? 'application/octet-stream',
    );
    if (path.endsWith('index.html')) {
      r.response.headers.set('Cache-Control', 'no-cache');
    }
    r.response.contentLength = await file.length();
    if (r.method == 'GET') await r.response.addStream(file.openRead());
  }

  Future<void> close() async {
    _closed = true;
    for (final s in _sessions.values) {
      s.accessTimer?.cancel();
      for (final j in s.jobs.values) {
        j.token.cancel('shutdown');
      }
      for (final socket in s.sockets.toList()) {
        await socket.close();
      }
    }
    await Future.wait(_running.toList());
    for (final s in _sessions.values) {
      await s.persistenceTail;
      s.runner.dispose();
      s.api.close();
      await s.store.close();
    }
    await _server?.close(force: true);
    await _lease?.close();
  }
}
