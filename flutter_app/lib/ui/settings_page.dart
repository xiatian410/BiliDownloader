import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../l10n/strings.dart';
import '../platform/platform.dart' as platform;
import 'login_dialog.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});
  final AppController controller;
  AppController get c => controller;
  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    Widget toggle(String key, bool value, void Function(bool) change) =>
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(s(key)),
          value: value,
          onChanged: (v) {
            change(v);
            c.saveSettings();
          },
        );
    Widget select<T>(
      String key,
      T value,
      Map<T, String> items,
      void Function(T) change,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: s(key)),
        items: items.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: (v) {
          change(v as T);
          c.saveSettings(updateConcurrency: key == 'concurrency');
        },
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        PageHeading(s('settings'), s('settingsSubtitle')),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s('account'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Chip(
                    avatar: Icon(
                      c.loggedIn
                          ? Icons.verified_user_outlined
                          : Icons.person_outline,
                    ),
                    label: Text(s(c.loggedIn ? 'loggedIn' : 'loggedOut')),
                  ),
                  FilledButton(
                    onPressed: c.busy
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            builder: (_) => LoginDialog(controller: c),
                          ),
                    child: Text(s('login')),
                  ),
                  if (c.loggedIn)
                    TextButton(
                      onPressed: c.busy ? null : c.logout,
                      child: Text(s('logout')),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(s('membership')),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s('appearance'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
              select('theme', c.settings.theme, {
                'system': s('system'),
                'light': s('light'),
                'dark': s('dark'),
              }, (v) => c.settings.theme = v),
              select('language', c.settings.locale, {
                'zh': '简体中文',
                'en': 'English',
              }, (v) => c.settings.locale = v),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s('downloadDefaults'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
              ListenableBuilder(
                listenable: c.queue,
                builder: (context, _) =>
                    select('concurrency', c.queue.maxConcurrent, {
                      for (var i = 1; i <= c.queue.maxSupportedConcurrent; i++)
                        i: '$i',
                    }, (v) => c.settings.concurrency = v),
              ),
              select('codec', c.settings.codec, {
                7: 'H.264 / AVC',
                12: 'H.265 / HEVC',
                13: 'AV1',
              }, (v) => c.settings.codec = v),
              toggle('onlyAudio', c.settings.onlyAudio, (v) {
                c.settings.onlyAudio = v;
                if (v) c.settings.onlyDanmaku = false;
              }),
              toggle(
                'reserveAudio',
                c.settings.reserveAudio,
                (v) => c.settings.reserveAudio = v,
              ),
              toggle(
                'danmaku',
                c.settings.danmaku,
                (v) => c.settings.danmaku = v,
              ),
              toggle('ultra', c.settings.ultra, (v) => c.settings.ultra = v),
              toggle('dolby', c.settings.dolby, (v) => c.settings.dolby = v),
              if (!kIsWeb)
                toggle(
                  'clipboard',
                  c.settings.clipboard,
                  (v) => c.settings.clipboard = v,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s('directory'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              SelectableText(
                kIsWeb
                    ? s('browserDownload')
                    : c.settings.directory.startsWith('content://')
                    ? s('systemFolder')
                    : c.settings.directory,
              ),
              if (!kIsWeb)
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => c.perform(() async {
                        final dir = await platform.chooseDirectory();
                        if (dir != null) {
                          c.settings.directory = dir;
                          await c.saveSettings();
                        }
                      }),
                      icon: const Icon(Icons.folder_open),
                      label: Text(s('chooseDirectory')),
                    ),
                    TextButton(
                      onPressed: () => c.perform(
                        () => platform.openDirectory(c.settings.directory),
                      ),
                      child: Text(s('openDirectory')),
                    ),
                  ],
                ),
              toggle(
                'flatDirectory',
                c.settings.flatDirectory,
                (v) => c.settings.flatDirectory = v,
              ),
              toggle(
                'limitTitle',
                c.settings.limitTitle,
                (v) => c.settings.limitTitle = v,
              ),
              if (platform.isAndroid) Text(s('androidStorage')),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'BiliDownloader 2.0',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(s('aboutText')),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => launchUrl(
                      Uri.parse('https://github.com/xiatian410/BiliDownloader'),
                    ),
                    child: Text(s('project')),
                  ),
                  TextButton(
                    onPressed: () => showLicensePage(
                      context: context,
                      applicationName: 'BiliDownloader',
                      applicationVersion: '2.0.0',
                      applicationLegalese:
                          'Original project © 2021–2026 Majjcom · MIT',
                    ),
                    child: Text(s('licenses')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
