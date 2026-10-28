import 'dart:async';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';

import '../core/bili_api.dart';
import '../core/download_job.dart';
import '../core/download_queue.dart';
import '../core/io_download_runner.dart';
import 'platform_native.dart' as platform;
export '../core/io_download_runner.dart';

DownloadQueue createDownloadQueue(BiliApi api) =>
    DownloadQueue(createDownloadRunner(api));

DownloadRunner createDownloadRunner(BiliApi api) => NativeDownloadRunner(
  api,
  merge: mergeWithFfmpeg,
  workingDirectory: platform.workingDirectory,
  publishFile: platform.publishStagedFile,
);

Future<void> mergeWithFfmpeg(
  List<String> arguments, {
  CancelToken? cancel,
  void Function(MergeProgress)? onProgress,
  void Function(String)? onStopping,
  Duration? idleTimeout,
}) async {
  if (cancel?.isCancelled ?? false) throw cancel!.cancelError!;
  final watch = MergeWatch(
    cancel: cancel,
    onProgress: onProgress,
    onStopping: onStopping,
    idleTimeout: idleTimeout,
  );
  final complete = Completer<int?>();
  // The plugin can finish before setup returns; attach the error observer first.
  unawaited(
    complete.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
  try {
    final session = await FFmpegKit.executeWithArgumentsAsync(
      arguments,
      (session) async {
        try {
          complete.complete((await session.getReturnCode())?.getValue());
        } catch (error, stack) {
          complete.completeError(error, stack);
        }
      },
      null,
      (stats) => watch.progress(
        MergeProgress(
          milliseconds: stats.getTime(),
          bytes: stats.getSize(),
          frames: stats.getVideoFrameNumber(),
        ),
      ),
    );
    watch.attachStop(session.cancel);
    watch.checkExit(await complete.future);
  } finally {
    watch.close();
  }
}
