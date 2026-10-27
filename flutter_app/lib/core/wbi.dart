import 'dart:convert';

import 'package:crypto/crypto.dart';

const _table = [
  46,
  47,
  18,
  2,
  53,
  8,
  23,
  32,
  15,
  50,
  10,
  31,
  58,
  3,
  45,
  35,
  27,
  43,
  5,
  49,
  33,
  9,
  42,
  19,
  29,
  28,
  14,
  39,
  12,
  38,
  41,
  13,
  37,
  48,
  7,
  16,
  24,
  55,
  40,
  61,
  26,
  17,
  0,
  1,
  60,
  51,
  30,
  4,
  22,
  25,
  54,
  21,
  56,
  59,
  6,
  63,
  57,
  62,
  11,
  36,
  20,
  34,
  44,
  52,
];

Map<String, String> signWbi(
  Map<String, dynamic> input,
  String imgKey,
  String subKey, {
  int? timestamp,
}) {
  final raw = imgKey + subKey;
  if (raw.length != 64) throw const FormatException('Invalid WBI key');
  final mixin = _table.take(32).map((i) => raw[i]).join();
  final params = {
    ...input,
    'wts': timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
  };
  final keys = params.keys.toList()..sort();
  final signed = <String, String>{
    for (final k in keys) k: '${params[k]}'.replaceAll(RegExp(r"[!'()*]"), ''),
  };
  final query = signed.entries
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');
  signed['w_rid'] = md5.convert(utf8.encode(query + mixin)).toString();
  return signed;
}
