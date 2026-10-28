import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../core/file_state_store.dart';
import '../core/state_store.dart';
import '../core/download_job.dart';

Future<StateStore?> openHistoryStore() async => FileStateStore(
  p.join((await getApplicationSupportDirectory()).path, 'history', 'queue'),
);

const _channel = MethodChannel('bili_downloader/files');
bool get isAndroid => Platform.isAndroid;
bool get isLinux => Platform.isLinux;
const _credentials = MethodChannel('bili_downloader/credentials');
Future<String?> readLinuxCredentials() =>
    _credentials.invokeMethod<String>('read');
Future<void> writeLinuxCredentials(String? value) => value == null
    ? _credentials.invokeMethod<void>('delete')
    : _credentials.invokeMethod<void>('write', value);

Future<String> defaultDirectory() async {
  final root = Platform.isAndroid
      ? await getExternalStorageDirectory()
      : await getDownloadsDirectory();
  final dir = Directory(
    p.join(
      (root ?? await getApplicationDocumentsDirectory()).path,
      'BiliDownloader',
    ),
  );
  await dir.create(recursive: true);
  return dir.path;
}

Future<String?> chooseDirectory() async {
  if (Platform.isAndroid) return _channel.invokeMethod<String>('pickDirectory');
  return FilePicker.getDirectoryPath();
}

Future<String> workingDirectory(String destination) async {
  if (destination.startsWith('content://') && Platform.isAndroid) {
    return p.join((await getApplicationSupportDirectory()).path, 'downloads');
  }
  if (destination.isEmpty) throw const AppFailure('invalidDirectory');
  return destination;
}

Future<void> openDirectory(String directory) async {
  if (Platform.isAndroid) {
    await _channel.invokeMethod<void>('openDirectory', {'path': directory});
  } else if (!await launchUrl(Uri.directory(directory))) {
    throw const AppFailure('openFailed');
  }
}

Future<String> publishFile(
  String file,
  String destination,
  String folder, {
  bool retainSource = false,
}) async {
  if (!destination.startsWith('content://')) return file;
  final uri = await _channel.invokeMethod<String>('publishFile', {
    'path': file,
    'tree': destination,
    'folder': folder,
    'name': p.basename(file),
  });
  if (uri == null) throw const AppFailure('saveFailed');
  // Delete the staged copy only after the system confirms the export succeeded.
  if (!retainSource) await File(file).delete();
  return uri;
}

Future<String> publishStagedFile(
  String file,
  String destination,
  String folder,
) => publishFile(file, destination, folder, retainSource: true);

Future<void> exportCompletedFiles(DownloadJob job, String directory) async {
  for (var i = 0; i < job.outputs.length; i++) {
    final source = job.outputs[i];
    if (source.startsWith('content://')) continue;
    final destination = await publishStagedFile(
      source,
      directory,
      job.options.flatDirectory ? '' : job.episode.folderName,
    );
    final previousDirectory = job.exportedDirectory;
    final previousExport = job.exportedFiles[source];
    job.outputs[i] = destination;
    job.exportedDirectory = directory;
    job.exportedFiles[source] = destination;
    try {
      await job.checkpoint();
    } catch (_) {
      job.outputs[i] = source;
      job.exportedDirectory = previousDirectory;
      if (previousExport == null) {
        job.exportedFiles.remove(source);
      } else {
        job.exportedFiles[source] = previousExport;
      }
      rethrow;
    }
    if (destination.startsWith('content://')) await File(source).delete();
  }
}

Future<void> saveBytes(Uint8List data, String name, String directory) async {
  final root = await workingDirectory(directory);
  await Directory(root).create(recursive: true);
  final file = File(p.join(root, safeFilename(name, limit: false)));
  if (await file.exists()) throw const AppFailure('fileExists');
  await file.writeAsBytes(data, flush: true);
  await publishFile(file.path, directory, 'Covers');
}
