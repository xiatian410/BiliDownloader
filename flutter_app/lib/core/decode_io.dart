import 'dart:convert';
import 'dart:io';

String decodeDanmaku(List<int> bytes) {
  // The XML endpoint can return raw DEFLATE without Content-Encoding.
  try {
    final plain = utf8.decode(bytes);
    if (plain.trimLeft().startsWith('<')) return plain;
  } on FormatException {
    /* Try the raw-deflate payload below. */
  }
  return utf8.decode(ZLibDecoder(raw: true).convert(bytes));
}
