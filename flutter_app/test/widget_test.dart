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
      });
    }
  }
}
