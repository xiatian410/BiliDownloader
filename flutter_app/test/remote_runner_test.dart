import 'dart:async';
import 'dart:convert';

import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/core/remote_api.dart';
import 'package:bili_downloader/core/wire.dart';
import 'package:bili_downloader/platform/download_web.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class TestSocket implements WebSocketChannel {
  TestSocket([List<Map<String, dynamic>> initial = const []]) {
    incoming = StreamController<dynamic>(
      sync: true,
      onListen: () {
        scheduleMicrotask(() {
          if (sendSnapshot) {
            emit({'type': 'snapshot', 'jobs': initial, 'concurrency': 4});
          }
        });
      },
    );
  }
  late final StreamController<dynamic> incoming;
  bool sendSnapshot = true;
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready async {}
  @override
  WebSocketSink get sink => TestSink(incoming);
  void emit(Map data) => incoming.add(jsonEncode(data));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestSink implements WebSocketSink {
  TestSink(this.incoming);
  final StreamController<dynamic> incoming;
  @override
  Future<void> close([int? closeCode, String? closeReason]) => incoming.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestRemote extends RemoteBiliApi {
  TestRemote(this.response) : super(origin: Uri.parse('http://localhost:1234'));
  final FutureOr<Map<String, dynamic>> Function(
    String path,
    Map<String, dynamic> body,
  )
  response;
  List<Map<String, dynamic>> bootstrap = [];
  Completer<void>? bootstrapGate;
  final initializing = Completer<void>();
  @override
  Future<void> initializeSession() async {
    if (!initializing.isCompleted) initializing.complete();
    await bootstrapGate?.future;
    restoredJobs = bootstrap;
  }

  @override
  Future<Map<String, dynamic>> call(
    String path, [
    Map<String, dynamic> body = const {},
    CancelToken? cancel,
  ]) async => response(path, body);
}

Map<String, dynamic> event(
  String state,
  int revision, {
  String id = 'remote-task',
  String? requestId,
  int cid = 1,
}) => {
  'id': id,
  'requestId': requestId,
  'revision': revision,
  'state': state,
  'stage': state == 'running' ? 'videoDownload' : state,
  'received': 10,
  'total': 20,
  'episode': episodeToJson(
    Episode(cid: cid, number: 1, name: 'part', title: 'video'),
  ),
  'options': optionsToJson(const DownloadOptions(directory: '', quality: 80)),
  'outputs': [
    {'url': '/api/files/$id/0'},
  ],
  if (state == 'failed') 'error': {'key': 'httpError', 'detail': '503'},
};

DownloadJob task([int cid = 1]) => DownloadJob(
  Episode(cid: cid, number: 1, name: 'part', title: 'video'),
  const DownloadOptions(directory: '', quality: 80),
);

Future<void> until(RemoteDownloadQueue queue, bool Function() condition) async {
  if (condition()) return;
  final done = Completer<void>();
  void changed() {
    if (condition() && !done.isCompleted) done.complete();
  }

  queue.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 2));
  } finally {
    queue.removeListener(changed);
  }
}

void main() {
  test(
    'closing during session initialization cancels pending queue mutations',
    () async {
      var calls = 0, connections = 0;
      final gate = Completer<void>();
      final api = TestRemote((path, body) {
        calls++;
        throw StateError('A closed view must not submit commands');
      })..bootstrapGate = gate;
      final queue = RemoteDownloadQueue(
        api,
        connect: (_) {
          connections++;
          return TestSocket();
        },
      );
      final adding = queue.add([task()]);
      final settings = queue.setConcurrency(2);
      final clearing = queue.clearCompleted();
      await api.initializing.future;
      await queue.close();
      gate.complete();
      await Future.wait([adding, settings, clearing]);
      expect(calls, 0);
      expect(connections, 0);
      expect(queue.jobs, isEmpty);
      queue.dispose();
      api.close();
    },
  );

  test(
    'closing before the initial snapshot releases the connection wait',
    () async {
      final socket = TestSocket()..sendSnapshot = false;
      final api = TestRemote(
        (path, body) => throw StateError('No commands expected'),
      );
      final connected = Completer<void>();
      final queue = RemoteDownloadQueue(
        api,
        connect: (_) {
          connected.complete();
          return socket;
        },
      );
      final opening = queue.reconnect();
      await connected.future;
      await queue.close();
      await opening.timeout(const Duration(seconds: 1));
      expect(queue.connected, false);
      expect(queue.connectionError, isNull);
      queue.dispose();
      api.close();
    },
  );
  test('concurrency edits are serialized and a newer server setting wins over a stale reply', () async {
    final socket = TestSocket();
    final calls = <int>[];
    final firstStarted = Completer<void>();
    final release = Completer<void>();
    final api = TestRemote((path, body) async {
      expect(path, '/api/settings');
      final value = body['concurrency'] as int;
      calls.add(value);
      if (calls.length == 1) {
        firstStarted.complete();
        await release.future;
        return {'concurrency': value, 'revision': 1};
      }
      socket.emit({'type': 'settings', 'concurrency': 1, 'revision': 3});
      return {'concurrency': value, 'revision': 2};
    });
    final queue = RemoteDownloadQueue(api, connect: (_) => socket);
    addTearDown(() async {
      await queue.close();
      queue.dispose();
      api.close();
    });
    final first = queue.setConcurrency(2);
    final second = queue.setConcurrency(3);
    await firstStarted.future;
    expect(calls, [2]);
    release.complete();
    await Future.wait([first, second]);
    expect(calls, [2, 3]);
    expect(queue.maxConcurrent, 1);
  });
  test(
    'one batch submits every queued item through one event connection',
    () async {
      final socket = TestSocket();
      var connections = 0, submissions = 0, pauses = 0;
      final api = TestRemote((path, body) {
        if (path == '/api/jobs/control') {
          pauses++;
          expect(body['action'], 'pause');
          return event('paused', 2, id: body['id'] as String, cid: 8);
        }
        expect(path, '/api/jobs/batch');
        submissions++;
        final entries = body['jobs'] as List;
        expect(entries, hasLength(8));
        return {
          'jobs': [
            for (var i = 0; i < entries.length; i++)
              event(
                'queued',
                1,
                id: 'remote-$i',
                requestId: entries[i]['requestId'],
                cid: i + 1,
              ),
          ],
        };
      });
      final queue = RemoteDownloadQueue(
        api,
        connect: (_) {
          connections++;
          return socket;
        },
      );
      addTearDown(() async {
        await queue.close();
        queue.dispose();
        api.close();
      });
      await queue.add(List.generate(8, (i) => task(i + 1)));
      expect(queue.jobs, hasLength(8));
      expect(
        queue.jobs.every(
          (j) => j.remoteId != null && j.state == JobState.queued,
        ),
        true,
      );
      expect(connections, 1);
      expect(submissions, 1);
      final last = queue.jobs.last;
      queue.pause(last);
      await until(
        queue,
        () => last.state == JobState.paused && !last.controlPending,
      );
      expect(pauses, 1);
      await queue.close();
      expect(
        pauses,
        1,
        reason: 'Closing the view must not pause remote tasks.',
      );
    },
  );

  for (final completesEarly in [false, true]) {
    test(
      'old failure cannot override ${completesEarly ? 'new completion' : 'resume response'}',
      () async {
        final socket = TestSocket([event('failed', 1)]);
        final api = TestRemote((path, body) {
          expect(path, '/api/jobs/control');
          if (completesEarly) socket.emit(event('completed', 4));
          socket.emit(event('failed', 1));
          return event('running', 2);
        });
        final queue = RemoteDownloadQueue(api, connect: (_) => socket);
        addTearDown(() async {
          await queue.close();
          queue.dispose();
          api.close();
        });
        await queue.reconnect();
        final job = queue.jobs.single;
        queue.resume(job);
        await until(queue, () => !job.controlPending);
        expect(
          job.state,
          completesEarly ? JobState.completed : JobState.running,
        );
        socket.emit(event('failed', 1));
        expect(
          job.state,
          completesEarly ? JobState.completed : JobState.running,
        );
        socket.emit(event('completed', 5));
        expect(
          job.outputs.single,
          'http://localhost:1234/api/files/remote-task/0',
        );
      },
    );
  }

  test('lost batch response retries the same request key without adding another local task', () async {
    final socket = TestSocket();
    final keys = <String>[];
    final api = TestRemote((path, body) {
      expect(path, '/api/jobs/batch');
      final entry = (body['jobs'] as List).single;
      keys.add(entry['requestId']);
      if (keys.length == 1) throw const AppFailure('serviceUnavailable');
      return {
        'jobs': [event('completed', 2, requestId: entry['requestId'])],
      };
    });
    final queue = RemoteDownloadQueue(api, connect: (_) => socket);
    addTearDown(() async {
      await queue.close();
      queue.dispose();
      api.close();
    });
    final job = task();
    await queue.add([job]);
    expect(job.state, JobState.failed);
    queue.resume(job);
    await until(
      queue,
      () => job.state == JobState.completed && !job.controlPending,
    );
    expect(keys, [job.id, job.id]);
    expect(queue.jobs, [job]);
  });

  test(
    'a task event confirms submission even when the HTTP response is lost',
    () async {
      final socket = TestSocket();
      final api = TestRemote((path, body) {
        final entry = (body['jobs'] as List).single;
        socket.emit(event('queued', 1, requestId: entry['requestId']));
        throw const AppFailure('serviceUnavailable');
      });
      final queue = RemoteDownloadQueue(api, connect: (_) => socket);
      addTearDown(() async {
        await queue.close();
        queue.dispose();
        api.close();
      });
      final job = task();
      await queue.add([job]);
      expect(job.remoteId, 'remote-task');
      expect(job.state, JobState.queued);
      expect(job.error, isNull);
    },
  );

  test('disconnect preserves last task state and reconnect takes an authoritative snapshot', () async {
    final sockets = [
      TestSocket([event('running', 5)]),
      TestSocket([event('completed', 1)]),
    ];
    var connections = 0;
    final api = TestRemote(
      (path, body) => throw StateError('No task control expected'),
    );
    final queue = RemoteDownloadQueue(
      api,
      connect: (_) => sockets[connections++],
    );
    addTearDown(() async {
      await queue.close();
      queue.dispose();
      api.close();
    });
    await queue.reconnect();
    expect(queue.jobs.single.state, JobState.running);
    await sockets.first.incoming.close();
    expect(queue.connected, false);
    expect(queue.connectionError?.key, 'serviceDisconnected');
    expect(queue.jobs.single.state, JobState.running);
    api.bootstrap = [event('completed', 1)];
    await queue.reconnect();
    expect(queue.connected, true);
    expect(queue.jobs.single.state, JobState.completed);
    expect(connections, 2);
  });

  test('clear notifications remove records and stale task messages cannot resurrect them', () async {
    final socket = TestSocket([event('completed', 4)]);
    final api = TestRemote((path, body) {
      expect(path, '/api/jobs/remove');
      return {'ok': true};
    });
    final queue = RemoteDownloadQueue(api, connect: (_) => socket);
    addTearDown(() async {
      await queue.close();
      queue.dispose();
      api.close();
    });
    await queue.reconnect();
    await queue.clearCompleted();
    socket.emit(event('completed', 4));
    expect(queue.jobs, isEmpty);
  });
}
