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

class _Session {
  _Session(this.id, this.api, this.store) : runner = NativeDownloadRunner(api);
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
}

/// Same-origin local web host. Remote exposure requires a separate authenticated gateway.
class WebService {
  WebService({
    required String webRoot,
    required String downloadRoot,
    BiliApi Function()? apiFactory,
  }) : apiFactory = apiFactory ?? BiliApi.new,
       webRoot = p.normalize(p.absolute(webRoot)),
       downloadRoot = p.normalize(p.absolute(downloadRoot));
  final String webRoot, downloadRoot;
  late final String _realWebRoot, _realDownloadRoot;
  final BiliApi Function() apiFactory;
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

  Future<void> _writeSession(_Session s) async {
    try {
      await s.store.write({
        'version': 1,
        'used': s.used.toIso8601String(),
        'jobs': s.jobs.values.map(jobSnapshot).toList(),
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
      if (bytes.length > 65536) throw const AppFailure('requestTooLarge');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map) throw const AppFailure('invalidResponse');
    return Map<String, dynamic>.from(data);
  }

  _Session? _session(HttpRequest r) {
    for (final c in r.cookies) {
      if (c.name == 'bili_session') {
        final session = _sessions[_sessionKey(c.value)];
        if (session != null) session.used = DateTime.now();
        return session;
      }
    }
    return null;
  }

  Map<String, dynamic> _job(DownloadJob j) => {
    'id': j.id,
    'state': j.state.name,
    'stage': j.stage,
    'detail': j.detail,
    'received': j.received,
    'total': j.total,
    'actualQuality': j.actualQuality,
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
    final data = jsonEncode(_job(j));
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
      final expected = host == 'localhost:$port'
          ? 'http://localhost:$port'
          : origin;
      if (host != '127.0.0.1:$port' && host != 'localhost:$port') {
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
      if (route == '/api/session' && r.method == 'POST') {
        var s = _session(r);
        if (s == null) {
          // Expire idle sessions only on incoming work, with no background polling.
          for (final old in _sessions.values.toList()) {
            if (DateTime.now().difference(old.used) >
                    const Duration(days: 30) &&
                old.jobs.isEmpty &&
                old.sockets.isEmpty) {
              _sessions.remove(old.id);
              old.runner.dispose();
              old.api.close();
              await old.store.close();
              for (final socket in old.sockets) {
                unawaited(socket.close());
              }
            }
          }
          if (_sessions.length >= 32) {
            _json(r, {'error': 'serviceBusy'}, status: 429);
            return;
          }
          final token = _id();
          final id = _sessionKey(token);
          final store = FileStateStore(p.join(downloadRoot, '.state', id));
          s = _Session(id, apiFactory(), store);
          _sessions[s.id] = s;
          try {
            await store.read();
          } catch (_) {
            _sessions.remove(id);
            s.api.close();
            s.runner.dispose();
            await store.close();
            rethrow;
          }
          r.response.headers.add(
            'set-cookie',
            'bili_session=$token; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000',
          );
        } else {
          final token = r.cookies
              .firstWhere((c) => c.name == 'bili_session')
              .value;
          r.response.headers.add(
            'set-cookie',
            'bili_session=$token; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000',
          );
        }
        await _persist(s);
        _json(r, {
          'authenticated': s.api.cookies.isNotEmpty,
          'jobs': s.jobs.values.map(_job).toList(),
          'recovered': s.recovered,
        });
        return;
      }
      final s = _session(r);
      if (s == null) {
        _json(r, {'error': 'serviceSessionExpired'}, status: 401);
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
        socket.listen(
          (_) {},
          onDone: () => s.sockets.remove(socket),
          onError: (_) => s.sockets.remove(socket),
        );
        for (final j in s.jobs.values) {
          socket.add(jsonEncode(_job(j)));
        }
        return;
      }
      if (route.startsWith('/api/cover/') && r.method == 'GET') {
        final url = s.covers[r.uri.pathSegments.last];
        final uri = url == null ? null : Uri.tryParse(url);
        if (uri == null ||
            uri.scheme != 'https' ||
            !(uri.host.endsWith('.hdslb.com') ||
                uri.host.endsWith('.bilibili.com'))) {
          _json(r, {'error': 'notFound'}, status: 404);
          return;
        }
        final image = await s.api.dio.get<ResponseBody>(
          url!,
          options: Options(
            headers: biliHeaders,
            responseType: ResponseType.stream,
            followRedirects: false,
          ),
        );
        final type = image.headers.value('content-type')?.split(';').first;
        final ext = const {
          'image/jpeg': 'jpg',
          'image/png': 'png',
          'image/webp': 'webp',
          'image/avif': 'avif',
        }[type];
        if (ext == null) {
          await image.data!.stream.listen(null).cancel();
          throw const AppFailure('invalidResponse');
        }
        final bytes = <int>[];
        await for (final chunk in image.data!.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 16 * 1024 * 1024) {
            throw const AppFailure('requestTooLarge');
          }
        }
        r.response.headers.set('Content-Type', type!);
        if (r.uri.queryParameters['download'] == '1') {
          r.response.headers.set(
            'Content-Disposition',
            'attachment; filename="cover.$ext"',
          );
        }
        r.response.add(bytes);
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
          final episode = s.episodes[body['episode']];
          if (episode == null) throw const AppFailure('noEpisodes');
          if (s.jobs.length >= 200) throw const AppFailure('serviceBusy');
          final options = optionsFromJson(
            Map<String, dynamic>.from(body['options']),
            directory: p.join(downloadRoot, s.id),
          );
          final j = DownloadJob(episode, options);
          j.onCheckpoint = () => _persist(s);
          await _transaction(s, () async {
            if (s.jobs.length >= 200) throw const AppFailure('serviceBusy');
            s.jobs[j.id] = j;
            try {
              await _writeSession(s);
            } catch (_) {
              s.jobs.remove(j.id);
              rethrow;
            }
          });
          _json(r, _job(j));
          _schedule();
        case '/api/jobs/remove':
          final ids = body['ids'];
          if (ids is! List || ids.length > 200) {
            throw const AppFailure('invalidResponse');
          }
          await _transaction(s, () async {
            final removed = <String, DownloadJob>{};
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
          _json(r, {'ok': true});
        case '/api/jobs/control':
          final j = s.jobs[body['id']];
          if (j == null) throw const AppFailure('notFound');
          if (body['action'] == 'pause') {
            if (j.state == JobState.queued) {
              j.state = JobState.paused;
            } else if (j.state == JobState.running) {
              j.state = JobState.pausing;
              j.token.cancel('pause');
            }
          } else if (body['action'] == 'resume' &&
              [JobState.paused, JobState.failed].contains(j.state)) {
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
      _json(r, {'error': e.key, 'detail': e.detail}, status: 422);
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
