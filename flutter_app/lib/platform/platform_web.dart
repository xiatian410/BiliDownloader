import 'dart:typed_data';

import '../core/models.dart';

bool get isAndroid => false;
bool get isLinux => false;
Future<String?> readLinuxCredentials() async => null;
Future<void> writeLinuxCredentials(String? value) async {}
Future<String> defaultDirectory() async => '';
Future<String?> chooseDirectory() async => null;
Future<void> openDirectory(String path) async =>
    throw const AppFailure('webDownloadUnsupported');
Future<String> workingDirectory(String destination) async =>
    throw const AppFailure('webDownloadUnsupported');
Future<String> publishFile(
  String file,
  String destination,
  String folder,
) async => throw const AppFailure('webDownloadUnsupported');
Future<void> saveBytes(Uint8List data, String name, String directory) async =>
    throw const AppFailure('webDownloadUnsupported');
