import 'dart:async';

import 'package:dio/dio.dart';

import 'download_job.dart';
import 'models.dart';
import 'job_snapshot.dart';
import 'state_store.dart';
import 'task_queue.dart';
import 'execution_host.dart';

class DownloadQueue extends TaskQueue {
  DownloadQueue(this.runner, {this.maxConcurrent = 4, this.executionHost}) {
    executionHost?.onPause = (reason) {
      for (final job in jobs.where((j) => j.canPause).toList()) {
        pause(job);
        if (reason != null) job.error = AppFailure(reason);
      }
      if (!_closed) notifyListeners();
    };
  }
  final DownloadRunner runner;
  final ExecutionHost? executionHost;

  @override
  void setLanguage(String language) {
    executionHost?.language = language;
    _updateExecutionHost();
  }

  @override
  void notifyListeners() {
    _updateExecutionHost();
    super.notifyListeners();
  }

  void _updateExecutionHost() {
    executionHost?.update(
      persistenceError == null ? jobs : jobs.where((j) => j.active).toList(),
      hasWorkers: _running.isNotEmpty,
    );
  }

  @override
  final List<DownloadJob> jobs = [];
  @override
  int maxConcurrent;
  bool _closed = false;
  StateStore? _store;
  bool _historyReady = false;
  @override
  AppFailure? persistenceError;
  @override
  bool recoveredHistory = false;
  final _running = <Future<void>>{};
  Future<void>? _closing;
  Future<void> _persistenceTail = Future.value();

  Future<void> _transaction(Future<void> Function() action) {
    final next = _persistenceTail.then((_) => action());
    _persistenceTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  @override
  Future<void> restore(StateStore store) async {
    if (_closed) {
      await store.close();
      return;
    }
    _store = store;
    try {
      final snapshot = await store.read();
      if (snapshot.data.isNotEmpty && snapshot.data['version'] != 1) {
        throw const AppFailure('historyCorrupt');
      }
      final restored = (snapshot.data['jobs'] as List? ?? [])
          .map((m) => restoreJob(Map<String, dynamic>.from(m)))
          .toList();
      if (restored.map((j) => j.id).toSet().length != restored.length) {
        throw const AppFailure('historyCorrupt');
      }
      if (_closed) {
        await store.close();
        return;
      }
      recoveredHistory = snapshot.recovered;
      jobs.addAll(restored);
      for (final job in restored) {
        job.onCheckpoint = _checkpoint;
      }
      _historyReady = true;
      notifyListeners();
    } catch (e) {
      persistenceError = e is AppFailure
          ? e
          : const AppFailure('historyCorrupt');
      rethrow;
    }
  }

  Future<void> _checkpoint() => _transaction(_writeCurrent);
  Future<void> _writeCurrent() async {
    if (_store == null) return;
    if (!_historyReady) {
      throw persistenceError ?? const AppFailure('historyNotReady');
    }
    try {
      await _store!.write({
        'version': 1,
        'jobs': jobs.map(jobSnapshot).toList(),
      });
      persistenceError = null;
    } catch (e) {
      persistenceError = e is AppFailure
          ? e
          : const AppFailure('historyWriteFailed');
      rethrow;
    }
  }

  @override
  Future<void> add(Iterable<DownloadJob> additions) async {
    if (_closed) return;
    final added = additions.toList();
    for (final job in added) {
      job.onCheckpoint = _checkpoint;
    }
    jobs.addAll(added);
    if (_store != null && added.isNotEmpty) {
      unawaited(_saveControl(added.first));
    }
    notifyListeners();
    _schedule();
  }

  @override
  Future<void> setConcurrency(int value) async {
    if (value < 1 || value > 8) throw const AppFailure('invalidConcurrency');
    maxConcurrent = value;
    _schedule();
  }

  void _schedule() {
    if (_closed || persistenceError != null) return;
    var active = jobs.where((j) => j.active).length;
    final targets = jobs.where((j) => j.active).map(_target).toSet();
    for (final job in jobs.where((j) => j.state == JobState.queued).toList()) {
      if (active >= maxConcurrent) break;
      if (!targets.add(_target(job))) continue;
      active++;
      job.state = JobState.running;
      job.token = CancelToken();
      final future = _run(job);
      _running.add(future);
      unawaited(
        future.whenComplete(() {
          _running.remove(future);
          if (!_closed) _updateExecutionHost();
        }),
      );
    }
  }

  String _target(DownloadJob j) =>
      '${j.options.directory}/${j.options.flatDirectory ? '' : j.episode.folderName}/${j.episode.filename(limit: j.options.limitTitle)}'
          .toLowerCase();

  Future<void> _run(DownloadJob job) async {
    try {
      job.error = null;
      if (executionHost != null) await executionHost!.start();
      if (_store != null) await _checkpoint();
      if (job.token.isCancelled) throw job.token.cancelError!;
      await runner.run(job, () {
        if (!_closed) notifyListeners();
      });
      job.state = JobState.completed;
      job.stage = 'completed';
      if (_store != null) await _checkpoint();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        job.state = JobState.paused;
        job.stage = 'paused';
      } else {
        job.state = JobState.failed;
        job.error = AppFailure(
          'networkError',
          e.response?.statusCode?.toString() ?? e.type.name,
        );
      }
    } catch (e) {
      job.state = JobState.failed;
      job.error = e is AppFailure
          ? e
          : AppFailure('downloadFailed', e.toString());
    } finally {
      if (_store != null && persistenceError == null) {
        try {
          await _checkpoint();
        } catch (_) {
          job.state = JobState.failed;
          job.error = persistenceError;
        }
      }
      if (!_closed) {
        notifyListeners();
        _schedule();
      }
    }
  }

  @override
  void pause(DownloadJob job) {
    if (job.state == JobState.queued) {
      job.state = JobState.paused;
    } else if ([JobState.running, JobState.merging].contains(job.state)) {
      job.state = JobState.pausing;
      job.stage = 'pausing';
      job.token.cancel('pause');
    }
    if (_store != null && job.state == JobState.paused) {
      unawaited(_saveControl(job));
    }
    notifyListeners();
  }

  Future<void> _saveControl(DownloadJob job) async {
    try {
      await _checkpoint();
    } catch (_) {
      job.error = persistenceError;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void resume(DownloadJob job) {
    if (_closed) return;
    if (!job.canResume) return;
    if (persistenceError != null) {
      unawaited(_recoverPersistence(job));
      return;
    }
    job.state = JobState.queued;
    job.error = null;
    notifyListeners();
    _schedule();
  }

  Future<void> _recoverPersistence(DownloadJob job) async {
    try {
      await _checkpoint();
      resume(job);
    } catch (_) {
      job.error = persistenceError;
      if (!_closed) notifyListeners();
    }
  }

  @override
  Future<void> clearCompleted({Iterable<DownloadJob>? only}) async {
    final ids = only?.map((j) => j.id).toSet();
    final targets = jobs
        .where(
          (j) =>
              j.state == JobState.completed &&
              (ids == null || ids.contains(j.id)),
        )
        .toList();
    if (_store != null) {
      await _transaction(() async {
        final previous = List.of(jobs);
        jobs.removeWhere(targets.contains);
        try {
          await _writeCurrent();
        } catch (_) {
          for (final (index, job) in previous.indexed) {
            if (targets.contains(job)) {
              jobs.insert(index.clamp(0, jobs.length), job);
            }
          }
          rethrow;
        }
      });
    } else {
      jobs.removeWhere(targets.contains);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    for (final job in jobs) {
      job.token.cancel('shutdown');
    }
    await Future.wait(_running.toList());
    await _persistenceTail;
    executionHost?.onPause = null;
    await executionHost?.stop();
    runner.dispose();
    await _store?.close();
  }
}
