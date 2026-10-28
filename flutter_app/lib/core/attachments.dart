import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'models.dart';

enum AttachmentState { pending, working, completed, failed, unavailable }

String normalizeCoverUrl(String value) {
  final uri = Uri.tryParse(value.startsWith('//') ? 'https:$value' : value);
  if (uri == null) return value;
  if (uri.scheme == 'http' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 80) &&
      (uri.host.endsWith('.hdslb.com') || uri.host.endsWith('.bilibili.com'))) {
    return uri.replace(scheme: 'https', port: 443).toString();
  }
  return uri.toString();
}

class AttachmentResult {
  AttachmentState state = AttachmentState.pending;
  String? output;
  AppFailure? error;
  String label = '';
  bool automatic = false;

  Map<String, dynamic> toJson({bool includePath = false}) => {
    'state': state.name,
    if (label.isNotEmpty) 'label': label,
    if (automatic) 'automatic': true,
    if (includePath) 'output': output,
    if (error != null) 'error': {'key': error!.key, 'detail': error!.detail},
  };

  static AttachmentResult fromJson(Map m) => AttachmentResult()
    ..state = AttachmentState.values.byName(m['state'] as String)
    ..output = m['output'] as String?
    ..label = m['label'] as String? ?? ''
    ..automatic = m['automatic'] == true
    ..error = m['error'] == null
        ? null
        : AppFailure(
            m['error']['key'] as String,
            m['error']['detail'] as String? ?? '',
          );
}

class CoverImage {
  CoverImage(List<int> data) : bytes = Uint8List.fromList(data) {
    bool starts(List<int> signature, [int offset = 0]) =>
        bytes.length >= offset + signature.length &&
        signature.indexed.every((v) => bytes[offset + v.$1] == v.$2);
    bool ascii(String value, int offset) => starts(value.codeUnits, offset);
    if (starts([0xff, 0xd8, 0xff])) {
      extension = 'jpg';
      contentType = 'image/jpeg';
    } else if (starts([137, 80, 78, 71, 13, 10, 26, 10])) {
      extension = 'png';
      contentType = 'image/png';
    } else if (ascii('RIFF', 0) && ascii('WEBP', 8)) {
      extension = 'webp';
      contentType = 'image/webp';
    } else if (bytes.length >= 16 &&
        ascii('ftyp', 4) &&
        (ascii('avif', 8) || ascii('avis', 8))) {
      extension = 'avif';
      contentType = 'image/avif';
    } else {
      throw const AppFailure('invalidCover');
    }
  }
  final Uint8List bytes;
  late final String extension, contentType;
}

/// Each downloaded part is an independent video item. Do not invent TV seasons,
/// ratings, dates, or external database IDs that the source did not supply.
String videoNfo(Episode e) {
  String xmlText(String text) => String.fromCharCodes(
    text.runes.map(
      (r) =>
          r == 9 ||
              r == 10 ||
              r == 13 ||
              (r >= 0x20 && r <= 0xd7ff) ||
              (r >= 0xe000 && r <= 0xfffd) ||
              (r >= 0x10000 && r <= 0x10ffff)
          ? r
          : 0xfffd,
    ),
  );
  final b = XmlBuilder()..processing('xml', 'version="1.0" encoding="UTF-8"');
  b.element(
    'movie',
    nest: () {
      b.element(
        'title',
        nest: xmlText(
          e.title == e.name ? e.title : '${e.title} - ${e.number}. ${e.name}',
        ),
      );
      if (e.description.isNotEmpty) {
        b.element('plot', nest: xmlText(e.description));
      }
      if (e.author.isNotEmpty) {
        b.element('tag', nest: xmlText('UP: ${e.author}'));
      }
      b.element(
        'uniqueid',
        attributes: {'type': 'bilibili', 'default': 'true'},
        nest: e.identity,
      );
    },
  );
  return '${b.buildDocument().toXmlString()}\n';
}
