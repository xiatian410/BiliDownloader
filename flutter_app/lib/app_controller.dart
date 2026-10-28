import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/bili_api.dart';
import 'core/download_queue.dart';
import 'core/download_job.dart';
import 'core/models.dart';
import 'core/settings.dart';
import 'core/remote_api.dart';
import 'core/wire.dart';
import 'core/state_store.dart';
import 'platform/platform.dart' as platform;

abstract class AppStore {
  Future<Map<String, dynamic>> readSettings();
  Future<void> writeSettings(Map<String, dynamic> data);
  Future<Map<String, String>> readCookies();
  Future<void> writeCookies(Map<String, String> cookies);
}

class LocalAppStore implements AppStore {
  final _secure = const FlutterSecureStorage();
  @override
  Future<Map<String, dynamic>> readSettings() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'settings.v2',
    );
    return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw));
  }

  @override
  Future<void> writeSettings(Map<String, dynamic> data) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      'settings.v2',
      jsonEncode(data),
    )) {
      throw const AppFailure('settingsError');
    }
  }

  @override
  Future<Map<String, String>> readCookies() async {
    if (kIsWeb) return {};
    final raw = platform.isLinux
        ? await platform.readLinuxCredentials()
        : await _secure.read(key: 'bilibili.cookies.v2');
    return raw == null ? {} : Map<String, String>.from(jsonDecode(raw));
  }

  @override
  Future<void> writeCookies(Map<String, String> cookies) async {
    if (kIsWeb) return;
    if (platform.isLinux) {
      await platform.writeLinuxCredentials(
        cookies.isEmpty ? null : jsonEncode(cookies),
      );
      return;
    }
    if (cookies.isEmpty) {
      await _secure.delete(key: 'bilibili.cookies.v2');
    } else {
      await _secure.write(
        key: 'bilibili.cookies.v2',
        value: jsonEncode(cookies),
      );
    }
  }
}

class AppController extends ChangeNotifier {
  AppController({
    required this.api,
    required this.queue,
    required this.store,
    this.openHistory,
  });
  final BiliApi api;
  final DownloadQueue queue;
  final AppStore store;
  final Future<StateStore?> Function()? openHistory;
  static const storageTimeout = Duration(seconds: 5);
  AppSettings settings = AppSettings();
  bool initializing = true;
  AppFailure? error;
  String? notice;
  bool busy = false;
  int tab = 0, step = 0;
  VideoInfo? info;
  final List<VideoInfo> sources = [];
  final Map<String, AppFailure> resolveErrors = {};
  int resolvedCount = 0, resolveTotal = 0;
  PlayableMedia? media;
  Set<int> selected = {};
  final Map<int, bool> audioOnlyOverrides = {};
  final Map<int, bool> danmakuOverrides = {};
  int quality = 80;
  String specialAudio = '', audioLanguage = '';
  CancelToken? _request;
  bool _disposed = false;
  bool get loggedIn => api.authenticated;

  Future<void> initialize() async {
    try {
      settings = AppSettings.fromJson(
        await store.readSettings().timeout(storageTimeout),
      );
      if (!kIsWeb && settings.directory.isEmpty) {
        settings.directory = await platform.defaultDirectory().timeout(
          storageTimeout,
        );
      }
    } catch (_) {
      error = const AppFailure('settingsError');
    }
    try {
      final cookies = await store.readCookies().timeout(storageTimeout);
      if (!_disposed) api.cookies = cookies;
    } catch (_) {
      notice = 'secureStorageError';
    }
    if (_disposed) return;
    try {
      final history = await openHistory?.call();
      if (history != null) {
        await queue.restore(history);
        if (queue.recoveredHistory) notice = 'historyRecovered';
      }
    } catch (e) {
      error = e is AppFailure ? e : const AppFailure('historyCorrupt');
    }
    if (_disposed) return;
    try {
      await api.initializeSession();
      if (api is RemoteBiliApi) {
        final remote = api as RemoteBiliApi;
        if (remote.recoveredHistory) notice = 'historyRecovered';
        queue.add(
          remote.restoredJobs.map((raw) {
            final data = Map<String, dynamic>.from(raw);
            final job = DownloadJob(
              episodeFromJson(Map<String, dynamic>.from(data['episode'])),
              optionsFromJson(
                Map<String, dynamic>.from(data['options']),
                directory: '',
              ),
            );
            job.remoteId = data['id'] as String;
            job.received = data['received'] as int;
            job.total = data['total'] as int;
            job.actualQuality = data['actualQuality'] as int?;
            job.detail = data['detail'] as String? ?? '';
            if (data['error'] is Map) {
              job.error = AppFailure(
                data['error']['key'] as String,
                data['error']['detail'] as String? ?? '',
              );
            }
            if (['completed', 'paused', 'failed'].contains(data['state'])) {
              job.state = JobState.values.byName(data['state'] as String);
            }
            job.outputs.addAll(
              (data['outputs'] as List).map(
                (f) => remote.origin.resolve(f['url'] as String).toString(),
              ),
            );
            return job;
          }),
        );
      }
    } catch (e) {
      error = e is AppFailure ? e : const AppFailure('serviceUnavailable');
    }
    if (_disposed) return;
    queue.setConcurrency(settings.concurrency);
    initializing = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setTab(int value) {
    tab = value;
    _notify();
  }

  void back() {
    if (step > 0 && !busy) step--;
    error = null;
    _notify();
  }

  void changeSelection(int index, bool checked) {
    checked ? selected.add(index) : selected.remove(index);
    media = null;
    _notify();
  }

  void selectAll() {
    selected = {for (var i = 0; i < (info?.episodes.length ?? 0); i++) i};
    media = null;
    _notify();
  }

  void invertSelection() {
    media = null;
    selected = {
      for (var i = 0; i < (info?.episodes.length ?? 0); i++)
        if (!selected.contains(i)) i,
    };
    _notify();
  }

  void selectionText(String input) {
    try {
      selected = parseSelection(input, info!.episodes.length);
      media = null;
      error = null;
    } catch (e) {
      fail(e);
    }
    _notify();
  }

  void nextFromDetails() {
    step = 2;
    _notify();
  }

  DownloadOptions options([int? episodeIndex]) => DownloadOptions(
    directory: settings.directory,
    quality: quality,
    codec: settings.codec,
    onlyAudio: audioOnlyOverrides[episodeIndex] ?? settings.onlyAudio,
    reserveAudio: settings.reserveAudio,
    danmaku: danmakuOverrides[episodeIndex] ?? settings.danmaku,
    specialAudio: specialAudio,
    language: audioLanguage,
    ultra: settings.ultra,
    dolby: settings.dolby,
    limitTitle: settings.limitTitle,
    flatDirectory: settings.flatDirectory,
    onlyDanmaku: settings.onlyDanmaku,
  );

  Future<void> resolve(String input) async {
    final batch = VideoId.parseMany(input);
    if (busy) return;
    if (batch.ids.isEmpty || batch.ids.length > 100) {
      fail(const AppFailure('invalidBatch'));
      return;
    }
    await perform(() async {
      _request = CancelToken();
      sources.clear();
      resolveErrors.clear();
      info = null;
      selected.clear();
      resolvedCount = 0;
      resolveTotal = batch.ids.length;
      audioOnlyOverrides.clear();
      danmakuOverrides.clear();
      media = null;
      specialAudio = '';
      audioLanguage = '';
      for (final id in batch.ids) {
        if (_request!.isCancelled) break;
        try {
          sources.add(await api.resolve(id, cancel: _request));
        } catch (e) {
          if (e is DioException && CancelToken.isCancel(e)) break;
          resolveErrors[id.label] = e is AppFailure
              ? e
              : const AppFailure('invalidResponse');
        }
        resolvedCount++;
        _notify();
      }
      final episodes = <String, Episode>{};
      for (final source in sources) {
        for (final episode in source.episodes) {
          episodes.putIfAbsent(episode.identity, () => episode);
        }
      }
      if (episodes.isNotEmpty) {
        final first = sources.first;
        info = VideoInfo(
          title: first.title,
          description: first.description,
          cover: first.cover,
          author: first.author,
          id: first.id,
          episodes: episodes.values.toList(),
        );
        selected = {for (var i = 0; i < info!.episodes.length; i++) i};
      }
      step = 1;
    });
  }

  void cancelResolve() => _request?.cancel('user');

  Future<void> saveCover() => perform(() async {
    if (info == null || info!.cover.isEmpty) return;
    final response = await api.dio.get<List<int>>(
      info!.cover,
      options: Options(responseType: ResponseType.bytes, headers: biliHeaders),
    );
    final type = response.headers.value('content-type')?.split(';').first;
    final extension = const {
      'image/jpeg': 'jpg',
      'image/png': 'png',
      'image/webp': 'webp',
      'image/avif': 'avif',
    }[type];
    if (extension == null || response.data == null) {
      throw const AppFailure('invalidResponse');
    }
    await platform.saveBytes(
      Uint8List.fromList(response.data!),
      '${safeFilename(info!.title)}.$extension',
      settings.directory,
    );
    notice = 'saved';
  });

  Future<void> loadOptions() async {
    if (selected.isEmpty) return;
    await perform(() async {
      _request = CancelToken();
      media = await api.play(
        info!.episodes[(selected.toList()..sort()).first],
        options(),
        cancel: _request,
      );
      if (!settings.onlyAudio && media!.availableQualities.isEmpty) {
        throw const AppFailure('noStreams');
      }
      if (media!.availableQualities.isNotEmpty) {
        quality = media!.availableQualities.first.id;
      }
      step = 3;
    });
  }

  void enqueue() {
    if ((!kIsWeb && settings.directory.isEmpty) || selected.isEmpty) {
      fail(const AppFailure('invalidDirectory'));
      return;
    }
    final indices = selected.toList()..sort();
    queue.add(indices.map((i) => DownloadJob(info!.episodes[i], options(i))));
    tab = 1;
    step = 0;
    info = null;
    sources.clear();
    resolveErrors.clear();
    media = null;
    selected = {};
    notice = null;
    _notify();
  }

  Future<void> saveSettings() async {
    queue.setConcurrency(settings.concurrency);
    _notify();
    try {
      await store.writeSettings(settings.toJson()).timeout(storageTimeout);
    } catch (_) {
      fail(const AppFailure('settingsError'));
    }
  }

  Future<void> acceptLogin(Map<String, String> cookies) async {
    api.cookies = cookies;
    try {
      await store.writeCookies(cookies).timeout(storageTimeout);
      notice = null;
    } catch (_) {
      notice = 'secureStorageError';
    }
    _notify();
  }

  Future<void> logout() async => perform(() async {
    await api.logout();
    await store.writeCookies({}).timeout(storageTimeout);
  });
  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
    } catch (e) {
      if (e is! DioException || !CancelToken.isCancel(e)) fail(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  void fail(Object e) {
    error = e is AppFailure ? e : AppFailure('unknownError', e.toString());
    _notify();
  }

  void clearError() {
    error = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _request?.cancel();
    api.close();
    queue.dispose();
    super.dispose();
  }
}
