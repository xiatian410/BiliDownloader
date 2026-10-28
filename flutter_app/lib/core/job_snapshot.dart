import 'download_job.dart';
import 'models.dart';
import 'wire.dart';
import 'attachments.dart';

Map<String, dynamic> jobSnapshot(DownloadJob j) => {
  'id': j.id,
  'submissionKey': j.submissionKey,
  'episode': episodeToJson(j.episode),
  'options': optionsToJson(j.options),
  'state': j.state.name,
  'revision': j.revision,
  'stage': j.stage,
  'detail': j.detail,
  'received': j.received,
  'total': j.total,
  'actualQuality': j.actualQuality,
  'outputs': List.of(j.outputs),
  'pendingExports': List.of(j.pendingExports),
  'exportedDirectory': j.exportedDirectory,
  'exportedFiles': Map.of(j.exportedFiles),
  'mediaPrepared': j.mediaPrepared,
  'commentsPrepared': j.commentsPrepared,
  'attachments': j.attachments.map(
    (key, value) => MapEntry(key, value.toJson(includePath: true)),
  ),
  'expectedMediaOutputs': List.of(j.expectedMediaOutputs),
  'error': j.error == null
      ? null
      : {'key': j.error!.key, 'detail': j.error!.detail},
  // Signed media URLs are never persisted. Reacquire them and compare fingerprints/validators.
  'streams': j.streams.map(
    (key, value) => MapEntry(key, {
      'fingerprint': value.fingerprint,
      'size': value.size,
      'validator': value.validator,
    }),
  ),
  'publications': j.publications.map(
    (key, value) => MapEntry(key, {
      'source': value.source,
      'size': value.size,
      'digest': value.digest,
    }),
  ),
};

DownloadJob restoreJob(Map<String, dynamic> m) {
  final id = m['id'] as String;
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
    throw const AppFailure('historyCorrupt');
  }
  final j = DownloadJob(
    episodeFromJson(Map<String, dynamic>.from(m['episode'])),
    optionsFromJson(Map<String, dynamic>.from(m['options'])),
    id: id,
  );
  final state = JobState.values.byName(m['state'] as String);
  j.submissionKey = m['submissionKey'] as String?;
  j.revision = m['revision'] as int? ?? 0;
  j.state =
      [JobState.completed, JobState.failed, JobState.cancelled].contains(state)
      ? state
      : JobState.paused;
  j.stage = j.state.name;
  j.detail = m['detail'] as String? ?? '';
  if ([
    JobState.running,
    JobState.pausing,
    JobState.merging,
    JobState.queued,
  ].contains(state)) {
    j.detail = 'interruptedTask';
  }
  j.received = m['received'] as int? ?? 0;
  j.total = m['total'] as int? ?? 0;
  j.actualQuality = m['actualQuality'] as int?;
  j.outputs.addAll(List<String>.from(m['outputs'] ?? []));
  j.pendingExports.addAll(List<String>.from(m['pendingExports'] ?? []));
  j.exportedDirectory = m['exportedDirectory'] as String?;
  j.exportedFiles.addAll(Map<String, String>.from(m['exportedFiles'] ?? {}));
  j.mediaPrepared = m['mediaPrepared'] == true;
  j.commentsPrepared = m['commentsPrepared'] == true;
  for (final entry in (m['attachments'] as Map? ?? {}).entries) {
    j.attachments[entry.key as String] = AttachmentResult.fromJson(
      entry.value as Map,
    );
    if (j.attachments[entry.key]!.state == AttachmentState.working) {
      j.attachments[entry.key]!.state = AttachmentState.pending;
    }
  }
  j.expectedMediaOutputs.addAll(
    List<String>.from(m['expectedMediaOutputs'] ?? []),
  );
  if (m['error'] is Map) {
    j.error = AppFailure(
      m['error']['key'] as String,
      m['error']['detail'] as String? ?? '',
    );
  }
  for (final entry in (m['streams'] as Map? ?? {}).entries) {
    final v = entry.value as Map;
    j.streams[entry.key as String] = StreamIdentity(
      '',
      v['size'] as int,
      v['validator'] as String?,
      fingerprint: v['fingerprint'] as String,
    );
  }
  for (final entry in (m['publications'] as Map? ?? {}).entries) {
    final v = entry.value as Map;
    j.publications[entry.key as String] = Publication(
      v['source'] as String,
      v['size'] as int,
      v['digest'] as String,
    );
  }
  return j;
}
