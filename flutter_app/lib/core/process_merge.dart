import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'media_merge.dart';
import 'models.dart';

Future<void> mergeWithProcess(
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
  Timer? forceStop;
  try {
    final process = await Process.start('ffmpeg', [
      '-nostdin',
      '-nostats',
      '-progress',
      'pipe:1',
      ...arguments,
    ]);
    var exited = false;
    watch.attachStop(() async {
      if (exited) return;
      process.kill();
      forceStop = Timer(const Duration(seconds: 5), () {
        if (!exited) process.kill(ProcessSignal.sigkill);
      });
    });
    var milliseconds = 0, bytes = 0, frames = 0;
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final split = line.indexOf('=');
          if (split < 0) return;
          final key = line.substring(0, split),
              value = int.tryParse(line.substring(split + 1));
          if (value == null) return;
          if (key == 'out_time_us') milliseconds = value ~/ 1000;
          if (key == 'total_size') bytes = value;
          if (key == 'frame') frames = value;
          watch.progress(
            MergeProgress(
              milliseconds: milliseconds,
              bytes: bytes,
              frames: frames,
            ),
          );
        });
    // Drain stderr without retaining unbounded logs in memory.
    final errors = process.stderr.listen((_) {});
    try {
      final code = await process.exitCode;
      exited = true;
      watch.checkExit(code);
    } finally {
      exited = true;
      forceStop?.cancel();
      await output.cancel();
      await errors.cancel();
    }
  } on ProcessException {
    throw const AppFailure('mergeUnavailable');
  } finally {
    forceStop?.cancel();
    watch.close();
  }
}
