import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/download_queue.dart';
import 'package:bili_downloader/core/models.dart';

class PendingRunner implements DownloadRunner {
  final started = <DownloadJob>[];
  final pending = <DownloadJob, Completer<void>>{};
  @override
  Future<void> run(DownloadJob job, void Function() changed) async {
    started.add(job);
    final done = pending[job] = Completer<void>();
    await Future.any([
      done.future,
      job.token.whenCancel.then<void>((e) => throw e),
    ]);
  }

  @override
  void dispose() {}
}

DownloadJob job(int n) => DownloadJob(
  Episode(cid: n, number: n, name: '$n', title: 'test'),
  const DownloadOptions(directory: '/tmp', quality: 80),
);

void main() {
  test(
    'queue respects concurrency and schedules completion without polling',
    () async {
      final runner = PendingRunner();
      final queue = DownloadQueue(runner, maxConcurrent: 2);
      addTearDown(queue.dispose);
      final jobs = [job(1), job(2), job(3)];
      queue.add(jobs);
      expect(runner.started.length, 2);
      runner.pending[jobs[0]]!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(jobs[0].state, JobState.completed);
      expect(runner.started.length, 3);
    },
  );
  test('pause cancels in-flight work and resume starts exactly once', () async {
    final runner = PendingRunner();
    final queue = DownloadQueue(runner, maxConcurrent: 1);
    addTearDown(queue.dispose);
    final j = job(1);
    queue.add([j]);
    queue.pause(j);
    await Future<void>.delayed(Duration.zero);
    expect(j.state, JobState.paused);
    queue.resume(j);
    queue.resume(j);
    expect(runner.started.length, 2);
    expect(j.state, JobState.running);
  });
  test('duplicate output targets are serialized', () async {
    final runner = PendingRunner();
    final queue = DownloadQueue(runner, maxConcurrent: 4);
    addTearDown(queue.dispose);
    queue.add([job(1), job(1)]);
    expect(runner.started.length, 1);
  });
  test('merging cannot be paused or accidentally resumed', () {
    final runner = PendingRunner();
    final queue = DownloadQueue(runner);
    addTearDown(queue.dispose);
    final j = job(1);
    queue.add([j]);
    j.state = JobState.merging;
    queue.pause(j);
    queue.resume(j);
    expect(j.state, JobState.merging);
    expect(j.token.isCancelled, false);
  });
}
