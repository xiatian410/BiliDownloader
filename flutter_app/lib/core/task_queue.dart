import 'package:flutter/foundation.dart';

import 'download_job.dart';
import 'models.dart';
import 'state_store.dart';

/// The UI operates on a task queue; execution belongs to the native process or
/// the remote service, never to an individual page.
abstract class TaskQueue extends ChangeNotifier {
  List<DownloadJob> get jobs;
  int get maxConcurrent;
  int get maxSupportedConcurrent => 8;
  bool get isRemote => false;
  bool get connected => true;
  AppFailure? get connectionError => null;
  AppFailure? get persistenceError => null;
  bool get recoveredHistory => false;
  void setLanguage(String language) {}
  Future<void> restore(StateStore store) =>
      Future.error(UnsupportedError('This queue has no local history store'));
  Future<void> reconnect({bool force = false}) async {}
  Future<void> add(Iterable<DownloadJob> additions);
  Future<void> setConcurrency(int value);
  void pause(DownloadJob job);
  void resume(DownloadJob job);
  Future<void> clearCompleted({Iterable<DownloadJob>? only});
  Future<void> close();
}
