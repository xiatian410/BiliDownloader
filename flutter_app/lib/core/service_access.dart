/// Access to the download service is independent of Bilibili sign-in.
abstract class ServiceAccess {
  bool get serviceLocked;
  bool get requiresServiceKey;
  bool get serviceSessionLost;
  String? get workspaceId;
  Stream<void> get accessChanges;
  void rememberWorkspace(String? id);
  Future<void> unlockService(String key, {bool newWorkspace = false});
  Future<void> lockService();
}
