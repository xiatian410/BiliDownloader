import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/bili_api.dart';
import '../core/download_job.dart';
import '../core/models.dart';
import '../core/remote_api.dart';
import '../core/wire.dart';
import '../core/media_merge.dart';

DownloadRunner createDownloadRunner(BiliApi api) =>
    WebDownloadRunner(api as RemoteBiliApi);

class WebDownloadRunner implements DownloadRunner, RemoteJobManagement {
  WebDownloadRunner(this.api, {WebSocketChannel Function(Uri)? connect})
    : connect = connect ?? WebSocketChannel.connect;
  final RemoteBiliApi api;
  final WebSocketChannel Function(Uri) connect;
  final _channels = <WebSocketChannel>{};
  @override
  Future<void> removeCompleted(Iterable<DownloadJob> jobs) async {
    await api.call('/api/jobs/remove', {
      'ids': jobs.map((j) => j.remoteId).whereType<String>().toList(),
    });
  }

  @override
  Future<void> run(DownloadJob job, void Function() changed) async {
    final channel = connect(
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
    var revision = -1;
    final latest = <String, Map<String, dynamic>>{};
    void accept(Map<String, dynamic> data) {
      if (data['id'] != job.remoteId || finished || completed.isCompleted) {
        return;
      }
      final nextRevision = data['revision'] as int? ?? 0;
      if (nextRevision < revision) return;
      revision = nextRevision;
      job.stage = data['stage'] as String;
      job.received = data['received'] as int;
      job.total = data['total'] as int;
      job.actualQuality = data['actualQuality'] as int?;
      job.detail = data['detail'] as String? ?? '';
      job.mergeProgress = data['merge'] is Map
          ? MergeProgress.fromJson(data['merge'] as Map)
          : null;
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
          final id = data['id'] as String;
          final previous = latest[id];
          if (previous == null ||
              (data['revision'] as int? ?? 0) >=
                  (previous['revision'] as int? ?? 0)) {
            latest[id] = data;
          }
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
          'requestId': job.id,
          'episode': job.episode.identity,
          'options': optionsToJson(job.options),
        });
        job.remoteId = data['id'] as String;
        readyToAccept = true;
        final cached = latest[job.remoteId];
        accept(
          cached != null &&
                  (cached['revision'] as int? ?? 0) >
                      (data['revision'] as int? ?? 0)
              ? cached
              : data,
        );
      } else {
        final data = await api.call('/api/jobs/control', {
          'id': job.remoteId,
          'action': 'resume',
        });
        readyToAccept = true;
        final cached = latest[job.remoteId];
        accept(
          cached != null &&
                  (cached['revision'] as int? ?? 0) >
                      (data['revision'] as int? ?? 0)
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
