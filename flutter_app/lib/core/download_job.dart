import 'package:dio/dio.dart';

import 'models.dart';

enum JobState {
  queued,
  running,
  pausing,
  paused,
  merging,
  completed,
  failed,
  cancelled,
}

class DownloadJob {
  DownloadJob(this.episode, this.options)
    : id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  static int _sequence = 0;
  final String id;
  String? remoteId;
  final Episode episode;
  final DownloadOptions options;
  JobState state = JobState.queued;
  String stage = 'queued';
  String detail = '';
  AppFailure? error;
  int received = 0, total = 0;
  int? actualQuality;
  CancelToken token = CancelToken();
  final Map<String, StreamIdentity> streams = {};
  final List<String> outputs = [];
  final List<String> pendingExports = [];
  String? exportedDirectory;
  bool get active =>
      [JobState.running, JobState.pausing, JobState.merging].contains(state);
  bool get canPause => [JobState.queued, JobState.running].contains(state);
}

class StreamIdentity {
  const StreamIdentity(this.url, this.size, this.validator);
  final String url;
  final int size;
  final String? validator;
}

abstract class DownloadRunner {
  Future<void> run(DownloadJob job, void Function() changed);
  void dispose();
}

abstract interface class RemoteJobManagement {
  Future<void> removeCompleted(Iterable<DownloadJob> jobs);
}
