import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../l10n/strings.dart';
import 'widgets.dart';

class SubtitleOptions extends StatelessWidget {
  const SubtitleOptions({
    super.key,
    required this.controller,
    this.preview = true,
  });
  final AppController controller;
  final bool preview;
  @override
  Widget build(BuildContext context) {
    final c = controller, s = Strings.of(context);
    final choices = <String, String>{
      'off': s('subtitlesOff'),
      'all': s('allSubtitleLanguages'),
    };
    for (final track in c.subtitlePreview) {
      choices.putIfAbsent(
        track.language,
        () =>
            '${track.label} [${track.language}]'
            '${track.automatic ? ' · ${s('automaticSubtitle')}' : ''}',
      );
    }
    choices.putIfAbsent(c.settings.subtitles, () => c.settings.subtitles);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey('subtitle-mode-${c.settings.subtitles}'),
            initialValue: c.settings.subtitles,
            isExpanded: true,
            itemHeight: null,
            decoration: InputDecoration(labelText: s('subtitles')),
            items: choices.entries
                .map(
                  (e) => DropdownMenuItem(
                    value: e.key,
                    child: Text(
                      e.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) {
                c.settings.subtitles = value;
                c.saveSettings();
              }
            },
          ),
          const SizedBox(height: 8),
          Text(
            s('subtitleSelectionHint'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (preview) ...[
            TextButton.icon(
              key: const ValueKey('subtitle-preview'),
              onPressed: c.busy || c.selected.isEmpty ? null : c.loadSubtitles,
              icon: const Icon(Icons.closed_caption_outlined),
              label: Text(s('previewSubtitles')),
            ),
            if (c.subtitlePreviewEpisode != null)
              Text(
                '${s('subtitlePreview')}: ${c.subtitlePreviewEpisode!.title} · ${c.subtitlePreviewEpisode!.name}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (c.subtitlePreviewError != null)
              StatusBanner(
                '${s(c.subtitlePreviewError!.key)} ${c.subtitlePreviewError!.detail}',
                error: true,
              ),
            if (c.subtitlePreviewLoaded && c.subtitlePreview.isEmpty)
              Text(s('noSubtitles')),
          ],
        ],
      ),
    );
  }
}
