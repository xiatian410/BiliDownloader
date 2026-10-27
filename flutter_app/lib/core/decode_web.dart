import 'dart:convert';

// A backend must serve decoded XML; browsers handle HTTP Content-Encoding.
String decodeDanmaku(List<int> bytes) => utf8.decode(bytes);
