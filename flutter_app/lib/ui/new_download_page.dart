import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/bili_api.dart';
import '../core/models.dart';
import '../l10n/strings.dart';
import '../platform/platform.dart' as platform;
import 'widgets.dart';

class NewDownloadPage extends StatefulWidget {
  const NewDownloadPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<NewDownloadPage> createState() => _NewDownloadPageState();
}

class _NewDownloadPageState extends State<NewDownloadPage>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _range = TextEditingController();
  String _search = '';
  AppController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _range.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !kIsWeb &&
        c.settings.clipboard &&
        c.tab == 0 &&
        _input.text.isEmpty) {
      unawaited(_paste(onlyValid: true));
    }
  }

  Future<void> _paste({bool onlyValid = false}) async {
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (mounted &&
          text != null &&
          (!onlyValid || VideoId.parseMany(text).ids.isNotEmpty)) {
        setState(() => _input.text = text);
      }
    } catch (e) {
      if (!onlyValid) c.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final parsed = VideoId.parseMany(_input.text);
    return LayoutBuilder(
      builder: (context, bounds) => ListView(
        key: const PageStorageKey('new-download-scroll'),
        padding: EdgeInsets.all(bounds.maxWidth < 600 ? 16 : 28),
        children: [
          PageHeading(s('createTitle'), s('createSubtitle')),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('video-input'),
                  controller: _input,
                  minLines: 2,
                  maxLines: 5,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: s('batchHint'),
                    suffixIcon: IconButton(
                      tooltip: s('paste'),
                      onPressed: () => _paste(),
                      icon: const Icon(Icons.content_paste_rounded),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('parse-input'),
                      onPressed:
                          c.busy ||
                              parsed.ids.isEmpty ||
                              parsed.ids.length > 100
                          ? null
                          : () {
                              _search = '';
                              c.resolve(_input.text);
                            },
                      icon: const Icon(Icons.manage_search_rounded),
                      label: Text(s('parse')),
                    ),
                    if (c.busy)
                      TextButton(
                        onPressed: c.cancelResolve,
                        child: Text(s('cancel')),
                      ),
                    Text('${s('detectedCount')}: ${parsed.ids.length}'),
                    if (parsed.duplicates > 0)
                      Text('${s('duplicates')}: ${parsed.duplicates}'),
                    if (c.busy && c.resolveTotal > 0)
                      Text('${c.resolvedCount} / ${c.resolveTotal}'),
                  ],
                ),
                if (parsed.invalid.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: StatusBanner(
                      '${s('unrecognized')}: ${parsed.invalid.join(' · ')}',
                    ),
                  ),
                if (parsed.ids.length > 100)
                  StatusBanner(s('invalidBatch'), error: true),
              ],
            ),
          ),
          const SizedBox(height: 20),
          for (final error in c.resolveErrors.entries)
            StatusBanner(
              '${error.key}: ${s(error.value.key)} ${error.value.detail}',
              error: true,
            ),
          if (c.info != null) ...[
            if (bounds.maxWidth >= 1000 &&
                MediaQuery.textScalerOf(context).scale(14) <= 21)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: _selection(s)),
                  const SizedBox(width: 20),
                  Expanded(flex: 2, child: _options(s)),
                ],
              )
            else ...[
              _selection(s),
              const SizedBox(height: 20),
              _options(s),
            ],
          ] else if (!c.busy && c.resolveErrors.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  Icon(
                    Icons.video_library_outlined,
                    size: 52,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(s('startHint'), textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    'BV · AV · MD · EP',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _selection(Strings s) {
    final episodes = c.info!.episodes.indexed
        .where(
          (e) => '${e.$2.title} ${e.$2.name}'.toLowerCase().contains(
            _search.toLowerCase(),
          ),
        )
        .toList();
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (c.sources.length == 1) ...[
            if (c.info!.cover.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  aspectRatio: 16 / 7,
                  child: Image.network(
                    c.info!.cover,
                    headers: kIsWeb ? null : biliHeaders,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(
                      child: Icon(Icons.video_library_outlined, size: 48),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(c.info!.title, style: Theme.of(context).textTheme.titleMedium),
            if (c.info!.author.isNotEmpty) Text(c.info!.author),
            if (c.info!.description.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(s('description')),
                children: [SelectableText(c.info!.description)],
              ),
          ],
          if (c.info!.cover.isNotEmpty)
            TextButton.icon(
              onPressed: c.busy
                  ? null
                  : () {
                      if (kIsWeb) {
                        launchUrl(
                          Uri.base.resolve('${c.info!.cover}?download=1'),
                        );
                      } else {
                        c.saveCover();
                      }
                    },
              icon: const Icon(Icons.image_outlined),
              label: Text(s('saveCover')),
            ),
          const SizedBox(height: 10),
          Text(
            '${s('episodes')} · ${c.selected.length} / ${c.info!.episodes.length}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: (v) => setState(() => _search = v),
            decoration: InputDecoration(
              hintText: s('searchEpisodes'),
              prefixIcon: const Icon(Icons.search),
            ),
          ),
          Wrap(
            spacing: 6,
            children: [
              TextButton(
                onPressed: c.busy ? null : c.selectAll,
                child: Text(s('selectAll')),
              ),
              TextButton(
                onPressed: c.busy ? null : c.invertSelection,
                child: Text(s('invert')),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _range,
                  decoration: InputDecoration(hintText: s('selectionHint')),
                  onSubmitted: c.selectionText,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: s('apply'),
                onPressed: c.busy ? null : () => c.selectionText(_range.text),
                icon: const Icon(Icons.check),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: episodes.length <= 2
                ? (episodes.length *
                          100.0 *
                          MediaQuery.textScalerOf(context).scale(1))
                      .clamp(100, 320)
                : 320,
            child: ListView.builder(
              physics: episodes.length <= 2
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemCount: episodes.length,
              itemBuilder: (context, index) {
                final (i, e) = episodes[index];
                return CheckboxListTile(
                  key: ValueKey('episode-$i'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('${e.number}. ${e.name}'),
                  subtitle: c.sources.length > 1
                      ? Text(
                          e.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  value: c.selected.contains(i),
                  secondary: PopupMenuButton<String>(
                    tooltip: s('episodeOptions'),
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(
                        value: 'audio',
                        checked:
                            c.audioOnlyOverrides[i] ?? c.settings.onlyAudio,
                        child: Text(s('onlyAudio')),
                      ),
                      CheckedPopupMenuItem(
                        value: 'comments',
                        checked: c.danmakuOverrides[i] ?? c.settings.danmaku,
                        child: Text(s('danmaku')),
                      ),
                    ],
                    onSelected: (choice) => setState(() {
                      if (choice == 'audio') {
                        c.audioOnlyOverrides[i] =
                            !(c.audioOnlyOverrides[i] ?? c.settings.onlyAudio);
                      } else {
                        c.danmakuOverrides[i] =
                            !(c.danmakuOverrides[i] ?? c.settings.danmaku);
                      }
                    }),
                  ),
                  onChanged: c.busy
                      ? null
                      : (v) => c.changeSelection(i, v == true),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _options(Strings s) {
    final media = c.media;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s('options'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mode in ['videoMode', 'onlyAudio', 'onlyDanmaku'])
                ChoiceChip(
                  label: Text(s(mode)),
                  selected: mode == 'onlyDanmaku'
                      ? c.settings.onlyDanmaku
                      : mode == 'onlyAudio'
                      ? c.settings.onlyAudio && !c.settings.onlyDanmaku
                      : !c.settings.onlyAudio && !c.settings.onlyDanmaku,
                  onSelected: c.busy
                      ? null
                      : (_) {
                          c.settings.onlyDanmaku = mode == 'onlyDanmaku';
                          c.settings.onlyAudio = mode == 'onlyAudio';
                          c.saveSettings();
                        },
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (!c.settings.onlyDanmaku) ...[
            if (media == null)
              OutlinedButton.icon(
                key: const ValueKey('load-options'),
                onPressed: c.busy || c.selected.isEmpty ? null : c.loadOptions,
                icon: const Icon(Icons.high_quality_outlined),
                label: Text(s('loadQualities')),
              )
            else ...[
              if (!c.settings.onlyAudio && media.availableQualities.isNotEmpty)
                DropdownButtonFormField<int>(
                  key: ValueKey('quality-${media.hashCode}'),
                  initialValue: c.quality,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: s('quality')),
                  items: media.availableQualities
                      .map(
                        (q) =>
                            DropdownMenuItem(value: q.id, child: Text(q.label)),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => c.quality = v!),
                ),
              const SizedBox(height: 12),
              Text(
                s('qualityHint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (media.flac != null || media.dolby != null) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: c.specialAudio,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: s('specialAudio')),
                  items: [
                    DropdownMenuItem(value: '', child: Text(s('original'))),
                    if (media.flac != null)
                      const DropdownMenuItem(
                        value: 'flac',
                        child: Text('Hi-Res / FLAC'),
                      ),
                    if (media.dolby != null)
                      const DropdownMenuItem(
                        value: 'dolby',
                        child: Text('Dolby'),
                      ),
                  ],
                  onChanged: (v) => setState(() => c.specialAudio = v!),
                ),
              ],
              if (media.languages.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: c.audioLanguage,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: s('aiLanguage')),
                  items: [
                    DropdownMenuItem(value: '', child: Text(s('original'))),
                    ...media.languages.entries.map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ),
                  ],
                  onChanged: (v) => setState(() => c.audioLanguage = v!),
                ),
              ],
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s('danmaku')),
              value: c.settings.danmaku,
              onChanged: (v) {
                c.settings.danmaku = v!;
                c.saveSettings();
              },
            ),
          ],
          ExpansionTile(
            key: const PageStorageKey('download-attachments'),
            tilePadding: EdgeInsets.zero,
            title: Text(s('attachments')),
            subtitle: Text(
              [
                if (c.settings.autoCover) s('autoCover'),
                if (c.settings.nfo) s('nfo'),
                if (!c.settings.autoCover && !c.settings.nfo)
                  s('attachmentsHint'),
              ].join(' · '),
            ),
            children: [
              CheckboxListTile(
                title: Text(s('autoCover')),
                value: c.settings.autoCover,
                onChanged: (v) {
                  c.settings.autoCover = v!;
                  c.saveSettings();
                },
              ),
              CheckboxListTile(
                title: Text(s('nfo')),
                value: c.settings.nfo,
                onChanged: (v) {
                  c.settings.nfo = v!;
                  c.saveSettings();
                },
              ),
            ],
          ),
          const Divider(height: 28),
          Text(s('directory'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(
            kIsWeb
                ? s('browserDownload')
                : c.settings.directory.startsWith('content://')
                ? s('systemFolder')
                : c.settings.directory,
          ),
          if (!kIsWeb)
            TextButton.icon(
              onPressed: c.busy
                  ? null
                  : () => c.perform(() async {
                      final dir = await platform.chooseDirectory();
                      if (dir != null) {
                        c.settings.directory = dir;
                        await c.saveSettings();
                      }
                    }),
              icon: const Icon(Icons.folder_open),
              label: Text(s('chooseDirectory')),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s('flatDirectory')),
            value: c.settings.flatDirectory,
            onChanged: (v) {
              c.settings.flatDirectory = v!;
              c.saveSettings();
            },
          ),
          if (c.selected.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              s('filenamePreview'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SelectableText(
              '${c.settings.flatDirectory ? '' : '${c.info!.episodes[c.selected.first].folderName}/'}${c.info!.episodes[c.selected.first].filename(limit: c.settings.limitTitle)}.${c.settings.onlyDanmaku
                  ? 'ass'
                  : c.settings.onlyAudio
                  ? (c.specialAudio == 'flac' ? 'flac' : 'm4a')
                  : 'mp4'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (c.settings.autoCover)
              Text(
                '${c.info!.episodes[c.selected.first].filename(limit: c.settings.limitTitle)}-poster · ${s('coverFormat')}',
              ),
            if (c.settings.nfo)
              Text(
                '${c.info!.episodes[c.selected.first].filename(limit: c.settings.limitTitle)}.nfo',
              ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('enqueue'),
              onPressed:
                  c.busy ||
                      c.selected.isEmpty ||
                      (media == null && !c.settings.onlyDanmaku)
                  ? null
                  : c.enqueue,
              icon: const Icon(Icons.download_rounded),
              label: Text('${s('submit')} (${c.selected.length})'),
            ),
          ),
        ],
      ),
    );
  }
}
