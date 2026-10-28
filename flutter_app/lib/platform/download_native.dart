import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

import '../core/bili_api.dart';
import '../core/download_job.dart';
import '../core/io_download_runner.dart';
import '../core/models.dart';
import 'platform_native.dart' as platform;
export '../core/io_download_runner.dart';

DownloadRunner createDownloadRunner(BiliApi api) => NativeDownloadRunner(
  api,
  merge: mergeWithFfmpeg,
  workingDirectory: platform.workingDirectory,
  publishFile: platform.publishStagedFile,
);

Future<void> mergeWithFfmpeg(List<String> arguments) async {
  final session = await FFmpegKit.executeWithArguments(arguments);
  if (!ReturnCode.isSuccess(await session.getReturnCode())) {
    throw const AppFailure('mergeFailed');
  }
}
