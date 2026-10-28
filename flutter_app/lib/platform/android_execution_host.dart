import 'dart:async';

import 'package:flutter/services.dart';

import '../core/download_job.dart';
import '../core/execution_host.dart';
import '../core/models.dart';
import '../l10n/strings.dart';

class AndroidExecutionHost extends ExecutionHost {
  AndroidExecutionHost({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('bili_downloader/execution') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pause') {
        final reason = call.arguments == 'backgroundExpired'
            ? 'backgroundExpired'
            : call.arguments == 'backgroundUnavailable'
            ? 'backgroundUnavailable'
            : null;
        onPause?.call(reason);
      }
    });
  }

  final MethodChannel _channel;
  Future<void> _tail = Future.value();
  Future<void>? _started;
  bool _ready = false;
  Map<String, Object>? _latest;
  bool _updating = false;

  Future<void> _serialize(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Future<void> start() => _started ??= _serialize(() async {
    try {
      final s = Strings(language);
      await _channel.invokeMethod<void>('start', {
        'title': s('downloads'),
        'text': s('backgroundWorking'),
        'pause': s('pauseAllDownloads'),
      });
      _ready = true;
    } catch (_) {
      onPause?.call('backgroundUnavailable');
      throw const AppFailure('backgroundUnavailable');
    }
  });

  @override
  void update(List<DownloadJob> jobs, {bool hasWorkers = false}) {
    final pending = jobs
        .where((j) => j.active || j.state == JobState.queued)
        .toList();
    if (pending.isEmpty && !hasWorkers) {
      unawaited(stop());
      return;
    }
    if (!_ready) return;
    final s = Strings(language);
    _latest = {
      'title': s('downloads'),
      'text':
          '${s('backgroundWorking')}${pending.isEmpty ? '' : ' · ${pending.length}'}',
      'pause': s('pauseAllDownloads'),
      // Progress is per current stage; unknown totals remain indeterminate.
      'progress':
          pending.length == 1 &&
              pending.single.total > 0 &&
              pending.single.state == JobState.running
          ? (pending.single.received * 100 ~/ pending.single.total).clamp(
              0,
              100,
            )
          : -1,
    };
    if (!_updating) unawaited(_flushUpdate());
  }

  Future<void> _flushUpdate() async {
    _updating = true;
    try {
      // At most one channel request in flight; newer progress replaces old data.
      while (_latest != null && _ready) {
        final value = _latest;
        _latest = null;
        await _channel.invokeMethod<void>('update', value);
      }
    } catch (_) {
      onPause?.call('backgroundUnavailable');
    } finally {
      _updating = false;
    }
  }

  @override
  Future<void> stop() {
    if (_started == null) return _tail;
    _started = null;
    _latest = null;
    return _serialize(() async {
      _ready = false;
      try {
        await _channel.invokeMethod<void>('stop');
      } catch (_) {
        // Android also stops a non-sticky service when its process exits.
      }
    });
  }
}
