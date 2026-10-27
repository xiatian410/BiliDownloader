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
  AppController({required this.api, required this.queue, required this.store});
  final BiliApi api;
  final DownloadQueue queue;
  final AppStore store;
  static const storageTimeout = Duration(seconds: 5);
  AppSettings settings = AppSettings();
  bool initializing = true;
  AppFailure? error;
  String? notice;
  bool busy = false;
  int tab = 0, step = 0;
  VideoInfo? info;
  PlayableMedia? media;
  Set<int> selected = {};
  final Map<int, bool> audioOnlyOverrides = {};
  final Map<int, bool> danmakuOverrides = {};
  int quality = 80;
  String specialAudio = '', audioLanguage = '';
  CancelToken? _request;
  bool _disposed = false;
  bool get loggedIn => api.cookies.isNotEmpty;

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
    _notify();
  }

  void selectAll() {
    selected = {for (var i = 0; i < (info?.episodes.length ?? 0); i++) i};
    _notify();
  }

  void invertSelection() {
    selected = {
      for (var i = 0; i < (info?.episodes.length ?? 0); i++)
        if (!selected.contains(i)) i,
    };
    _notify();
  }

  void selectionText(String input) {
    try {
      selected = parseSelection(input, info!.episodes.length);
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
  );

  Future<void> resolve(String input) async {
    final id = VideoId.parse(input);
    if (id == null || busy) return;
    await perform(() async {
      _request = CancelToken();
      info = await api.resolve(id, cancel: _request);
      selected = {for (var i = 0; i < info!.episodes.length; i++) i};
      audioOnlyOverrides.clear();
      danmakuOverrides.clear();
      media = null;
      specialAudio = '';
      audioLanguage = '';
      step = 1;
    });
  }

  Future<void> loadOptions() async {
    if (selected.isEmpty) return;
    await perform(() async {
      _request = CancelToken();
      media = await api.play(
        info!.episodes[(selected.toList()..sort()).first],
        options(),
        cancel: _request,
      );
      if (media!.qualities.isEmpty) throw const AppFailure('noStreams');
      quality = media!.qualities.first.id;
      step = 3;
    });
  }

  void enqueue() {
    if (kIsWeb) {
      fail(const AppFailure('webDownloadUnsupported'));
      return;
    }
    if (settings.directory.isEmpty || selected.isEmpty) {
      fail(const AppFailure('invalidDirectory'));
      return;
    }
    final indices = selected.toList()..sort();
    queue.add(indices.map((i) => DownloadJob(info!.episodes[i], options(i))));
    tab = 1;
    step = 0;
    info = null;
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
