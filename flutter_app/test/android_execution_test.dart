import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/download_queue.dart';
import 'package:bili_downloader/platform/android_execution_host.dart';

import 'queue_test.dart' show PendingRunner, job;
import 'persistence_test.dart' show MemoryStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('bili_downloader/execution');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;
  late DownloadQueue queue;
  late PendingRunner runner;
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  Future<void> nativePause([String? reason]) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('pause', reason)),
      (ByteData? response) {
        try {
          if (response != null) {
            const StandardMethodCodec().decodeEnvelope(response);
          }
          done.complete();
        } catch (e, stack) {
          done.completeError(e, stack);
        }
      },
    );
    await done.future;
    await tick();
  }

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    runner = PendingRunner();
    queue = DownloadQueue(
      runner,
      maxConcurrent: 1,
      executionHost: AndroidExecutionHost(),
    );
  });
  tearDown(() async {
    await queue.close();
    queue.dispose();
    channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('worker waits for service acknowledgment and cancellation before start is honored', () async {
    final acknowledgment = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'start') await acknowledgment.future;
      return null;
    });
    final j = job(1);
    await queue.add([j]);
    await tick();
    expect(runner.started, isEmpty);
    queue.pause(j);
    acknowledgment.complete();
    await tick();
    expect(j.state, JobState.paused);
    expect(runner.started, isEmpty);
    expect(calls.where((c) => c == 'stop'), hasLength(1));
  });

  test('one service session spans consecutive queued downloads', () async {
    final jobs = [job(1), job(2)];
    await queue.add(jobs);
    await tick();
    runner.pending[jobs[0]]!.complete();
    await tick();
    expect(runner.started, jobs);
    expect(calls.where((c) => c == 'start'), hasLength(1));
    expect(calls, isNot(contains('stop')));
    runner.pending[jobs[1]]!.complete();
    await tick();
    expect(calls.where((c) => c == 'stop'), hasLength(1));
    queue.add([job(3)]);
    await tick();
    expect(calls.where((c) => c == 'start'), hasLength(2));
  });

  test(
    'service denial stops queued work without running an unprotected worker',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'start') {
          throw PlatformException(
            code: 'denied',
            message: 'private device detail',
          );
        }
        return null;
      });
      final jobs = [job(1), job(2), job(3)];
      await queue.add(jobs);
      await tick();
      expect(runner.started, isEmpty);
      expect(jobs.every((j) => !j.active && j.state != JobState.queued), true);
      expect(jobs.every((j) => j.error?.key == 'backgroundUnavailable'), true);
      expect(calls.where((c) => c == 'start'), hasLength(1));
    },
  );

  test('notification pause and system timeout use the same queue and require manual resume', () async {
    final jobs = [job(1), job(2)];
    await queue.add(jobs);
    await tick();
    await nativePause('backgroundExpired');
    expect(jobs.every((j) => j.state == JobState.paused), true);
    expect(jobs.every((j) => j.error?.key == 'backgroundExpired'), true);
    expect(calls.where((c) => c == 'stop'), hasLength(1));
    queue.resume(jobs.first);
    await tick();
    expect(runner.started, hasLength(2));
    expect(jobs.last.state, JobState.paused);
    await nativePause();
    expect(jobs.first.state, JobState.paused);
  });
  test(
    'service remains alive until the last durable checkpoint finishes',
    () async {
      final store = MemoryStore();
      await queue.restore(store);
      final j = job(1);
      await queue.add([j]);
      await tick();
      final writing = Completer<void>();
      final commit = Completer<void>();
      store.beforeWrite = () async {
        if (j.state == JobState.completed) {
          if (!writing.isCompleted) writing.complete();
          await commit.future;
        }
      };
      runner.pending[j]!.complete();
      await writing.future;
      queue.setLanguage('en');
      await tick();
      expect(calls, isNot(contains('stop')));
      commit.complete();
      await tick();
      expect(calls.where((c) => c == 'stop'), hasLength(1));
    },
  );

  test(
    'failed history stops the service even when jobs remain queued',
    () async {
      final store = MemoryStore();
      await queue.restore(store);
      final jobs = [job(1), job(2)];
      await queue.add(jobs);
      await tick();
      store.beforeWrite = () async => throw StateError('disk full');
      runner.pending[jobs.first]!.complete();
      await tick();
      expect(jobs.last.state, JobState.queued);
      expect(queue.persistenceError, isNotNull);
      expect(calls.where((c) => c == 'stop'), hasLength(1));
      expect(runner.started, hasLength(1));
    },
  );

  test(
    'concurrent workers share one startup and stop only after all finish',
    () async {
      await queue.setConcurrency(3);
      final jobs = [job(1), job(2), job(3)];
      await queue.add(jobs);
      await tick();
      expect(runner.started, hasLength(3));
      expect(calls.where((c) => c == 'start'), hasLength(1));
      for (final j in jobs.take(2)) {
        runner.pending[j]!.complete();
      }
      await tick();
      expect(calls, isNot(contains('stop')));
      runner.pending[jobs.last]!.complete();
      await tick();
      expect(calls.where((c) => c == 'stop'), hasLength(1));
    },
  );
  test('late native pause is ignored while disposed queue finishes its checkpoint', () async {
    final store = MemoryStore();
    await queue.restore(store);
    final writing = Completer<void>();
    final commit = Completer<void>();
    store.beforeWrite = () async {
      if (!writing.isCompleted) writing.complete();
      await commit.future;
    };
    await queue.add([job(1)]);
    await writing.future;
    queue.dispose();
    try {
      await nativePause('backgroundExpired');
      expect(runner.started, isEmpty);
    } finally {
      commit.complete();
    }
    await queue.close();
    // tearDown owns its own empty queue; the disposed instance stays disposed.
    queue = DownloadQueue(runner);
  });
}
