import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'state_store.dart';

/// Two checksummed generations keep the previous state intact during replacement.
/// A single writer owns a store; callers serialize snapshots through [write].
class FileStateStore implements StateStore {
  FileStateStore(this.path, {this.beforeReplace});
  final String path;
  final Future<void> Function(File temporary)? beforeReplace;
  int _generation = 0;
  int _slot = 0;
  bool _loaded = false;
  bool _corrupt = false;
  bool _closed = false;
  Future<void>? _closing;
  RandomAccessFile? _lock;
  Future<void> _tail = Future.value();

  @override
  Future<StateSnapshot> read() async {
    if (_closed) throw const AppFailure('historyNotReady');
    await _tail;
    if (_lock == null) {
      final RandomAccessFile lock;
      try {
        await File(path).parent.create(recursive: true);
        lock = await File('$path.lock').open(mode: FileMode.append);
      } on FileSystemException {
        throw const AppFailure('historyReadFailed');
      }
      try {
        await lock.lock(FileLock.exclusive);
        _lock = lock;
      } catch (_) {
        await lock.close();
        throw const AppFailure('historyInUse');
      }
    }
    final valid = <(int, int, Map<String, dynamic>)>[];
    var invalid = 0;
    for (var slot = 0; slot < 2; slot++) {
      final file = File('$path.$slot.json');
      try {
        final envelope = jsonDecode(await file.readAsString()) as Map;
        final payload = envelope['payload'] as String;
        if (envelope['version'] != 1 ||
            envelope['checksum'] !=
                sha256.convert(utf8.encode(payload)).toString()) {
          throw const FormatException('State checksum mismatch');
        }
        final data = Map<String, dynamic>.from(jsonDecode(payload));
        final generation = envelope['generation'] as int;
        if (generation < 1) throw const FormatException('Invalid generation');
        valid.add((generation, slot, data));
      } on FileSystemException catch (e) {
        final code = e.osError?.errorCode;
        if (code == 2 || (Platform.isWindows && code == 3)) continue;
        throw const AppFailure('historyReadFailed');
      } catch (_) {
        invalid++;
      }
    }
    _loaded = true;
    if (valid.isEmpty && invalid != 0) {
      _corrupt = true;
      throw const AppFailure('historyCorrupt');
    }
    if (valid.isEmpty) {
      _corrupt = false;
      return const StateSnapshot({});
    }
    valid.sort((a, b) => b.$1.compareTo(a.$1));
    _generation = valid.first.$1;
    _slot = valid.first.$2;
    _corrupt = false;
    return StateSnapshot(valid.first.$3, recovered: invalid != 0);
  }

  @override
  Future<void> write(Map<String, dynamic> data) {
    if (_closed) return Future.error(const AppFailure('historyNotReady'));
    // Encode at invocation, so later mutations cannot alter an enqueued snapshot.
    final payload = jsonEncode(data);
    final operation = _tail.then((_) async {
      if (!_loaded) throw const AppFailure('historyNotReady');
      if (_corrupt) throw const AppFailure('historyCorrupt');
      final nextSlot = 1 - _slot;
      final target = File('$path.$nextSlot.json');
      final temporary = File('${target.path}.tmp');
      try {
        await target.parent.create(recursive: true);
        await temporary.writeAsString(
          jsonEncode({
            'version': 1,
            'generation': _generation + 1,
            'checksum': sha256.convert(utf8.encode(payload)).toString(),
            'payload': payload,
          }),
          flush: true,
        );
        await beforeReplace?.call(temporary);
        await temporary.rename(target.path);
        _generation++;
        _slot = nextSlot;
      } catch (e) {
        if (e is AppFailure) rethrow;
        throw const AppFailure('historyWriteFailed');
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    await _tail;
    final lock = _lock;
    _lock = null;
    if (lock != null) {
      try {
        await lock.unlock();
      } finally {
        await lock.close();
      }
    }
  }
}
