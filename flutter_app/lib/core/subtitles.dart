import 'models.dart';

bool validSubtitleLanguage(String value) =>
    RegExp(r'^[A-Za-z][A-Za-z0-9-]{0,31}$').hasMatch(value) &&
    !['off', 'all'].contains(value);
bool validSubtitleSelection(String value) =>
    ['off', 'all'].contains(value) || validSubtitleLanguage(value);

class SubtitleTrack {
  const SubtitleTrack({
    required this.id,
    required this.language,
    required this.label,
    this.url = '',
    this.automatic = false,
  });
  final String id, language, label, url;
  final bool automatic;
  String get key => 'subtitle:$language:$id';
  Map<String, dynamic> toJson() => {
    'id': id,
    'language': language,
    'label': label,
    'automatic': automatic,
  };
  factory SubtitleTrack.fromJson(Map m) {
    if (m['id'] is! String ||
        !RegExp(r'^[0-9]{1,40}$').hasMatch(m['id'] as String) ||
        m['language'] is! String ||
        !validSubtitleLanguage(m['language'] as String) ||
        m['label'] is! String) {
      throw const AppFailure('invalidSubtitle');
    }
    return SubtitleTrack(
      id: m['id'] as String,
      language: m['language'] as String,
      label: m['label'] as String,
      automatic: m['automatic'] == true,
    );
  }
}

List<SubtitleTrack> playerSubtitles(
  Map<String, dynamic> data,
  Episode episode,
) {
  // A video's first-part response must never be used for another CID.
  if (data['cid'] != episode.cid ||
      (data['aid'] != null && episode.aid > 0 && data['aid'] != episode.aid)) {
    throw const AppFailure('subtitleIdentityMismatch');
  }
  if (data['need_login_subtitle'] == true) {
    throw const AppFailure('subtitleLoginRequired');
  }
  final subtitle = data['subtitle'];
  if (subtitle != null && subtitle is! Map) {
    throw const AppFailure('invalidSubtitle');
  }
  final rows = (subtitle as Map?)?['subtitles'];
  if (rows == null) return [];
  if (rows is! List) throw const AppFailure('invalidSubtitle');
  if (rows.length > 32) throw const AppFailure('requestTooLarge');
  final result = <String, SubtitleTrack>{};
  for (final row in rows) {
    if (row is! Map) throw const AppFailure('invalidSubtitle');
    final id = row['id_str'] ?? row['id']?.toString();
    final language = row['lan'];
    final url = row['subtitle_url'];
    final track = SubtitleTrack.fromJson({
      'id': id,
      'language': language,
      'label': row['lan_doc'] ?? language,
      'automatic':
          language is String && language.toLowerCase().startsWith('ai-') ||
          row['ai_type'] is num && row['ai_type'] > 0,
    });
    // is_lock also occurs on usable tracks. It is not a download permission.
    // Honor actual API/resource errors instead of inventing a local access gate.
    if (url is! String || url.isEmpty) {
      throw const AppFailure('invalidSubtitle');
    }
    result.putIfAbsent(
      track.key.toLowerCase(),
      () => SubtitleTrack(
        id: track.id,
        language: track.language,
        label: track.label,
        automatic: track.automatic,
        url: url,
      ),
    );
  }
  return result.values.toList();
}

String subtitlesToSrt(dynamic data) {
  if (data is! Map || data['body'] is! List) {
    throw const AppFailure('invalidSubtitle');
  }
  final cues = data['body'] as List;
  if (cues.isEmpty) throw const AppFailure('subtitleEmpty');
  if (cues.length > 20000) throw const AppFailure('requestTooLarge');
  String timestamp(int ms) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
  }

  final output = StringBuffer();
  for (final (index, cue) in cues.indexed) {
    if (cue is! Map ||
        cue['from'] is! num ||
        cue['to'] is! num ||
        cue['content'] is! String) {
      throw const AppFailure('invalidSubtitle');
    }
    final from = cue['from'] as num, to = cue['to'] as num;
    if (!from.isFinite ||
        !to.isFinite ||
        from < 0 ||
        to > 7 * 86400 ||
        to <= from) {
      throw const AppFailure('invalidSubtitle');
    }
    final start = (from * 1000).round(), end = (to * 1000).round();
    if (end <= start) throw const AppFailure('invalidSubtitle');
    final text = (cue['content'] as String)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .split('\n')
        .map((line) => line.trim().isEmpty ? '\u00a0' : line)
        .join('\n');
    if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(text)) {
      throw const AppFailure('invalidSubtitle');
    }
    output.write(
      '${index + 1}\n${timestamp(start)} --> ${timestamp(end)}\n$text\n\n',
    );
  }
  return output.toString();
}
