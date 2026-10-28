import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_controller.dart';
import 'l10n/strings.dart';
import 'ui/app_theme.dart';
import 'ui/downloads_page.dart';
import 'ui/new_download_page.dart';
import 'ui/settings_page.dart';
import 'ui/widgets.dart';

class BiliDownloaderApp extends StatelessWidget {
  const BiliDownloaderApp({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => MaterialApp(
      title: 'BiliDownloader',
      debugShowCheckedModeBanner: false,
      locale: Locale(controller.settings.locale),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: switch (controller.settings.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: controller.initializing
          ? const Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('BiliDownloader'),
                    SizedBox(height: 24),
                    CircularProgressIndicator(),
                  ],
                ),
              ),
            )
          : _Workspace(controller: controller),
    ),
  );
}

class _Workspace extends StatelessWidget {
  const _Workspace({required this.controller});
  final AppController controller;
  static const icons = [
    Icons.add_circle_outline,
    Icons.downloading_outlined,
    Icons.tune_rounded,
  ];
  static const keys = ['input', 'downloads', 'settings'];
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = Strings.of(context);
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, size) {
        final desktop = size.maxWidth >= 900;
        final rail = size.maxWidth >= 600;
        final content = Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Row(
                children: [
                  if (!desktop) ...[
                    Icon(Icons.play_circle_fill_rounded, color: colors.primary),
                    const SizedBox(width: 8),
                  ],
                  const Expanded(
                    child: Text(
                      'BiliDownloader',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: s('settings'),
                    onPressed: () => c.setTab(2),
                    icon: Icon(
                      c.loggedIn
                          ? Icons.account_circle
                          : Icons.account_circle_outlined,
                    ),
                  ),
                ],
              ),
            ),
            if (c.busy) const LinearProgressIndicator(minHeight: 2),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: StatusBanner(
                  '${s(c.error!.key)} ${c.error!.detail}',
                  error: true,
                  onClose: c.clearError,
                ),
              ),
            if (c.notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: StatusBanner(s(c.notice!)),
              ),
            Expanded(
              child: IndexedStack(
                index: c.tab.clamp(0, 2),
                children: [
                  NewDownloadPage(controller: c),
                  DownloadsPage(controller: c),
                  SettingsPage(controller: c),
                ],
              ),
            ),
          ],
        );
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                if (rail)
                  Container(
                    width: desktop ? 220 : 84,
                    decoration: BoxDecoration(
                      color: colors.surface,
                      border: Border(
                        right: BorderSide(
                          color: colors.outlineVariant.withValues(alpha: .5),
                        ),
                      ),
                    ),
                    child: Column(
                      children: [
                        const SizedBox(height: 28),
                        Icon(
                          Icons.play_circle_fill_rounded,
                          size: 38,
                          color: colors.primary,
                        ),
                        const SizedBox(height: 32),
                        ...List.generate(
                          3,
                          (i) => Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            child: Material(
                              color: c.tab == i
                                  ? colors.primaryContainer
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(16),
                              child: InkWell(
                                key: ValueKey('tab-$i'),
                                borderRadius: BorderRadius.circular(16),
                                onTap: () => c.setTab(i),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Row(
                                    mainAxisAlignment: desktop
                                        ? MainAxisAlignment.start
                                        : MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        icons[i],
                                        color: c.tab == i
                                            ? colors.onPrimaryContainer
                                            : colors.onSurfaceVariant,
                                      ),
                                      if (desktop) ...[
                                        const SizedBox(width: 12),
                                        Expanded(child: Text(s(keys[i]))),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        if (desktop)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              s('workspaceHint'),
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Expanded(child: content),
              ],
            ),
          ),
          bottomNavigationBar: rail
              ? null
              : NavigationBar(
                  selectedIndex: c.tab.clamp(0, 2),
                  onDestinationSelected: c.setTab,
                  height: MediaQuery.textScalerOf(context).scale(14) > 20
                      ? 96
                      : 76,
                  destinations: List.generate(
                    3,
                    (i) => NavigationDestination(
                      key: ValueKey('tab-$i'),
                      icon: Icon(icons[i]),
                      label: s(keys[i]),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
