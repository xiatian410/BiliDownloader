import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/bili_api.dart';
import 'core/task_queue.dart';
import 'core/download_job.dart';
import 'core/models.dart';
import 'core/settings.dart';
import 'core/state_store.dart';
import 'core/service_access.dart';
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
  }) {
    _accessSubscription = serviceAccess?.accessChanges.listen((_) => _notify());
  }
  final BiliApi api;
  final TaskQueue queue;
  final AppStore store;
  final Future<StateStore?> Function()? openHistory;
  StreamSubscription<void>? _accessSubscription;
  ServiceAccess? get serviceAccess =>
      api is ServiceAccess ? api as ServiceAccess : null;
  static const storageTimeout = Duration(seconds: 5);
  AppSettings settings = AppSettings();
  bool initializing = true;
  AppFailure? error;
  String? notice;
  bool busy = false;
  bool connectingService = false;
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

  Future<void> connectService(String key, {bool newWorkspace = false}) =>
      perform(() async {
        connectingService = true;
        _notify();
        final access = serviceAccess!;
        final previousWorkspace = access.workspaceId;
        try {
          await access.unlockService(key, newWorkspace: newWorkspace);
          if (previousWorkspace != null &&
              previousWorkspace != access.workspaceId) {
            info = null;
            sources.clear();
            selected.clear();
            resolveErrors.clear();
            media = null;
            tab = 0;
          }
          await queue.reconnect(force: true);
          settings.concurrency = queue.maxConcurrent;
          await _rememberWorkspace();
        } finally {
          connectingService = false;
        }
      });

  Future<void> lockService() => perform(() => serviceAccess!.lockService());

  Future<void> _rememberWorkspace() async {
    final id = serviceAccess?.workspaceId;
    if (id == null || id == settings.serviceWorkspace) return;
    settings.serviceWorkspace = id;
    try {
      await store.writeSettings(settings.toJson()).timeout(storageTimeout);
    } catch (_) {
      throw const AppFailure('settingsError');
    }
  }

  Future<void> initialize() async {
    try {
      settings = AppSettings.fromJson(
        await store.readSettings().timeout(storageTimeout),
      );
      serviceAccess?.rememberWorkspace(
        settings.serviceWorkspace.isEmpty ? null : settings.serviceWorkspace,
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
      if (queue.isRemote) {
        await queue.reconnect();
        settings.concurrency = queue.maxConcurrent;
        if (queue.recoveredHistory) notice = 'historyRecovered';
        await _rememberWorkspace();
      } else {
        await api.initializeSession();
      }
    } catch (e) {
      error = e is AppFailure ? e : const AppFailure('serviceUnavailable');
    }
    if (_disposed) return;
    if (!queue.isRemote) await queue.setConcurrency(settings.concurrency);
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
    autoCover: settings.autoCover,
    nfo: settings.nfo,
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
    final image = await api.fetchCover(info!.cover);
    await platform.saveBytes(
      image.bytes,
      '${safeFilename(info!.title)}.${image.extension}',
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

  Future<void> enqueue() async {
    if ((!kIsWeb && settings.directory.isEmpty) || selected.isEmpty) {
      fail(const AppFailure('invalidDirectory'));
      return;
    }
    await perform(() async {
      final indices = selected.toList()..sort();
      final jobs = indices
          .map((i) => DownloadJob(info!.episodes[i], options(i)))
          .toList();
      await queue.add(jobs);
      tab = 1;
      step = 0;
      info = null;
      sources.clear();
      resolveErrors.clear();
      media = null;
      selected = {};
      notice = null;
    });
  }

  Future<void> saveSettings({bool updateConcurrency = false}) async {
    _notify();
    try {
      if (updateConcurrency) await queue.setConcurrency(settings.concurrency);
      settings.concurrency = queue.maxConcurrent;
      await store.writeSettings(settings.toJson()).timeout(storageTimeout);
    } catch (e) {
      settings.concurrency = queue.maxConcurrent;
      fail(e is AppFailure ? e : const AppFailure('settingsError'));
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
    unawaited(_accessSubscription?.cancel());
    _request?.cancel();
    api.close();
    queue.dispose();
    super.dispose();
  }
}
