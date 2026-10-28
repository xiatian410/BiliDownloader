import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/download_queue.dart';
import 'package:bili_downloader/core/file_state_store.dart';
import 'package:bili_downloader/core/job_snapshot.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/core/state_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:bili_downloader/platform/platform_native.dart' as platform;

class MemoryStore implements StateStore {
  Map<String, dynamic> data = {};
  Future<void> Function()? beforeWrite;
  @override
  Future<StateSnapshot> read() async => StateSnapshot(data);
  @override
  Future<void> write(Map<String, dynamic> next) async {
    await beforeWrite?.call();
    data = Map<String, dynamic>.from(jsonDecode(jsonEncode(next)));
  }

  @override
  Future<void> close() async {}
}

class ControlledRunner implements DownloadRunner {
  final started = Completer<DownloadJob>();
  int starts = 0;
  @override
  Future<void> run(DownloadJob job, void Function() changed) async {
    starts++;
    if (!started.isCompleted) started.complete(job);
    throw await job.token.whenCancel;
  }

  @override
  void dispose() {}
}

DownloadJob sampleJob(int id) => DownloadJob(
  Episode(cid: id, number: id, name: 'Part $id', title: 'Video'),
  const DownloadOptions(directory: '/saved/path', quality: 80, onlyAudio: true),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bili-state-');
    path = '${directory.path}/queue';
  });
  tearDown(() => directory.delete(recursive: true));

  for (final failWrite in [false, true]) {
    test(
      'manual SAF export retains source until history commit (failure=$failWrite)',
      () async {
        const channel = MethodChannel('bili_downloader/files');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (call) async => 'content://fixture/output',
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final file = await File('${directory.path}/ready.mp4')
            .writeAsBytes([1, 2, 3]);
        final job = sampleJob(1)
          ..outputs.add(file.path)
          ..state = JobState.completed;
        Map<String, dynamic>? committed;
        job.onCheckpoint = () async {
          expect(await file.exists(), true);
          if (failWrite) throw const AppFailure('historyWriteFailed');
          committed = jobSnapshot(job);
        };
        final exporting = platform.exportCompletedFiles(
          job,
          'content://fixture/tree',
        );
        if (failWrite) {
          await expectLater(exporting, throwsA(isA<AppFailure>()));
          expect(job.outputs, [file.path]);
          expect(await file.exists(), true);
        } else {
          await exporting;
          expect(await file.exists(), false);
          expect(restoreJob(committed!).outputs, ['content://fixture/output']);
        }
      },
    );
  }

  test('unreadable state is not treated as empty history', () async {
    await Directory('$path.0.json').create();
    final store = FileStateStore(path);
    await expectLater(
      store.read(),
      throwsA(
        isA<AppFailure>().having((e) => e.key, 'key', 'historyReadFailed'),
      ),
    );
    await expectLater(store.write({'value': 1}), throwsA(isA<AppFailure>()));
    expect(await Directory('$path.0.json').exists(), true);
    await store.close();
  });

  test(
    'OS lock rejects a second writer and force-kill preserves committed data',
    () async {
      final child = await Process.start('dart', [
        'run',
        'test/fixtures/state_writer.dart',
        path,
      ]);
      final lines = StreamIterator(
        child.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final stderr = child.stderr.transform(utf8.decoder).join();
      try {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 30)),
          true,
        );
        expect(lines.current, 'locked');
        final competing = FileStateStore(path);
        await expectLater(
          competing.read(),
          throwsA(
            isA<AppFailure>().having((e) => e.key, 'key', 'historyInUse'),
          ),
        );
        await competing.close();
        child.stdin.writeln('write');
        await child.stdin.flush();
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          true,
        );
        expect(lines.current, 'replacing');
        child.kill(ProcessSignal.sigkill);
        await child.exitCode.timeout(const Duration(seconds: 10));
        final recovered = FileStateStore(path);
        expect((await recovered.read()).data, {'value': 1});
        await recovered.write({'value': 3});
        await recovered.close();
      } finally {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        await lines.cancel();
        final errors = await stderr;
        expect(errors, isNot(contains('Unhandled exception')));
      }
    },
  );

  test('interrupted replacement keeps the last committed generation', () async {
    var interrupt = false;
    final store = FileStateStore(
      path,
      beforeReplace: (_) async {
        if (interrupt) throw const FileSystemException('Injected interruption');
      },
    );
    await store.read();
    await store.write({'value': 1});
    interrupt = true;
    await expectLater(store.write({'value': 2}), throwsA(isA<AppFailure>()));
    await store.close();
    final reopened = FileStateStore(path);
    expect((await reopened.read()).data, {'value': 1});
    await reopened.close();
  });

  test(
    'one damaged generation recovers; two damaged generations stay untouched',
    () async {
      final store = FileStateStore(path);
      await store.read();
      await store.write({'value': 1});
      await store.write({'value': 2});
      await store.close();
      await File('$path.0.json').writeAsString('{broken');
      final fallback = FileStateStore(path);
      final snapshot = await fallback.read();
      expect(snapshot.data, {'value': 1});
      expect(snapshot.recovered, true);
      await fallback.close();
      await File('$path.1.json').writeAsString('{also broken');
      final damaged = FileStateStore(path);
      await expectLater(
        damaged.read(),
        throwsA(
          isA<AppFailure>().having((e) => e.key, 'key', 'historyCorrupt'),
        ),
      );
      await expectLater(
        damaged.write({'value': 3}),
        throwsA(isA<AppFailure>()),
      );
      expect(await File('$path.0.json').readAsString(), '{broken');
      expect(await File('$path.1.json').readAsString(), '{also broken');
      await damaged.close();
    },
  );

  test(
    'enqueued writes capture immutable data and preserve write order',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var first = true;
      final store = FileStateStore(
        path,
        beforeReplace: (_) async {
          if (first) {
            first = false;
            entered.complete();
            await release.future;
          }
        },
      );
      await store.read();
      final one = store.write({'value': 1});
      await entered.future;
      final data = {
        'nested': [2],
      };
      final two = store.write(data);
      data['nested']!.add(3);
      release.complete();
      await Future.wait([one, two]);
      await store.close();
      final reopened = FileStateStore(path);
      expect((await reopened.read()).data, {
        'nested': [2],
      });
      await reopened.close();
    },
  );

  test(
    'snapshots preserve task options and identity without signed media URLs',
    () {
      const url = 'https://media.invalid/video?secret=temporary-token';
      final job = sampleJob(1)
        ..state = JobState.merging
        ..streams['video'] = const StreamIdentity(url, 100, 'etag');
      final snapshot = jobSnapshot(job);
      expect(jsonEncode(snapshot), isNot(contains('temporary-token')));
      final restored = restoreJob(snapshot);
      expect(restored.id, job.id);
      expect(restored.options.directory, '/saved/path');
      expect(restored.options.onlyAudio, true);
      expect(restored.state, JobState.paused);
      expect(restored.detail, 'interruptedTask');
      expect(restored.streams['video']!.matchesUrl(url), true);
      expect(restored.streams['video']!.matchesUrl('$url-changed'), false);
    },
  );

  test('closing and restoring a queue keeps waiting jobs and requires explicit resume', () async {
    final runner = ControlledRunner();
    final queue = DownloadQueue(runner, maxConcurrent: 1);
    await queue.restore(FileStateStore(path));
    final jobs = [sampleJob(1), sampleJob(2)];
    queue.add(jobs);
    await runner.started.future;
    expect(runner.starts, 1);
    await queue.close();
    queue.dispose();
    final nextRunner = ControlledRunner();
    final next = DownloadQueue(nextRunner, maxConcurrent: 1);
    await next.restore(FileStateStore(path));
    expect(next.jobs.map((j) => j.id), jobs.map((j) => j.id));
    expect(next.jobs.map((j) => j.state), everyElement(JobState.paused));
    expect(nextRunner.starts, 0);
    next.resume(next.jobs.first);
    await nextRunner.started.future;
    expect(nextRunner.starts, 1);
    await next.close();
    next.dispose();
  });

  test(
    'failed durable write prevents media work until an explicit retry',
    () async {
      final store = MemoryStore()
        ..beforeWrite = () async =>
            throw const AppFailure('historyWriteFailed');
      final runner = ControlledRunner();
      final queue = DownloadQueue(runner);
      await queue.restore(store);
      final failed = Completer<void>();
      queue.addListener(() {
        if (queue.jobs.any((j) => j.state == JobState.failed) &&
            !failed.isCompleted) {
          failed.complete();
        }
      });
      queue.add([sampleJob(1)]);
      await failed.future.timeout(const Duration(seconds: 2));
      expect(runner.starts, 0);
      expect(queue.persistenceError?.key, 'historyWriteFailed');
      store.beforeWrite = null;
      queue.resume(queue.jobs.single);
      await runner.started.future;
      expect(queue.persistenceError, isNull);
      await queue.close();
      queue.dispose();
    },
  );

  test(
    'clearing a completed task cannot be undone by a concurrent checkpoint',
    () async {
      final completed = sampleJob(1)..state = JobState.completed;
      final paused = sampleJob(2)..state = JobState.paused;
      final store = MemoryStore()
        ..data = {
          'version': 1,
          'jobs': [jobSnapshot(completed), jobSnapshot(paused)],
        };
      final queue = DownloadQueue(ControlledRunner());
      await queue.restore(store);
      final entered = Completer<void>(), release = Completer<void>();
      store.beforeWrite = () async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final remove = queue.clearCompleted();
      await entered.future;
      final checkpoint = queue.jobs.single.checkpoint();
      release.complete();
      await Future.wait([remove, checkpoint]);
      expect((store.data['jobs'] as List).map((m) => m['id']), [paused.id]);
      await queue.close();
      queue.dispose();
    },
  );
}
