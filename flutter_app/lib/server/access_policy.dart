import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// An operator-generated random key grants access to a browser's own workspace.
/// HTTPS terminates at a local reverse proxy; forwarded headers are not trusted.
class AccessPolicy {
  AccessPolicy({
    required String key,
    this.publicOrigin,
    this.lifetime = const Duration(hours: 12),
    DateTime Function()? now,
  }) : fingerprint = sha256.convert(utf8.encode(key)).toString(),
       now = now ?? DateTime.now {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw ArgumentError('Access key must contain 32 random bytes as hex');
    }
    if (lifetime <= Duration.zero || lifetime > const Duration(hours: 24)) {
      throw ArgumentError(
        'Access lifetime must be positive and at most 24 hours',
      );
    }
    if (publicOrigin != null &&
        (publicOrigin!.scheme != 'https' ||
            publicOrigin!.host.isEmpty ||
            publicOrigin!.userInfo.isNotEmpty ||
            publicOrigin!.hasQuery ||
            publicOrigin!.hasFragment ||
            !['', '/'].contains(publicOrigin!.path))) {
      throw ArgumentError(
        'Public origin must be an HTTPS origin without a path',
      );
    }
  }

  final String fingerprint;
  final Uri? publicOrigin;
  final Duration lifetime;
  final DateTime Function() now;
  bool get secure => publicOrigin != null;

  bool accepts(Object? supplied) {
    if (supplied is! String || supplied.length > 128) return false;
    final candidate = sha256.convert(utf8.encode(supplied)).toString();
    var difference = 0;
    for (var i = 0; i < fingerprint.length; i++) {
      difference |= candidate.codeUnitAt(i) ^ fingerprint.codeUnitAt(i);
    }
    return difference == 0;
  }

  static Future<void> generateKey(String path) async {
    final file = File(path);
    await file.create(exclusive: true);
    // Restrict permissions before writing any secret bytes.
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) throw StateError('Cannot protect access key');
    }
    final random = Random.secure();
    final key = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await file.writeAsString('$key\n', flush: true);
  }

  static Future<AccessPolicy> load({
    required String keyFile,
    required String webRoot,
    String? publicOrigin,
  }) async {
    final file = File(keyFile);
    final realKey = await file.resolveSymbolicLinks();
    final realWeb = await Directory(webRoot).resolveSymbolicLinks();
    if (realKey == realWeb || p.isWithin(realWeb, realKey)) {
      throw ArgumentError(
        'Access key must be outside the static web directory',
      );
    }
    final stat = await file.stat();
    if (stat.size > 128 || (!Platform.isWindows && stat.mode & 0x3f != 0)) {
      throw ArgumentError('Access key must be a private, small file');
    }
    return AccessPolicy(
      key: (await file.readAsString()).trim(),
      publicOrigin: publicOrigin == null ? null : Uri.parse(publicOrigin),
    );
  }
}
