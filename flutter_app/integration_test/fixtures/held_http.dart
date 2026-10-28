import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Test-only stream that holds the body after a genuinely delivered first chunk.
class HeldHttpFixture {
  HeldHttpFixture._(this._server, this._bytes) {
    _server.listen(_respond);
  }
  final HttpServer _server;
  final List<int> _bytes;
  final _release = Completer<void>();
  bool rangeResumed = false;
  String get url => 'http://127.0.0.1:${_server.port}/fixture.mp4';

  static Future<HeldHttpFixture> open(List<int> bytes) async =>
      HeldHttpFixture._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        bytes,
      );

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Future<void> close() async {
    release();
    await _server.close(force: true);
  }

  Future<void> _respond(HttpRequest request) async {
    try {
      final match = RegExp(r'^bytes=(\d+)-(\d*)$')
          .firstMatch(request.headers.value('range') ?? '');
      final start = match == null ? 0 : int.parse(match[1]!);
      final end = match == null || match[2]!.isEmpty
          ? _bytes.length - 1
          : int.parse(match[2]!);
      if (start > 0) rangeResumed = true;
      // flush() alone retains a small body in HttpResponse's output buffer.
      request.response.bufferOutput = false;
      request.response.headers.set('etag', '"fixture-v1"');
      request.response.contentLength = end - start + 1;
      if (match != null) {
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/${_bytes.length}',
        );
      }
      final split = min(end + 1, start + 4096);
      request.response.add(_bytes.sublist(start, split));
      await request.response.flush();
      if (end > start) {
        await _release.future.timeout(const Duration(seconds: 35));
      }
      if (split <= end) request.response.add(_bytes.sublist(split, end + 1));
      await request.response.close();
    } catch (_) {
      // A paused client deliberately closes its connection.
      request.response.close().ignore();
    }
  }
}
