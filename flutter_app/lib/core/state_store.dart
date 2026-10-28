class StateSnapshot {
  const StateSnapshot(this.data, {this.recovered = false});
  final Map<String, dynamic> data;
  final bool recovered;
}

abstract interface class StateStore {
  Future<StateSnapshot> read();
  Future<void> write(Map<String, dynamic> data);
  Future<void> close();
}
