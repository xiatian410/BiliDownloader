import 'package:xml/xml.dart';

// ASS sidecar, as in the original downloader. Normal, top and bottom comments.
String danmakuToAss(String source) {
  final xml = XmlDocument.parse(source);
  final out = StringBuffer('''[Script Info]
ScriptType: v4.00+
PlayResX: 852
PlayResY: 480
WrapStyle: 2

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,HarmonyOS Sans SC,25,&H66FFFFFF,&H66FFFFFF,&H66000000,&H66000000,0,0,0,0,100,100,0,0,1,1,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''');
  final lanes = List<double>.filled(16, -10);
  for (final node in xml.findAllElements('d')) {
    final fields = node.getAttribute('p')?.split(',') ?? [];
    if (fields.length < 4) continue;
    final at = double.tryParse(fields[0]);
    final mode = int.tryParse(fields[1]);
    final color = int.tryParse(fields[3]);
    if (at == null ||
        at < 0 ||
        color == null ||
        ![1, 2, 3, 4, 5].contains(mode)) {
      continue;
    }
    var lane = lanes.indexWhere((t) => at >= t);
    if (lane == -1) continue;
    lanes[lane] = at + (mode == 4 || mode == 5 ? 5 : 2);
    final y = mode == 4 ? 460 - lane * 26 : lane * 26;
    final bgr =
        '${(color & 255).toRadixString(16).padLeft(2, '0')}${((color >> 8) & 255).toRadixString(16).padLeft(2, '0')}${((color >> 16) & 255).toRadixString(16).padLeft(2, '0')}';
    final text = node.innerText
        .replaceAll('\\', r'\\')
        .replaceAll('{', '｛')
        .replaceAll('}', '｝')
        .replaceAll('\n', r'\N')
        .replaceAll('\r', '');
    final position = mode == 4 || mode == 5
        ? r'\an8\pos(426,'
              '$y)'
        : r'\move(852,'
              '$y,-${node.innerText.runes.length * 25},$y)';
    out.writeln(
      'Dialogue: 0,${_timestamp(at)},${_timestamp(at + 5)},Default,,0,0,0,,{$position\\c&H$bgr&}$text',
    );
  }
  return out.toString();
}

String _timestamp(double value) {
  final ticks = (value * 100).round();
  return '${ticks ~/ 360000}:${(ticks ~/ 6000 % 60).toString().padLeft(2, '0')}:${(ticks ~/ 100 % 60).toString().padLeft(2, '0')}.${(ticks % 100).toString().padLeft(2, '0')}';
}
