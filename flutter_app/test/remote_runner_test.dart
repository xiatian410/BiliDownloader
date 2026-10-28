import 'dart:async';
import 'dart:convert';

import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/core/remote_api.dart';
import 'package:bili_downloader/platform/download_web.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class TestSocket implements WebSocketChannel {
  final incoming = StreamController<dynamic>(sync: true);
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
  final Map<String, dynamic> Function(String path, Map<String, dynamic> body)
  response;
  @override
  Future<Map<String, dynamic>> call(
    String path, [
    Map<String, dynamic> body = const {},
    CancelToken? cancel,
  ]) async => response(path, body);
}

Map<String, dynamic> event(String state, int revision) => {
  'id': 'remote-task',
  'revision': revision,
  'state': state,
  'stage': state == 'running' ? 'videoDownload' : state,
  'received': 10,
  'total': 20,
  'outputs': [
    {'url': '/api/files/remote-task/0'},
  ],
  if (state == 'failed') 'error': {'key': 'httpError', 'detail': '503'},
};

DownloadJob task() => DownloadJob(
  const Episode(cid: 1, number: 1, name: 'part', title: 'video'),
  const DownloadOptions(directory: '', quality: 80),
);

void main() {
  test('a cached failure cannot override a newer resume response or later progress', () async {
    final socket = TestSocket();
    final api = TestRemote((path, body) {
      socket.emit(event('failed', 1));
      return event('running', 2);
    });
    final runner = WebDownloadRunner(api, connect: (_) => socket);
    addTearDown(() {
      runner.dispose();
      api.close();
    });
    final job = task()..remoteId = 'remote-task';
    final accepted = Completer<void>();
    final done = expectLater(
      runner.run(job, () {
        if (!accepted.isCompleted) accepted.complete();
      }),
      completes,
    );
    await accepted.future;
    expect(job.stage, 'videoDownload');
    socket.emit(event('failed', 1));
    expect(job.stage, 'videoDownload');
    socket.emit(event('completed', 3));
    await done;
    expect(job.outputs.single, 'http://localhost:1234/api/files/remote-task/0');
  });

  test('newer completion received before HTTP response is kept', () async {
    final socket = TestSocket();
    final api = TestRemote((path, body) {
      socket.emit(event('completed', 4));
      socket.emit(event('failed', 1));
      return event('running', 2);
    });
    final runner = WebDownloadRunner(api, connect: (_) => socket);
    addTearDown(() {
      runner.dispose();
      api.close();
    });
    final job = task()..remoteId = 'remote-task';
    await runner.run(job, () {});
    expect(job.outputs, hasLength(1));
  });

  test(
    'a lost create response reuses the same request key on explicit retry',
    () async {
      final sockets = [TestSocket(), TestSocket()];
      final keys = <String>[];
      final api = TestRemote((path, body) {
        expect(path, '/api/jobs');
        keys.add(body['requestId'] as String);
        if (keys.length == 1) throw const AppFailure('serviceUnavailable');
        return event('completed', 1);
      });
      var connection = 0;
      final runner = WebDownloadRunner(
        api,
        connect: (_) => sockets[connection++],
      );
      addTearDown(() {
        runner.dispose();
        api.close();
      });
      final job = task();
      await expectLater(runner.run(job, () {}), throwsA(isA<AppFailure>()));
      await runner.run(job, () {});
      expect(keys, [job.id, job.id]);
      expect(job.remoteId, 'remote-task');
    },
  );
}
