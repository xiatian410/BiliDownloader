import 'dart:io';

import 'package:bili_downloader/core/media_merge.dart';
import 'package:bili_downloader/core/process_merge.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('only advancing media progress resets the inactivity deadline', (
    tester,
  ) async {
    var stops = 0;
    final reasons = <String>[];
    final watch = MergeWatch(
      idleTimeout: const Duration(seconds: 2),
      onStopping: reasons.add,
    );
    watch.attachStop(() async {
      stops++;
    });
    await tester.pump(const Duration(seconds: 1));
    watch.progress(const MergeProgress(milliseconds: 1000));
    await tester.pump(const Duration(seconds: 1));
    watch.progress(const MergeProgress(milliseconds: 1000));
    expect(stops, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(stops, 1);
    expect(reasons, ['mergeStalledStopping']);
    expect(
      () => watch.checkExit(255),
      throwsA(isA<AppFailure>().having((e) => e.key, 'key', 'mergeStalled')),
    );
    watch.close();
    await tester.pump(const Duration(minutes: 5));
    expect(stops, 1);
  });

  testWidgets(
    'cancellation before backend setup stops only that execution once',
    (tester) async {
      var stops = 0;
      final cancel = CancelToken();
      final watch = MergeWatch(cancel: cancel);
      cancel.cancel('pause');
      await tester.pump();
      watch.attachStop(() async {
        stops++;
      });
      await tester.pump();
      expect(stops, 1);
      expect(
        () => watch.checkExit(0),
        throwsA(
          isA<DioException>().having(
            (e) => CancelToken.isCancel(e),
            'cancelled',
            true,
          ),
        ),
      );
      watch.close();
      await tester.pump(const Duration(minutes: 5));
      expect(stops, 1);
    },
  );

  testWidgets(
    'slow stop stays visible and successful completion removes timers',
    (tester) async {
      final reasons = <String>[];
      final cancel = CancelToken();
      final watch = MergeWatch(cancel: cancel, onStopping: reasons.add);
      watch.attachStop(() async {});
      cancel.cancel();
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(reasons, ['stoppingMerge', 'mergeStopPending']);
      watch.close();
      final completed = MergeWatch(onStopping: reasons.add);
      completed.checkExit(0);
      completed.close();
      await tester.pump(const Duration(minutes: 3));
      expect(reasons, hasLength(2));
    },
  );

  test(
    'system FFmpeg reports progress and exits on cancellation without stopping its peer',
    () async {
      final cancel = CancelToken();
      var updates = 0;
      final peer = mergeWithProcess([
        '-v',
        'error',
        '-re',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=600',
        '-t',
        '2',
        '-f',
        'null',
        '-',
      ]);
      final stopped = mergeWithProcess(
        [
          '-v',
          'error',
          '-re',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440',
          '-t',
          '4',
          '-f',
          'null',
          '-',
        ],
        cancel: cancel,
        onProgress: (progress) {
          updates++;
          if (progress.milliseconds > 0) cancel.cancel('pause');
        },
      );
      await Future.wait([
        peer,
        expectLater(
          stopped.timeout(const Duration(seconds: 10)),
          throwsA(isA<DioException>()),
        ),
      ]);
      expect(updates, greaterThan(0));
    },
    skip: Platform.isWindows
        ? 'Windows native integration exercises the bundled FFmpeg library.'
        : false,
  );
}
