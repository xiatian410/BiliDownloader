import 'subtitles.dart';

class AppSettings {
  String directory = '';
  String locale = 'zh';
  int concurrency = 4;
  int codec = 7;
  bool onlyAudio = false;
  bool reserveAudio = false;
  bool danmaku = false;
  bool ultra = false;
  bool dolby = false;
  bool clipboard = true;
  bool limitTitle = true;
  bool flatDirectory = false;
  bool onlyDanmaku = false;
  bool autoCover = false;
  bool nfo = false;
  String subtitles = 'off';
  String theme = 'system';
  // A non-secret hint detects cleared ownership cookies; it grants no access.
  String serviceWorkspace = '';

  Map<String, dynamic> toJson() => {
    'directory': directory,
    'locale': locale,
    'concurrency': concurrency,
    'codec': codec,
    'onlyAudio': onlyAudio,
    'reserveAudio': reserveAudio,
    'danmaku': danmaku,
    'ultra': ultra,
    'dolby': dolby,
    'clipboard': clipboard,
    'limitTitle': limitTitle,
    'flatDirectory': flatDirectory,
    'onlyDanmaku': onlyDanmaku,
    'autoCover': autoCover,
    'nfo': nfo,
    'subtitles': subtitles,
    'theme': theme,
    'serviceWorkspace': serviceWorkspace,
  };
  factory AppSettings.fromJson(Map<String, dynamic> data) {
    final s = AppSettings();
    final workspace = data['serviceWorkspace'];
    if (workspace is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(workspace)) {
      s.serviceWorkspace = workspace;
    }
    s.directory = data['directory'] as String? ?? '';
    s.locale = data['locale'] == 'en' ? 'en' : 'zh';
    final concurrency = data['concurrency'];
    if (concurrency is int && concurrency >= 1 && concurrency <= 8) {
      s.concurrency = concurrency;
    }
    if ([7, 12, 13].contains(data['codec'])) s.codec = data['codec'] as int;
    s.onlyAudio = data['onlyAudio'] == true;
    s.reserveAudio = data['reserveAudio'] == true;
    s.danmaku = data['danmaku'] == true;
    s.ultra = data['ultra'] == true;
    s.dolby = data['dolby'] == true;
    s.clipboard = data['clipboard'] != false;
    s.limitTitle = data['limitTitle'] != false;
    s.flatDirectory = data['flatDirectory'] == true;
    s.onlyDanmaku = data['onlyDanmaku'] == true;
    s.autoCover = data['autoCover'] == true;
    s.nfo = data['nfo'] == true;
    if (data['subtitles'] is String &&
        validSubtitleSelection(data['subtitles'] as String)) {
      s.subtitles = data['subtitles'] as String;
    }
    if (['system', 'light', 'dark'].contains(data['theme'])) {
      s.theme = data['theme'] as String;
    }
    return s;
  }
  AppSettings();
}
