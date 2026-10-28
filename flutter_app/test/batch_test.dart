import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bili_downloader/app_controller.dart';
import 'package:bili_downloader/core/download_queue.dart';
import 'package:bili_downloader/core/models.dart';

import 'support.dart';

class BatchApi extends FixtureApi {
  final calls = <String>[];
  @override
  Future<VideoInfo> resolve(VideoId id, {CancelToken? cancel}) async {
    calls.add(id.label);
    if (id.value == '2') throw const AppFailure('httpError', '412');
    return VideoInfo(
      title: id.label,
      description: '',
      cover: '',
      episodes: [
        Episode(
          cid: int.parse(id.value),
          aid: int.parse(id.value),
          number: 1,
          name: 'P1',
          title: id.label,
        ),
      ],
    );
  }
}

void main() {
  test(
    'partial batch failure keeps every successful source and reports failures',
    () async {
      final api = BatchApi();
      final c = AppController(
        api: api,
        queue: DownloadQueue(CompletedRunner()),
        store: MemoryStore(),
      );
      addTearDown(c.dispose);
      await c.initialize();
      await c.resolve('av1;av2;av3;av1');
      expect(api.calls, ['AV1', 'AV2', 'AV3']);
      expect(c.info!.episodes.map((e) => e.aid), [1, 3]);
      expect(c.resolveErrors['AV2']!.detail, '412');
      expect(c.selected, {0, 1});
      c.enqueue();
      expect(c.queue.jobs.map((j) => j.episode.aid), [1, 3]);
    },
  );
  test('oversized batch is rejected before making any API request', () async {
    final api = BatchApi();
    final c = AppController(
      api: api,
      queue: DownloadQueue(CompletedRunner()),
      store: MemoryStore(),
    );
    addTearDown(c.dispose);
    await c.resolve(List.generate(101, (i) => 'av${i + 1}').join(';'));
    expect(c.error!.key, 'invalidBatch');
    expect(api.calls, isEmpty);
  });
}
