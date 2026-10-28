import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/bili_api.dart';
import '../core/download_job.dart';
import '../core/models.dart';
import '../core/remote_api.dart';
import '../core/wire.dart';

DownloadRunner createDownloadRunner(BiliApi api) =>
    WebDownloadRunner(api as RemoteBiliApi);

class WebDownloadRunner implements DownloadRunner, RemoteJobManagement {
  WebDownloadRunner(this.api);
  final RemoteBiliApi api;
  final _channels = <WebSocketChannel>{};
  @override
  Future<void> removeCompleted(Iterable<DownloadJob> jobs) async {
    await api.call('/api/jobs/remove', {
      'ids': jobs.map((j) => j.remoteId).whereType<String>().toList(),
    });
  }

  @override
  Future<void> run(DownloadJob job, void Function() changed) async {
    final channel = WebSocketChannel.connect(
      api.origin
          .resolve('/api/events')
          .replace(scheme: api.origin.scheme == 'https' ? 'wss' : 'ws'),
    );
    _channels.add(channel);
    final completed = Completer<void>();
    // Attach an error listener before asynchronous connection/setup can finish.
    final result = completed.future;
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    var finished = false;
    var readyToAccept = false;
    final latest = <String, Map<String, dynamic>>{};
    void accept(Map<String, dynamic> data) {
      if (data['id'] != job.remoteId || finished) return;
      job.stage = data['stage'] as String;
      job.received = data['received'] as int;
      job.total = data['total'] as int;
      job.actualQuality = data['actualQuality'] as int?;
      job.detail = data['detail'] as String? ?? '';
      final state = data['state'] as String;
      job.state = state == 'merging'
          ? JobState.merging
          : state == 'pausing'
          ? JobState.pausing
          : JobState.running;
      changed();
      if (completed.isCompleted) return;
      if (state == 'completed') {
        job.outputs.clear();
        job.outputs.addAll(
          (data['outputs'] as List).map(
            (f) => api.origin.resolve(f['url'] as String).toString(),
          ),
        );
        completed.complete();
      } else if (state == 'failed') {
        final error = data['error'] as Map?;
        completed.completeError(
          AppFailure(
            error?['key'] as String? ?? 'downloadFailed',
            error?['detail'] as String? ?? '',
          ),
        );
      } else if (state == 'paused') {
        completed.completeError(
          DioException.requestCancelled(
            requestOptions: RequestOptions(),
            reason: 'paused',
          ),
        );
      }
    }

    final subscription = channel.stream.listen(
      (raw) {
        try {
          final data = Map<String, dynamic>.from(jsonDecode(raw as String));
          latest[data['id'] as String] = data;
          if (readyToAccept) accept(data);
        } catch (_) {
          if (!completed.isCompleted) {
            completed.completeError(const AppFailure('invalidResponse'));
          }
        }
      },
      onError: (Object _) {
        if (!completed.isCompleted) {
          completed.completeError(const AppFailure('serviceDisconnected'));
        }
      },
      onDone: () {
        if (!completed.isCompleted) {
          completed.completeError(const AppFailure('serviceDisconnected'));
        }
      },
    );
    Future<void> pause() async {
      if (finished || job.remoteId == null) return;
      try {
        accept(
          await api.call('/api/jobs/control', {
            'id': job.remoteId,
            'action': 'pause',
          }),
        );
      } catch (_) {
        if (!completed.isCompleted) {
          completed.completeError(const AppFailure('serviceDisconnected'));
        }
      }
    }

    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      if (job.remoteId == null) {
        final data = await api.call('/api/jobs', {
          'episode': job.episode.identity,
          'options': optionsToJson(job.options),
        });
        job.remoteId = data['id'] as String;
        readyToAccept = true;
        accept(latest[job.remoteId] ?? data);
      } else {
        final data = await api.call('/api/jobs/control', {
          'id': job.remoteId,
          'action': 'resume',
        });
        readyToAccept = true;
        final cached = latest[job.remoteId];
        accept(
          cached != null && ['completed', 'failed'].contains(cached['state'])
              ? cached
              : data,
        );
      }
      unawaited(job.token.whenCancel.then((_) => pause()));
      await result;
    } finally {
      finished = true;
      await subscription.cancel();
      await channel.sink.close();
      _channels.remove(channel);
    }
  }

  @override
  void dispose() {
    for (final channel in _channels.toList()) {
      unawaited(channel.sink.close());
    }
  }
}
