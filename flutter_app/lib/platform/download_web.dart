import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/bili_api.dart';
import '../core/download_job.dart';
import '../core/attachments.dart';
import '../core/media_merge.dart';
import '../core/models.dart';
import '../core/remote_api.dart';
import '../core/task_queue.dart';
import '../core/wire.dart';

RemoteDownloadQueue createDownloadQueue(BiliApi api) =>
    RemoteDownloadQueue(api as RemoteBiliApi);

/// A view of the service-owned queue. One connection observes every task,
/// including work that has not started. Closing this view never pauses work.
class RemoteDownloadQueue extends TaskQueue {
  RemoteDownloadQueue(this.api, {WebSocketChannel Function(Uri)? connect})
    : connect = connect ?? WebSocketChannel.connect;
  final RemoteBiliApi api;
  final WebSocketChannel Function(Uri) connect;
  @override
  final jobs = <DownloadJob>[];
  @override
  int maxConcurrent = 4;
  @override
  int get maxSupportedConcurrent => 4;
  @override
  bool get isRemote => true;
  @override
  bool get connected => _ready && !_closed;
  @override
  AppFailure? connectionError;
  @override
  bool get recoveredHistory => api.recoveredHistory;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _connecting, _closing;
  Completer<void>? _opening;
  bool _closed = false, _ready = false;
  int _generation = 0;
  int _settingsRevision = 0;
  String? _workspaceId;
  Future<void> _settingsTail = Future.value();
  final _removed = <String>{};

  void _notify() {
    if (!_closed) notifyListeners();
  }

  AppFailure _failure(Object error) =>
      error is AppFailure ? error : const AppFailure('serviceDisconnected');

  DownloadJob? _find(Map<String, dynamic> data) {
    for (final job in jobs) {
      if (job.remoteId == data['id'] ||
          (data['requestId'] != null && job.id == data['requestId'])) {
        return job;
      }
    }
    return null;
  }

  void _apply(Map<String, dynamic> data, {bool authoritative = false}) {
    final id = data['id'] as String;
    if (_removed.contains(id)) return;
    var job = _find(data);
    final revision = data['revision'] as int;
    if (job != null && !authoritative && revision < job.revision) return;
    if (job == null) {
      job = DownloadJob(
        episodeFromJson(Map<String, dynamic>.from(data['episode'])),
        optionsFromJson(
          Map<String, dynamic>.from(data['options']),
          directory: '',
        ),
        id: data['requestId'] as String? ?? id,
      );
      jobs.add(job);
    }
    job.remoteId = id;
    job.revision = revision;
    job.state = JobState.values.byName(data['state'] as String);
    job.stage = data['stage'] as String;
    job.received = data['received'] as int;
    job.total = data['total'] as int;
    job.actualQuality = data['actualQuality'] as int?;
    job.detail = data['detail'] as String? ?? '';
    job.mergeProgress = data['merge'] is Map
        ? MergeProgress.fromJson(data['merge'] as Map)
        : null;
    final error = data['error'] as Map?;
    job.error = error == null
        ? null
        : AppFailure(error['key'] as String, error['detail'] as String? ?? '');
    job.outputs
      ..clear()
      ..addAll(
        (data['outputs'] as List).map(
          (file) => api.origin.resolve(file['url'] as String).toString(),
        ),
      );
    job.outputNames
      ..clear()
      ..addAll(
        (data['outputs'] as List).map((file) => file['name'] as String? ?? ''),
      );
    job.attachments
      ..clear()
      ..addAll(
        (data['attachments'] as Map? ?? {}).map(
          (key, value) =>
              MapEntry(key as String, AttachmentResult.fromJson(value as Map)),
        ),
      );
  }

  void _snapshot(List<dynamic> data) {
    final ids = data.map((j) => j['id'] as String).toSet();
    jobs.removeWhere((j) => j.remoteId != null && !ids.contains(j.remoteId));
    _removed.removeAll(ids);
    for (final raw in data) {
      _apply(Map<String, dynamic>.from(raw), authoritative: true);
    }
  }

  void _settings(Map<String, dynamic> data, {bool authoritative = false}) {
    final revision = data['revision'] as int? ?? 0;
    if (!authoritative && revision < _settingsRevision) return;
    _settingsRevision = revision;
    maxConcurrent = data['concurrency'] as int;
  }

  @override
  Future<void> reconnect({bool force = false}) {
    if (_closed || (!force && connected)) return Future.value();
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    await _subscription?.cancel();
    await _channel?.sink.close();
    if (_closed || generation != _generation) return;
    _subscription = null;
    _channel = null;
    _ready = false;
    connectionError = null;
    if (_workspaceId != null &&
        api.workspaceId != null &&
        _workspaceId != api.workspaceId) {
      jobs.clear();
      _removed.clear();
    }
    _notify();
    final initial = _opening = Completer<void>();
    unawaited(
      initial.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    void disconnected(Object error) {
      if (_closed || generation != _generation) return;
      _ready = false;
      connectionError = _failure(error);
      if (!initial.isCompleted) initial.completeError(connectionError!);
      _notify();
    }

    try {
      await api.initializeSession();
      if (_closed || generation != _generation) return;
      if (_workspaceId != null && _workspaceId != api.workspaceId) {
        jobs.clear();
        _removed.clear();
      }
      _workspaceId = api.workspaceId;
      _snapshot(api.restoredJobs);
      maxConcurrent = api.serverConcurrency;
      _settingsRevision = api.serverSettingsRevision;
      final channel = _channel = connect(
        api.origin
            .resolve('/api/events')
            .replace(scheme: api.origin.scheme == 'https' ? 'wss' : 'ws'),
      );
      _subscription = channel.stream.listen(
        (raw) {
          if (_closed || generation != _generation) return;
          try {
            final data = Map<String, dynamic>.from(jsonDecode(raw as String));
            switch (data['type']) {
              case 'snapshot':
                _snapshot(data['jobs'] as List);
                _settings({
                  'concurrency': data['concurrency'],
                  'revision': data['settingsRevision'],
                }, authoritative: true);
                _ready = true;
                connectionError = null;
                if (!initial.isCompleted) initial.complete();
              case 'removed':
                final ids = List<String>.from(data['ids']);
                _removed.addAll(ids);
                jobs.removeWhere((j) => ids.contains(j.remoteId));
              case 'settings':
                _settings(data);
              default:
                _apply(data);
            }
            _notify();
          } catch (error) {
            disconnected(const AppFailure('invalidResponse'));
            unawaited(channel.sink.close());
          }
        },
        onError: disconnected,
        onDone: () {
          if (_closed || generation != _generation) return;
          if (channel.closeCode == 4001) {
            api.requireServiceAccess();
            disconnected(const AppFailure('serviceAccessRequired'));
          } else {
            disconnected(const AppFailure('serviceDisconnected'));
          }
        },
      );
      await Future.wait([
        channel.ready,
        initial.future,
      ], eagerError: true).timeout(const Duration(seconds: 10));
    } catch (error) {
      if (_closed || generation != _generation) return;
      disconnected(error);
      await _subscription?.cancel();
      await _channel?.sink.close();
      rethrow;
    } finally {
      if (identical(_opening, initial)) _opening = null;
    }
  }

  @override
  Future<void> add(Iterable<DownloadJob> additions) async {
    if (_closed) return;
    await reconnect();
    if (_closed) return;
    final batch = additions.toList();
    if (batch.isEmpty) return;
    if (batch.length > 200) throw const AppFailure('serviceBusy');
    for (final job in batch) {
      job.state = JobState.submitting;
      job.stage = 'submitting';
      jobs.add(job);
    }
    _notify();
    await _submit(batch);
  }

  Future<void> _submit(List<DownloadJob> batch) async {
    try {
      final response = await api.call('/api/jobs/batch', {
        'jobs': [
          for (final job in batch)
            {
              'requestId': job.id,
              'episode': job.episode.identity,
              'options': optionsToJson(job.options),
            },
        ],
      });
      if (_closed) return;
      for (final raw in response['jobs'] as List) {
        _apply(Map<String, dynamic>.from(raw));
      }
    } catch (error) {
      if (_closed) return;
      // An event can confirm receipt even if the HTTP response is lost.
      for (final job in batch.where((j) => j.remoteId == null)) {
        job.state = JobState.failed;
        job.stage = 'failed';
        job.error = _failure(error);
      }
    }
    _notify();
  }

  Future<void> _control(DownloadJob job, String action) async {
    if (_closed || job.controlPending) return;
    job.controlPending = true;
    _notify();
    try {
      await reconnect();
      if (_closed) return;
      if (job.remoteId == null) {
        job.state = JobState.submitting;
        job.error = null;
        await _submit([job]);
      } else {
        final response = await api.call('/api/jobs/control', {
          'id': job.remoteId,
          'action': action,
        });
        if (!_closed) _apply(response);
      }
    } catch (error) {
      if (!_closed) job.error = _failure(error);
    } finally {
      job.controlPending = false;
      _notify();
    }
  }

  @override
  void pause(DownloadJob job) {
    if (job.canPause && job.remoteId != null) unawaited(_control(job, 'pause'));
  }

  @override
  void resume(DownloadJob job) {
    if (job.canResume) {
      unawaited(_control(job, 'resume'));
    }
  }

  @override
  Future<void> setConcurrency(int value) async {
    if (value < 1 || value > maxSupportedConcurrent) {
      throw const AppFailure('invalidConcurrency');
    }
    final next = _settingsTail.then((_) async {
      if (_closed) return;
      await reconnect();
      if (_closed || value == maxConcurrent) return;
      final response = await api.call('/api/settings', {'concurrency': value});
      if (_closed) return;
      _settings(response);
      _notify();
    });
    _settingsTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await next;
  }

  @override
  Future<void> clearCompleted({Iterable<DownloadJob>? only}) async {
    await reconnect();
    if (_closed) return;
    final targets = (only ?? jobs)
        .where((j) => j.state == JobState.completed)
        .toList();
    final ids = targets.map((j) => j.remoteId).whereType<String>().toList();
    await api.call('/api/jobs/remove', {'ids': ids});
    if (_closed) return;
    _removed.addAll(ids);
    jobs.removeWhere((j) => ids.contains(j.remoteId));
    _notify();
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _ready = false;
    _generation++;
    final opening = _opening;
    if (opening != null && !opening.isCompleted) {
      opening.completeError(StateError('Queue closed'));
    }
    await _subscription?.cancel();
    await _channel?.sink.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
