import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'models.dart';
import 'media_merge.dart';
import 'attachments.dart';
import 'subtitles.dart';

enum JobState {
  submitting,
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
  DownloadJob(this.episode, this.options, {String? id})
    : id = id ?? '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  static int _sequence = 0;
  final String id;
  String? remoteId;
  String? submissionKey;
  bool controlPending = false;
  final Episode episode;
  final DownloadOptions options;
  JobState state = JobState.queued;
  String stage = 'queued';
  String detail = '';
  AppFailure? error;
  int received = 0, total = 0;
  int? actualQuality;
  MergeProgress? mergeProgress;
  int revision = 0;
  CancelToken token = CancelToken();
  final Map<String, StreamIdentity> streams = {};
  final List<String> outputs = [];
  // Remote queues receive display names separately from opaque download URLs.
  final List<String> outputNames = [];
  final Map<String, AttachmentResult> attachments = {};
  // Only track identity and labels are durable; signed URLs are reacquired.
  final List<SubtitleTrack> subtitleTracks = [];
  bool get hasAttachmentFailures =>
      attachments.values.any((a) => a.state == AttachmentState.failed);
  bool get hasRetryableAttachments =>
      hasAttachmentFailures ||
      attachments.values.any((a) => a.state == AttachmentState.unavailable);
  bool get canResume =>
      !controlPending &&
      ([JobState.paused, JobState.failed].contains(state) ||
          (state == JobState.completed && hasRetryableAttachments));
  final List<String> pendingExports = [];
  final Map<String, Publication> publications = {};
  final Map<String, String> exportedFiles = {};
  bool mediaPrepared = false;
  bool commentsPrepared = false;
  final List<String> expectedMediaOutputs = [];
  Future<void> Function()? onCheckpoint;
  Future<void> checkpoint() async {
    try {
      await onCheckpoint?.call();
    } catch (e) {
      throw e is AppFailure ? e : const AppFailure('historyWriteFailed');
    }
  }

  String? exportedDirectory;
  bool get active => [
    JobState.submitting,
    JobState.running,
    JobState.pausing,
    JobState.merging,
  ].contains(state);
  bool get canPause =>
      !controlPending &&
      [JobState.queued, JobState.running, JobState.merging].contains(state);
}

class StreamIdentity {
  const StreamIdentity(
    this.url,
    this.size,
    this.validator, {
    this._fingerprint,
  });
  final String url;
  final String? _fingerprint;
  String get fingerprint =>
      _fingerprint ?? sha256.convert(utf8.encode(url)).toString();
  bool matchesUrl(String value) =>
      fingerprint == sha256.convert(utf8.encode(value)).toString();
  final int size;
  final String? validator;
}

class Publication {
  const Publication(this.source, this.size, this.digest);
  final String source, digest;
  final int size;
}

abstract class DownloadRunner {
  Future<void> run(DownloadJob job, void Function() changed);
  void dispose();
}
