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
  };
  factory AppSettings.fromJson(Map<String, dynamic> data) {
    final s = AppSettings();
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
    return s;
  }
  AppSettings();
}
