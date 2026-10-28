import 'package:flutter_test/flutter_test.dart';
import 'package:bili_downloader/core/models.dart';
import 'package:bili_downloader/core/wbi.dart';
import 'package:bili_downloader/core/danmaku.dart';
import 'package:bili_downloader/core/decode.dart';

import 'dart:convert';
import 'dart:io';

void main() {
  test(
    'batch IDs retain source order and report duplicates and unknown inputs',
    () {
      final parsed = VideoId.parseMany('av12;BV1gx4y187fX\nep24，av12 invalid');
      expect(parsed.ids.map((id) => id.label), [
        'AV12',
        'BV1gx4y187fX',
        'EP24',
      ]);
      expect(parsed.duplicates, 1);
      expect(parsed.invalid, ['invalid']);
      expect(VideoId.parse('BV1gx4y187fX;BV1Bf421B7XS'), isNull);
    },
  );
  test(
    'truncated titles retain stable media and episode identity in paths',
    () {
      final title = 'A' * 90;
      final a = Episode(
        cid: 1,
        number: 1,
        name: '${title}first',
        title: title,
        bvid: 'BV1gx4y187fX',
      );
      final b = Episode(
        cid: 2,
        number: 1,
        name: '${title}second',
        title: title,
        bvid: 'BV1Bf421B7XS',
      );
      expect(a.folderName, isNot(b.folderName));
      expect(a.filename(), isNot(b.filename()));
    },
  );
  test('available quality excludes advertised formats without streams', () {
    final media = PlayableMedia.fromJson({
      'support_formats': [
        {'quality': 120, 'new_description': '4K'},
        {'quality': 32, 'new_description': '480P'},
      ],
      'dash': {
        'video': [
          {'id': 32, 'base_url': 'https://example.test/v'},
        ],
      },
    });
    expect(media.availableQualities.map((q) => q.label), ['480P']);
  });
  test('comment payload accepts plain XML and raw DEFLATE', () {
    const xml = '<i><d p="1,1,25,16777215">弹幕</d></i>';
    expect(decodeDanmaku(utf8.encode(xml)), xml);
    expect(
      decodeDanmaku(ZLibEncoder(raw: true).convert(utf8.encode(xml))),
      xml,
    );
  });
  test('IDs preserve BV case and reject malformed or ambiguous input', () {
    expect(
      VideoId.parse('https://www.bilibili.com/video/BV1xx411c7mD?p=1')?.label,
      'BV1xx411c7mD',
    );
    expect(VideoId.parse('bv1xx411c7mD')?.label, 'BV1xx411c7mD');
    for (final value in ['av12', 'md42', 'ep123']) {
      expect(VideoId.parse(value), isNotNull);
    }
    for (final value in [
      'abc',
      'BV1xx411c7mDextra',
      'av0',
      'av12foo',
      'av12 ep24',
    ]) {
      expect(VideoId.parse(value), isNull, reason: value);
    }
  });
  test('selection ranges validate before changing selection', () {
    expect(parseSelection('1,3-5', 5), {0, 2, 3, 4});
    expect(parseSelection('1，2', 5), {0, 1});
    for (final value in ['0', '3-2', '1-6', 'a', '1,,2']) {
      expect(() => parseSelection(value, 5), throwsA(isA<AppFailure>()));
    }
  });
  test('WBI agrees with the original Python signature algorithm', () {
    final original = {'foo': 114, 'bar': 514, 'baz': 1919810};
    final signed = signWbi(
      original,
      '7cd084941338484aae1ad9425b84077c',
      '4932caff0ff746eab6f01bf08b70ac45',
      timestamp: 1702204169,
    );
    expect(signed['w_rid'], '6149fdadf571698ca7e6a567265cd0ee');
    expect(original, {'foo': 114, 'bar': 514, 'baz': 1919810});
  });
  test('filenames cannot escape the destination or use Windows devices', () {
    expect(safeFilename('../../video'), '.._.._video');
    expect(safeFilename('CON'), '_CON');
    expect(safeFilename('NUL.mp4'), '_NUL.mp4');
    expect(safeFilename('..'), '_');
    expect(safeFilename('中' * 100).runes.length, 80);
  });
  test('DASH maps optional null audio, snake-case URLs and special tracks', () {
    final media = PlayableMedia.fromJson({
      'support_formats': [
        {'quality': 80, 'new_description': '1080P'},
      ],
      'dash': {
        'video': [
          {'id': 80, 'codecid': 7, 'base_url': 'https://example.test/v'},
        ],
        'audio': null,
        'flac': {
          'audio': {'baseUrl': 'https://example.test/a'},
        },
      },
    });
    expect(media.selectVideo(80, 7).url, endsWith('/v'));
    expect(media.selectAudio(''), isNull);
    expect(media.selectAudio('flac')!.extension, 'flac');
    expect(() => media.selectAudio('dolby'), throwsA(isA<AppFailure>()));
    expect(() => media.selectVideo(64, 7), throwsA(isA<AppFailure>()));
  });
  test(
    'quality is a maximum and codec is preferred without altering options',
    () {
      const media = PlayableMedia(
        qualities: [],
        video: [
          MediaStream(url: '4k', quality: 120, codec: 7),
          MediaStream(url: '1080-av1', quality: 80, codec: 13),
          MediaStream(url: '1080-avc', quality: 80, codec: 7),
        ],
        audio: [],
      );
      expect(media.selectVideo(116, 13).url, '1080-av1');
      expect(media.selectVideo(80, 12).quality, 80);
    },
  );
  test('MP4 and API errors are not mistaken for empty DASH', () {
    final media = PlayableMedia.fromJson({
      'video_info': {
        'quality': 80,
        'durl': [
          {'url': 'https://example.test/video'},
        ],
      },
    });
    expect(media.mp4, true);
    expect(media.video.single.quality, 80);
    expect(() => PlayableMedia.fromJson({}), throwsA(isA<AppFailure>()));
    expect(
      () => PlayableMedia.fromJson({
        'durl': [
          {'url': 'a'},
          {'url': 'b'},
        ],
      }),
      throwsA(isA<AppFailure>()),
    );
  });
  test(
    'ASS conversion escapes override tags and positions normal comments',
    () {
      final ass = danmakuToAss(
        '<i><d p="1.2,1,25,16711680">hello {tag}</d><d p="2,5,25,16777215">top</d></i>',
      );
      expect(ass, contains('0:00:01.20'));
      expect(ass, contains(r'\move('));
      expect(ass, contains('｛tag｝'));
      expect(ass, contains(r'\c&H0000ff&'));
    },
  );
}
