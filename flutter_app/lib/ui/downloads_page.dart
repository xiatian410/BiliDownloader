import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/download_job.dart';
import '../core/models.dart';
import '../l10n/strings.dart';
import '../platform/platform.dart' as platform;
import 'widgets.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  String _filter = 'allTasks', _search = '';
  AppController get c => widget.controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c.queue,
    builder: (context, _) {
      final s = Strings.of(context);
      final visible = c.queue.jobs
          .where(
            (j) =>
                '${j.episode.title} ${j.episode.name} ${j.episode.bvid}'
                    .toLowerCase()
                    .contains(_search.toLowerCase()) &&
                (_filter == 'allTasks' ||
                    (_filter == 'activeTasks'
                        ? j.active || j.state == JobState.queued
                        : j.state.name == _filter)),
          )
          .toList();
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PageHeading(s('downloads'), s('tasksSubtitle')),
                  if (c.queue.connectionError != null) ...[
                    StatusBanner(s(c.queue.connectionError!.key), error: true),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: c.busy
                            ? null
                            : () => c.perform(c.queue.reconnect),
                        icon: const Icon(Icons.sync),
                        label: Text(s('reconnectService')),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    onChanged: (v) => setState(() => _search = v),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: s('searchTasks'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final f in [
                        'allTasks',
                        'activeTasks',
                        'paused',
                        'failed',
                        'completed',
                      ])
                        ChoiceChip(
                          label: Text(s(f)),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed:
                            c.queue.connected && visible.any((j) => j.canPause)
                            ? () {
                                for (final j in visible.where(
                                  (j) => j.canPause,
                                )) {
                                  c.queue.pause(j);
                                }
                              }
                            : null,
                        icon: const Icon(Icons.pause),
                        label: Text(
                          '${s('pauseVisible')} (${visible.where((j) => j.canPause).length})',
                        ),
                      ),
                      TextButton.icon(
                        onPressed:
                            c.queue.connected &&
                                visible.any(
                                  (j) => [
                                    JobState.paused,
                                    JobState.failed,
                                  ].contains(j.state),
                                )
                            ? () {
                                for (final j in visible.where(
                                  (j) => [
                                    JobState.paused,
                                    JobState.failed,
                                  ].contains(j.state),
                                )) {
                                  c.queue.resume(j);
                                }
                              }
                            : null,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(s('resumeVisible')),
                      ),
                      TextButton(
                        onPressed: () => c.perform(
                          () => c.queue.clearCompleted(only: visible),
                        ),
                        child: Text(s('clearCompleted')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (visible.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.download_done_rounded,
                        size: 52,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        s(c.queue.jobs.isEmpty ? 'emptyQueue' : 'noMatches'),
                      ),
                      const SizedBox(height: 8),
                      Text(s('emptyHint'), textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _job(visible[i], s),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _job(DownloadJob job, Strings s) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          job.episode.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          '${job.episode.number}. ${job.episode.name}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            Chip(
              label: Text(
                s(
                  job.options.onlyDanmaku
                      ? 'onlyDanmaku'
                      : job.options.onlyAudio
                      ? 'onlyAudio'
                      : 'videoMode',
                ),
              ),
            ),
            if (job.actualQuality != null)
              Chip(
                label: Text(
                  '${s('actualQuality')}: ${qualityLabel(job.actualQuality!)}',
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value:
              job.active &&
                  (job.state == JobState.merging ||
                      job.stage == 'stoppingMerge' ||
                      job.total == 0)
              ? null
              : job.total > 0
              ? (job.received / job.total).clamp(0, 1)
              : 0,
          minHeight: 6,
          borderRadius: BorderRadius.circular(6),
        ),
        const SizedBox(height: 12),
        Text(s(job.active ? job.stage : job.state.name)),
        if (job.mergeProgress != null && job.active)
          Text(
            '${s('mergeProgress')}: ${Duration(milliseconds: job.mergeProgress!.milliseconds).toString().split('.').first} · ${fileSize(job.mergeProgress!.bytes)}',
          ),
        if (job.error != null)
          StatusBanner(
            '${s(job.error!.key)} ${job.error!.detail}',
            error: true,
          ),
        if (job.detail.isNotEmpty) StatusBanner(s(job.detail)),
        for (final entry in job.attachments.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${s(entry.key == 'cover'
                  ? 'autoCover'
                  : entry.key == 'nfo'
                  ? 'nfo'
                  : 'subtitles')}'
              '${entry.value.label.isEmpty ? '' : ' · ${entry.value.label}'}'
              '${entry.value.automatic ? ' · ${s('automaticSubtitle')}' : ''}: '
              '${s('attachment_${entry.value.state.name}')}'
              '${entry.value.error == null ? '' : ' · ${s(entry.value.error!.key)} ${entry.value.error!.detail}'}',
            ),
          ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${fileSize(job.received)} / ${fileSize(job.total)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (job.canPause)
              IconButton(
                tooltip: s('pause'),
                onPressed: c.queue.connected ? () => c.queue.pause(job) : null,
                icon: const Icon(Icons.pause_rounded),
              ),
            if ([JobState.paused, JobState.failed].contains(job.state))
              IconButton(
                tooltip: s('resume'),
                onPressed: c.queue.connected && !job.controlPending
                    ? () => c.queue.resume(job)
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            if (job.state == JobState.completed && job.hasRetryableAttachments)
              TextButton.icon(
                onPressed: c.queue.connected && job.canResume
                    ? () => c.queue.resume(job)
                    : null,
                icon: const Icon(Icons.refresh),
                label: Text(
                  s(
                    job.hasAttachmentFailures
                        ? 'retryAttachments'
                        : 'recheckAttachments',
                  ),
                ),
              ),
            if (!kIsWeb)
              IconButton(
                tooltip: s('openDirectory'),
                onPressed: () => c.perform(
                  () => platform.openDirectory(
                    job.exportedDirectory ?? job.options.directory,
                  ),
                ),
                icon: const Icon(Icons.folder_open_outlined),
              ),
            if (kIsWeb)
              for (var index = 0; index < job.outputs.length; index++)
                TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(job.outputs[index])),
                  icon: const Icon(Icons.file_download_outlined),
                  label: Text(
                    '${s('downloadFile')} ${index + 1}'
                    '${job.outputNames.length > index ? ' · ${job.outputNames[index]}' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            if (platform.isAndroid &&
                job.state == JobState.completed &&
                job.outputs.any((p) => !p.startsWith('content://')))
              TextButton(
                onPressed: () => c.perform(() async {
                  final directory = await platform.chooseDirectory();
                  if (directory == null) return;
                  await platform.exportCompletedFiles(job, directory);
                }),
                child: Text(s('exportFiles')),
              ),
          ],
        ),
      ],
    ),
  );
}
