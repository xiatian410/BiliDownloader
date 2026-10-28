import 'download_job.dart';

/// Keeps the platform alive for the existing queue; never creates another worker.
abstract class ExecutionHost {
  void Function(String? reason)? onPause;
  String language = 'zh';
  Future<void> start();
  void update(List<DownloadJob> jobs, {bool hasWorkers = false});
  Future<void> stop();
}
