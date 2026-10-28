import 'models.dart';
import 'subtitles.dart';

Map<String, dynamic> episodeToJson(Episode e) => {
  'cid': e.cid,
  'number': e.number,
  'name': e.name,
  'title': e.title,
  'bvid': e.bvid,
  'aid': e.aid,
  'epId': e.epId,
  'cover': e.cover,
  'description': e.description,
  'author': e.author,
};
Episode episodeFromJson(Map<String, dynamic> m) => Episode(
  cid: m['cid'] as int,
  number: m['number'] as int,
  name: m['name'] as String,
  title: m['title'] as String,
  bvid: m['bvid'] as String,
  aid: m['aid'] as int,
  epId: m['epId'] as int?,
  cover: m['cover'] as String? ?? '',
  description: m['description'] as String? ?? '',
  author: m['author'] as String? ?? '',
);
Map<String, dynamic> videoToJson(VideoInfo v) => {
  'title': v.title,
  'description': v.description,
  'cover': v.cover,
  'author': v.author,
  'id': v.id,
  'episodes': v.episodes.map(episodeToJson).toList(),
};
VideoInfo videoFromJson(Map<String, dynamic> m) => VideoInfo(
  title: m['title'] as String,
  description: m['description'] as String,
  cover: m['cover'] as String,
  author: m['author'] as String,
  id: m['id'] as String,
  episodes: (m['episodes'] as List)
      .map((e) => episodeFromJson(Map<String, dynamic>.from(e)))
      .toList(),
);
Map<String, dynamic> optionsToJson(DownloadOptions o) => {
  'directory': o.directory,
  'quality': o.quality,
  'codec': o.codec,
  'onlyAudio': o.onlyAudio,
  'reserveAudio': o.reserveAudio,
  'danmaku': o.danmaku,
  'specialAudio': o.specialAudio,
  'language': o.language,
  'ultra': o.ultra,
  'dolby': o.dolby,
  'limitTitle': o.limitTitle,
  'flatDirectory': o.flatDirectory,
  'onlyDanmaku': o.onlyDanmaku,
  'autoCover': o.autoCover,
  'nfo': o.nfo,
  'subtitles': o.subtitles,
};
DownloadOptions optionsFromJson(Map<String, dynamic> m, {String? directory}) {
  final subtitles = m['subtitles'] ?? 'off';
  if (subtitles is! String || !validSubtitleSelection(subtitles)) {
    throw const AppFailure('invalidSubtitleSelection');
  }
  final quality = m['quality'];
  if (quality is! int ||
      quality < 1 ||
      quality > 127 ||
      ![7, 12, 13].contains(m['codec'])) {
    throw const AppFailure('invalidResponse');
  }
  return DownloadOptions(
    directory: directory ?? m['directory'] as String,
    quality: quality,
    codec: m['codec'] as int,
    onlyAudio: m['onlyAudio'] == true,
    reserveAudio: m['reserveAudio'] == true,
    danmaku: m['danmaku'] == true,
    specialAudio: m['specialAudio'] as String? ?? '',
    language: m['language'] as String? ?? '',
    ultra: m['ultra'] == true,
    dolby: m['dolby'] == true,
    limitTitle: m['limitTitle'] != false,
    flatDirectory: m['flatDirectory'] == true,
    onlyDanmaku: m['onlyDanmaku'] == true,
    autoCover: m['autoCover'] == true,
    nfo: m['nfo'] == true,
    subtitles: subtitles,
  );
}

Map<String, dynamic> mediaToJson(PlayableMedia m) {
  Map<String, dynamic> stream(MediaStream s) => {
    'url': '',
    'id': s.quality,
    'codecid': s.codec,
    'bandwidth': s.bandwidth,
    'extension': s.extension,
  };
  return {
    'qualities': m.qualities
        .map((q) => {'id': q.id, 'label': q.label})
        .toList(),
    'video': m.video.map(stream).toList(),
    'audio': m.audio.map(stream).toList(),
    'flac': m.flac == null ? null : stream(m.flac!),
    'dolby': m.dolby == null ? null : stream(m.dolby!),
    'languages': m.languages,
    'mp4': m.mp4,
  };
}

PlayableMedia mediaFromJson(Map<String, dynamic> m) {
  MediaStream stream(dynamic s) => MediaStream.fromJson(
    Map<String, dynamic>.from(s),
    extension: s['extension'] as String,
  );
  return PlayableMedia(
    qualities: (m['qualities'] as List)
        .map((q) => Quality(q['id'] as int, q['label'] as String))
        .toList(),
    video: (m['video'] as List).map(stream).toList(),
    audio: (m['audio'] as List).map(stream).toList(),
    flac: m['flac'] == null ? null : stream(m['flac']),
    dolby: m['dolby'] == null ? null : stream(m['dolby']),
    languages: Map<String, String>.from(m['languages']),
    mp4: m['mp4'] == true,
  );
}
