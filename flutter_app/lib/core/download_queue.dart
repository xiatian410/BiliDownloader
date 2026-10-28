import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'download_job.dart';
import 'models.dart';

class DownloadQueue extends ChangeNotifier {
  DownloadQueue(this.runner, {this.maxConcurrent = 4});
  final DownloadRunner runner;
  final List<DownloadJob> jobs = [];
  int maxConcurrent;
  bool _closed = false;

  void add(Iterable<DownloadJob> additions) {
    jobs.addAll(additions);
    notifyListeners();
    _schedule();
  }

  void setConcurrency(int value) {
    if (value < 1 || value > 8) throw const AppFailure('invalidConcurrency');
    maxConcurrent = value;
    _schedule();
  }

  void _schedule() {
    if (_closed) return;
    var active = jobs.where((j) => j.active).length;
    final targets = jobs.where((j) => j.active).map(_target).toSet();
    for (final job in jobs.where((j) => j.state == JobState.queued).toList()) {
      if (active >= maxConcurrent) break;
      if (!targets.add(_target(job))) continue;
      active++;
      job.state = JobState.running;
      job.token = CancelToken();
      unawaited(_run(job));
    }
  }

  String _target(DownloadJob j) =>
      '${j.options.directory}/${j.options.flatDirectory ? '' : j.episode.folderName}/${j.episode.filename(limit: j.options.limitTitle)}'
          .toLowerCase();

  Future<void> _run(DownloadJob job) async {
    try {
      job.error = null;
      await runner.run(job, () {
        if (!_closed) notifyListeners();
      });
      job.state = JobState.completed;
      job.stage = 'completed';
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        job.state = _closed ? JobState.cancelled : JobState.paused;
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
      if (!_closed) {
        notifyListeners();
        _schedule();
      }
    }
  }

  void pause(DownloadJob job) {
    if (job.state == JobState.queued) {
      job.state = JobState.paused;
    } else if (job.state == JobState.running) {
      job.state = JobState.pausing;
      job.token.cancel('pause');
    }
    notifyListeners();
  }

  void resume(DownloadJob job) {
    if (![JobState.paused, JobState.failed].contains(job.state)) return;
    job.state = JobState.queued;
    job.error = null;
    notifyListeners();
    _schedule();
  }

  Future<void> clearCompleted({Iterable<DownloadJob>? only}) async {
    final ids = only?.map((j) => j.id).toSet();
    final targets = jobs
        .where(
          (j) =>
              j.state == JobState.completed &&
              (ids == null || ids.contains(j.id)),
        )
        .toList();
    if (runner is RemoteJobManagement) {
      await (runner as RemoteJobManagement).removeCompleted(targets);
    }
    jobs.removeWhere(
      (j) =>
          j.state == JobState.completed && (ids == null || ids.contains(j.id)),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    for (final job in jobs) {
      job.token.cancel('shutdown');
    }
    runner.dispose();
    super.dispose();
  }
}
