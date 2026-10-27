import 'package:bili_downloader/app_controller.dart';
import 'package:bili_downloader/core/bili_api.dart';
import 'package:bili_downloader/core/download_job.dart';
import 'package:bili_downloader/core/models.dart';

class MemoryStore implements AppStore {
  MemoryStore({this.directory = '/tmp/bili-test'});
  final String directory;
  Map<String, dynamic>? settings;
  @override
  Future<Map<String, dynamic>> readSettings() async =>
      settings ?? {'directory': directory};
  @override
  Future<void> writeSettings(Map<String, dynamic> data) async {
    settings = data;
  }

  @override
  Future<Map<String, String>> readCookies() async => {};
  @override
  Future<void> writeCookies(Map<String, String> cookies) async {}
}

class CompletedRunner implements DownloadRunner {
  @override
  Future<void> run(DownloadJob job, void Function() changed) async {
    job.received = job.total = 100;
  }

  @override
  void dispose() {}
}

class FixtureApi extends BiliApi {
  FixtureApi({super.dio});
  static const video = VideoInfo(
    title: '测试视频 / Test video',
    description: 'Video description',
    cover: '',
    episodes: [
      Episode(
        cid: 1,
        number: 1,
        name: '第一集',
        title: 'Test video',
        bvid: 'BV1xx411c7mD',
      ),
      Episode(
        cid: 2,
        number: 2,
        name: '第二集',
        title: 'Test video',
        bvid: 'BV1xx411c7mD',
      ),
    ],
  );
  static const playable = PlayableMedia(
    qualities: [Quality(80, '1080P')],
    video: [MediaStream(url: 'https://example.test/v', quality: 80, codec: 7)],
    audio: [MediaStream(url: 'https://example.test/a')],
  );
}
