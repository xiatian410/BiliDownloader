enum VideoKind { bv, av, md, ep }

class AppFailure implements Exception {
  const AppFailure(this.key, [this.detail = '']);
  final String key;
  final String detail;
  @override
  String toString() => detail.isEmpty ? key : '$key: $detail';
}

class VideoId {
  const VideoId(this.kind, this.value);
  final VideoKind kind;
  final String value;
  String get label => '${kind.name.toUpperCase()}$value';

  static VideoId? parse(String input) {
    // Preserve the case of the BV payload; it is case sensitive.
    final bv = RegExp(
      r'(?<![A-Za-z0-9])(?:BV|bv)([A-Za-z0-9]{10})(?![A-Za-z0-9])',
    ).firstMatch(input);
    if (bv != null) return VideoId(VideoKind.bv, bv[1]!);
    final matches = RegExp(
      r'(?<![A-Za-z0-9])(av|md|ep)([1-9][0-9]*)(?![A-Za-z0-9])',
      caseSensitive: false,
    ).allMatches(input).toList();
    if (matches.length != 1) return null;
    final m = matches.single;
    return VideoId(VideoKind.values.byName(m[1]!.toLowerCase()), m[2]!);
  }
}

class Episode {
  const Episode({
    required this.cid,
    required this.number,
    required this.name,
    required this.title,
    this.bvid = '',
    this.aid = 0,
    this.epId,
  });
  final int cid, number, aid;
  final String name, title, bvid;
  final int? epId;
  bool get isBangumi => epId != null;
}

class VideoInfo {
  const VideoInfo({
    required this.title,
    required this.description,
    required this.cover,
    required this.episodes,
    this.author = '',
    this.id = '',
  });
  final String title, description, cover, author, id;
  final List<Episode> episodes;
}

class Quality {
  const Quality(this.id, this.label);
  final int id;
  final String label;
}

class MediaStream {
  const MediaStream({
    required this.url,
    this.quality = 0,
    this.codec = 0,
    this.bandwidth = 0,
    this.extension = 'm4a',
  });
  final String url, extension;
  final int quality, codec, bandwidth;
  factory MediaStream.fromJson(
    Map<String, dynamic> data, {
    String extension = 'm4a',
  }) => MediaStream(
    url: (data['baseUrl'] ?? data['base_url'] ?? data['url'] ?? '').toString(),
    quality: (data['id'] ?? data['quality'] ?? 0) as int,
    codec: (data['codecid'] ?? 0) as int,
    bandwidth: (data['bandwidth'] ?? 0) as int,
    extension: extension,
  );
}

class PlayableMedia {
  const PlayableMedia({
    required this.qualities,
    required this.video,
    required this.audio,
    this.flac,
    this.dolby,
    this.languages = const {},
    this.mp4 = false,
  });
  final List<Quality> qualities;
  final List<MediaStream> video, audio;
  final MediaStream? flac, dolby;
  final Map<String, String> languages;
  final bool mp4;

  factory PlayableMedia.fromJson(Map<String, dynamic> data) {
    if (data['video_info'] is Map) {
      data = Map<String, dynamic>.from(data['video_info']);
    }
    final formats = (data['support_formats'] as List? ?? []).cast<Map>();
    final qualities = formats
        .map(
          (v) => Quality(
            v['quality'] as int,
            (v['new_description'] ?? v['display_desc'] ?? v['quality'])
                .toString(),
          ),
        )
        .toList();
    if (qualities.isEmpty) {
      final ids = data['accept_quality'] as List? ?? [];
      final labels = data['accept_description'] as List? ?? [];
      for (var i = 0; i < ids.length; i++) {
        qualities.add(
          Quality(
            ids[i] as int,
            i < labels.length ? labels[i].toString() : ids[i].toString(),
          ),
        );
      }
    }
    final dash = data['dash'] as Map?;
    MediaStream? special(dynamic value, String ext) => value is Map
        ? MediaStream.fromJson(Map<String, dynamic>.from(value), extension: ext)
        : null;
    final languages = <String, String>{};
    for (final l in (data['language']?['items'] as List? ?? [])) {
      languages[l['lang'].toString()] = l['title'].toString();
    }
    if (dash != null) {
      final videos = (dash['video'] as List? ?? [])
          .map(
            (v) => MediaStream.fromJson(
              Map<String, dynamic>.from(v),
              extension: 'mp4',
            ),
          )
          .toList();
      final audio =
          (dash['audio'] as List? ?? [])
              .map((v) => MediaStream.fromJson(Map<String, dynamic>.from(v)))
              .toList()
            ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
      final dolby = dash['dolby']?['audio'] as List? ?? [];
      if (qualities.isEmpty) {
        for (final id in videos.map((v) => v.quality).toSet()) {
          qualities.add(Quality(id, '$id'));
        }
      }
      return PlayableMedia(
        qualities: qualities,
        video: videos,
        audio: audio,
        flac: special(dash['flac']?['audio'], 'flac'),
        dolby: special(dolby.isEmpty ? null : dolby.first, 'm4a'),
        languages: languages,
      );
    }
    final groups =
        data['durls'] as List? ??
        [
          {'quality': data['quality'] ?? 0, 'durl': data['durl'] ?? []},
        ];
    final streams = <MediaStream>[];
    for (final group in groups) {
      final urls = group['durl'] as List? ?? [];
      if (urls.length > 1) throw const AppFailure('segmentedMp4');
      if (urls.isNotEmpty) {
        streams.add(
          MediaStream(
            url: urls.first['url'].toString(),
            quality: group['quality'] as int,
            extension: 'mp4',
          ),
        );
      }
    }
    if (streams.isEmpty) throw const AppFailure('noStreams');
    if (qualities.isEmpty) {
      for (final s in streams) {
        qualities.add(Quality(s.quality, '${s.quality}'));
      }
    }
    return PlayableMedia(
      qualities: qualities,
      video: streams,
      audio: const [],
      mp4: true,
      languages: languages,
    );
  }

  // Original UI offers a maximum quality and a preferred codec, not a guarantee.
  MediaStream selectVideo(int maximumQuality, int preferredCodec) {
    if (video.isEmpty) throw const AppFailure('noStreams');
    final candidates = video.where((s) => s.quality <= maximumQuality).toList()
      ..sort((a, b) => b.quality.compareTo(a.quality));
    if (candidates.isEmpty) throw const AppFailure('qualityUnavailable');
    final best = candidates
        .where((s) => s.quality == candidates.first.quality)
        .toList();
    return best.firstWhere(
      (s) => s.codec == preferredCodec,
      orElse: () => best.first,
    );
  }

  MediaStream? selectAudio(String special) {
    if (special == 'flac') {
      if (flac == null) throw const AppFailure('audioUnavailable');
      return flac;
    }
    if (special == 'dolby') {
      if (dolby == null) throw const AppFailure('audioUnavailable');
      return dolby;
    }
    return audio.isEmpty ? null : audio.first;
  }
}

class DownloadOptions {
  const DownloadOptions({
    required this.directory,
    required this.quality,
    this.codec = 7,
    this.onlyAudio = false,
    this.reserveAudio = false,
    this.danmaku = false,
    this.specialAudio = '',
    this.language = '',
    this.ultra = false,
    this.dolby = false,
    this.limitTitle = true,
  });
  final String directory, specialAudio, language;
  final int quality, codec;
  final bool onlyAudio, reserveAudio, danmaku, ultra, dolby, limitTitle;
  int get fnval =>
      16 | 128 | 2048 | (ultra ? 64 | 1024 : 0) | (dolby ? 256 : 0);
}

Set<int> parseSelection(String text, int count) {
  if (text.trim().isEmpty) return {};
  final selected = <int>{};
  for (final segment in text.replaceAll('，', ',').split(',')) {
    final m = RegExp(r'^\s*(\d+)(?:\s*-\s*(\d+))?\s*$').firstMatch(segment);
    if (m == null) throw const AppFailure('invalidSelection');
    final start = int.parse(m[1]!);
    final end = int.parse(m[2] ?? m[1]!);
    if (start < 1 || end < start || end > count) {
      throw const AppFailure('invalidSelection');
    }
    for (var n = start; n <= end; n++) {
      selected.add(n - 1);
    }
  }
  return selected;
}

String safeFilename(String text, {bool limit = true}) {
  var result = text
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  if (result.isEmpty || result == '.' || result == '..') result = '_';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(result)) {
    result = '_$result';
  }
  if (limit && result.runes.length > 80) {
    result = String.fromCharCodes(result.runes.take(80));
  }
  return result;
}
