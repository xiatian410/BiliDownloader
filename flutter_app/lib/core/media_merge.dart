import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import 'models.dart';

class MergeProgress {
  const MergeProgress({this.milliseconds = 0, this.bytes = 0, this.frames = 0});
  final int milliseconds, bytes, frames;
  Map<String, int> toJson() => {
    'milliseconds': milliseconds,
    'bytes': bytes,
    'frames': frames,
  };
  factory MergeProgress.fromJson(Map data) => MergeProgress(
    milliseconds: data['milliseconds'] as int? ?? 0,
    bytes: data['bytes'] as int? ?? 0,
    frames: data['frames'] as int? ?? 0,
  );
}

typedef MergeMedia = Future<void> Function(
  List<String> arguments, {
  CancelToken? cancel,
  void Function(MergeProgress)? onProgress,
  void Function(String)? onStopping,
  Duration? idleTimeout,
});

/// Event-driven inactivity monitoring. Cancellation never releases a task until
/// its backend has reported termination, so a retry cannot race an old writer.
class MergeWatch {
  MergeWatch({
    this.cancel,
    this.onProgress,
    this.onStopping,
    Duration? idleTimeout,
  }) : idleTimeout = idleTimeout ?? const Duration(minutes: 2) {
    if (this.idleTimeout <= Duration.zero) {
      throw ArgumentError.value(idleTimeout);
    }
    _arm();
    if (cancel != null) {
      if (cancel!.isCancelled) {
        _requestStop();
      } else {
        unawaited(cancel!.whenCancel.then((_) => _requestStop()));
      }
    }
  }
  final CancelToken? cancel;
  final void Function(MergeProgress)? onProgress;
  final void Function(String)? onStopping;
  final Duration idleTimeout;
  Timer? _idle, _grace;
  bool _closed = false, _requested = false, _issued = false, _stalled = false;
  Future<void> Function()? _stop;
  MergeProgress _last = const MergeProgress();

  void _arm() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () {
      if (_closed || _requested) return;
      _stalled = true;
      _requestStop();
    });
  }

  void progress(MergeProgress progress) {
    if (_closed || _requested) return;
    if (progress.milliseconds <= _last.milliseconds &&
        progress.bytes <= _last.bytes &&
        progress.frames <= _last.frames) {
      return;
    }
    _last = MergeProgress(
      milliseconds: max(_last.milliseconds, progress.milliseconds),
      bytes: max(_last.bytes, progress.bytes),
      frames: max(_last.frames, progress.frames),
    );
    _arm();
    onProgress?.call(_last);
  }

  void attachStop(Future<void> Function() stop) {
    _stop = stop;
    if (_requested) unawaited(_issueStop());
  }

  void _requestStop() {
    if (_closed || _requested) return;
    _requested = true;
    _idle?.cancel();
    onStopping?.call(_stalled ? 'mergeStalledStopping' : 'stoppingMerge');
    if (_stop != null) unawaited(_issueStop());
  }

  Future<void> _issueStop() async {
    if (_closed || _issued) return;
    _issued = true;
    _grace = Timer(const Duration(seconds: 10), () {
      if (!_closed) onStopping?.call('mergeStopPending');
    });
    try {
      await _stop!();
    } catch (_) {
      if (!_closed) onStopping?.call('mergeStopPending');
    }
  }

  void checkExit(int? code) {
    if (_stalled) throw const AppFailure('mergeStalled');
    if (cancel?.isCancelled ?? false) throw cancel!.cancelError!;
    if (code != 0) throw const AppFailure('mergeFailed');
  }

  void close() {
    _closed = true;
    _idle?.cancel();
    _grace?.cancel();
    _stop = null;
  }
}
