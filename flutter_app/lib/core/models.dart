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
    final ids = parseMany(input).ids;
    return ids.length == 1 ? ids.single : null;
  }

  static VideoInput parseMany(String input) {
    final ids = <String, VideoId>{};
    final invalid = <String>[];
    var duplicates = 0;
    final pattern = RegExp(
      r'(?<![A-Za-z0-9])(?:(BV)([A-Za-z0-9]{10})|(av|md|ep)([1-9][0-9]*))(?![A-Za-z0-9])',
      caseSensitive: false,
    );
    for (final token in input.trim().split(RegExp(r'[\s,;，；]+'))) {
      if (token.isEmpty) continue;
      final matches = pattern.allMatches(token);
      if (matches.isEmpty) invalid.add(token);
      for (final m in matches) {
        final id = m[1] != null
            ? VideoId(VideoKind.bv, m[2]!)
            : VideoId(VideoKind.values.byName(m[3]!.toLowerCase()), m[4]!);
        if (ids.containsKey(id.label)) duplicates++;
        ids[id.label] = id;
      }
    }
    return VideoInput(ids.values.toList(), invalid, duplicates);
  }
}

class VideoInput {
  const VideoInput(this.ids, this.invalid, this.duplicates);
  final List<VideoId> ids;
  final List<String> invalid;
  final int duplicates;
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
    this.cover = '',
    this.description = '',
    this.author = '',
  });
  final int cid, number, aid;
  final String name, title, bvid;
  final String cover, description, author;
  final int? epId;
  bool get isBangumi => epId != null;
  String get identity =>
      epId != null ? 'ep$epId-$cid' : '${bvid.isEmpty ? 'av$aid' : bvid}-$cid';
  String get folderName =>
      '${safeFilename(title)} [${safeFilename(bvid.isNotEmpty
          ? bvid
          : epId != null
          ? 'ep$epId'
          : 'av$aid')}]';
  String filename({bool limit = true}) =>
      '${number.toString().padLeft(3, '0')}-${safeFilename(name, limit: limit)} [$cid]';
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

  List<Quality> get availableQualities {
    final ids = video.map((v) => v.quality).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    return ids
        .map(
          (id) => qualities.firstWhere(
            (q) => q.id == id,
            orElse: () => Quality(id, qualityLabel(id)),
          ),
        )
        .toList();
  }

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
    this.flatDirectory = false,
    this.onlyDanmaku = false,
    this.autoCover = false,
    this.nfo = false,
  });
  final String directory, specialAudio, language;
  final int quality, codec;
  final bool onlyAudio, reserveAudio, danmaku, ultra, dolby, limitTitle;
  final bool flatDirectory, onlyDanmaku;
  final bool autoCover, nfo;
  int get fnval =>
      16 | 128 | 2048 | (ultra ? 64 | 1024 : 0) | (dolby ? 256 : 0);
}

String qualityLabel(int id) =>
    const {
      6: '240P',
      16: '360P',
      32: '480P',
      64: '720P',
      74: '720P 60',
      80: '1080P',
      112: '1080P+',
      116: '1080P 60',
      120: '4K',
      125: 'HDR',
      126: 'Dolby Vision',
      127: '8K',
    }[id] ??
    '$id';

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
