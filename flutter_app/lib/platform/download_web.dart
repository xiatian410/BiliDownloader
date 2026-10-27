import '../core/bili_api.dart';
import '../core/download_job.dart';
import '../core/models.dart';

DownloadRunner createDownloadRunner(BiliApi api) => _WebRunner();

class _WebRunner implements DownloadRunner {
  @override
  Future<void> run(DownloadJob job, void Function() changed) async =>
      throw const AppFailure('webDownloadUnsupported');
  @override
  void dispose() {}
}
