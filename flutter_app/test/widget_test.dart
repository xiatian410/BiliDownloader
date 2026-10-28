import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bili_downloader/app.dart';
import 'package:bili_downloader/app_controller.dart';
import 'package:bili_downloader/core/download_queue.dart';
import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/core/remote_api.dart';
import 'package:bili_downloader/ui/widgets.dart';

import 'support.dart';

class WizardApi extends FixtureApi {
  @override
  Future<VideoInfo> resolve(VideoId id, {CancelToken? cancel}) async =>
      FixtureApi.video;
  @override
  Future<PlayableMedia> play(
    Episode episode,
    DownloadOptions options, {
    CancelToken? cancel,
  }) async => FixtureApi.playable;
}

class LockedStore extends MemoryStore {
  final pendingCookies = Completer<Map<String, String>>();
  @override
  Future<Map<String, String>> readCookies() => pendingCookies.future;
}

void main() {
  setUpAll(() async {
    final font = FontLoader('HarmonyOS Sans SC')
      ..addFont(rootBundle.load('assets/HarmonyOS_Sans_SC_Regular.ttf'));
    await font.load();
  });
  testWidgets('status messages are announced as readable live regions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      const message = '与服务连接中断，可点击继续重新连接。';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: StatusBanner(message, error: true)),
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel(message)),
        matchesSemantics(label: message, isLiveRegion: true),
      );
    } finally {
      semantics.dispose();
    }
  });
  testWidgets(
    'service gate fits large text and hides the workspace from accessibility',
    (tester) async {
      final api = RemoteBiliApi()
        ..serviceLocked = true
        ..requiresServiceKey = true;
      final c =
          AppController(
              api: api,
              queue: DownloadQueue(CompletedRunner()),
              store: MemoryStore(),
            )
            ..initializing = false
            ..info = FixtureApi.video;
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        for (final width in [320.0, 360.0, 900.0]) {
          for (final locale in ['zh', 'en']) {
            c.settings.locale = locale;
            await tester.binding.setSurfaceSize(Size(width, 800));
            await tester.pumpWidget(BiliDownloaderApp(controller: c));
            c.clearError();
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('service-access-key')),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('video-input')), findsNothing);
            expect(
              find.bySemanticsLabel(RegExp('测试视频 / Test video')),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
          }
        }
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets('locked keyring does not block first frame or late login', (
    tester,
  ) async {
    final store = LockedStore();
    final c = AppController(
      api: WizardApi(),
      queue: DownloadQueue(CompletedRunner()),
      store: store,
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(BiliDownloaderApp(controller: c));
    expect(find.text('BiliDownloader'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final initialization = c.initialize();
    await tester.pump();
    await tester.pump(AppController.storageTimeout);
    await initialization;
    await tester.pumpAndSettle();
    expect(c.notice, 'secureStorageError');
    expect(find.byKey(const ValueKey('video-input')), findsOneWidget);
    await c.acceptLogin({'SESSDATA': 'new-session'});
    store.pendingCookies.complete({'SESSDATA': 'stale-session'});
    await tester.pump();
    expect(c.api.cookies['SESSDATA'], 'new-session');
    expect(tester.takeException(), isNull);
  });

  testWidgets('service locking retains a draft and closes private dialogs', (
    tester,
  ) async {
    final api = RemoteBiliApi()
      ..requiresServiceKey = true
      ..workspaceId = List.filled(64, 'a').join();
    final c = AppController(
      api: api,
      queue: DownloadQueue(CompletedRunner()),
      store: MemoryStore(),
    )..initializing = false;
    addTearDown(c.dispose);
    await tester.pumpWidget(BiliDownloaderApp(controller: c));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('video-input')), 'av2');
    unawaited(
      showDialog<void>(
        context: tester.element(find.byKey(const ValueKey('video-input'))),
        builder: (_) => const AlertDialog(title: Text('Private QR dialog')),
      ),
    );
    await tester.pumpAndSettle();
    api.requireServiceAccess();
    await tester.pumpAndSettle();
    expect(find.text('Private QR dialog'), findsNothing);
    expect(find.byKey(const ValueKey('video-input')), findsNothing);
    api.serviceLocked = false;
    c.clearError();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('video-input')))
          .controller!
          .text,
      'av2',
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 760.0]) {
    testWidgets('parse select configure and enqueue at width $width', (
      tester,
    ) async {
      tester.view.reset();
      await tester.binding.setSurfaceSize(Size(width, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = AppController(
        api: WizardApi(),
        queue: DownloadQueue(CompletedRunner()),
        store: MemoryStore(),
      );
      await c.initialize();
      addTearDown(c.dispose);
      await tester.pumpWidget(BiliDownloaderApp(controller: c));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-input')),
        'BV1xx411c7mD',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('parse-input')));
      await tester.pumpAndSettle();
      expect(find.text('测试视频 / Test video'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('episode-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('episode-1')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('load-options')),
        350,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('new-download-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('load-options')));
      await tester.pumpAndSettle();
      expect(find.text('1080P'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('enqueue')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('enqueue')));
      await tester.pumpAndSettle();
      expect(c.queue.jobs.length, 1);
      expect(c.queue.jobs.single.state, JobState.completed);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pumpAndSettle();
      c.settings.locale = 'en';
      await c.saveSettings();
      await tester.pumpAndSettle();
      expect(find.text('Sign in with QR'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [320.0, 360.0, 600.0, 900.0, 1440.0]) {
    for (final theme in ['light', 'dark']) {
      testWidgets('responsive $width $theme at 200 percent font', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 760));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final c = AppController(
          api: WizardApi(),
          queue: DownloadQueue(CompletedRunner()),
          store: MemoryStore(),
        );
        addTearDown(c.dispose);
        await c.initialize();
        c.settings.theme = theme;
        c.settings.locale = theme == 'dark' ? 'en' : 'zh';
        c.settings.autoCover = true;
        c.settings.nfo = true;
        await tester.pumpWidget(BiliDownloaderApp(controller: c));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('tab-2')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('tab-0')));
        await c.resolve('BV1xx411c7mD');
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('load-options')),
          350,
          scrollable: find
              .descendant(
                of: find.byKey(const PageStorageKey('new-download-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await c.loadOptions();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byKey(const PageStorageKey('download-attachments')),
          350,
          scrollable: find
              .descendant(
                of: find.byKey(const PageStorageKey('new-download-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.text(theme == 'dark' ? 'Attachments' : '附加文件'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
