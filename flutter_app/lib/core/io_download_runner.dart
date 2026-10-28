import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'bili_api.dart';
import 'danmaku.dart';
import 'download_job.dart';
import 'models.dart';

typedef MergeMedia = Future<void> Function(List<String> arguments);
Future<String> directWorkingDirectory(String directory) async => directory;
Future<String> directPublishFile(
  String file,
  String destination,
  String folder,
) async => file;
Future<void> mergeWithProcess(List<String> arguments) async {
  final result = await Process.run('ffmpeg', arguments);
  if (result.exitCode != 0) throw const AppFailure('mergeFailed');
}

class NativeDownloadRunner implements DownloadRunner {
  NativeDownloadRunner(
    this.api, {
    this.workingDirectory = directWorkingDirectory,
    this.publishFile = directPublishFile,
    Dio? dio,
    MergeMedia? merge,
    this.retryDelay = const Duration(seconds: 2),
  }) : dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 20),
             ),
           ),
       merge = merge ?? mergeWithProcess;
  final Future<String> Function(String) workingDirectory;
  final Future<String> Function(String, String, String) publishFile;
  final BiliApi api;
  final Dio dio;
  final MergeMedia merge;
  final Duration retryDelay;

  Future<Response<ResponseBody>> _get(
    String url,
    CancelToken token,
    Map<String, String> headers,
  ) => dio.get<ResponseBody>(
    url,
    cancelToken: token,
    options: Options(
      responseType: ResponseType.stream,
      headers: {...biliHeaders, 'Accept-Encoding': 'identity', ...headers},
    ),
  );

  static (int, int, int)? contentRange(String? value) {
    final m = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value ?? '');
    if (m == null) return null;
    final r = (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    return r.$1 <= r.$2 && r.$2 < r.$3 ? r : null;
  }

  static String? validator(Headers headers) {
    final etag = headers.value('etag');
    return etag != null && !etag.startsWith('W/')
        ? etag
        : headers.value('last-modified');
  }

  Future<int> downloadStream(
    String url,
    File file,
    String kind,
    DownloadJob job,
    void Function(int received, int total) progress,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (job.token.isCancelled) throw job.token.cancelError!;
      try {
        final probe = await _get(url, job.token, {'Range': 'bytes=0-0'});
        await probe.data!.stream.listen(null).cancel();
        final range = contentRange(probe.headers.value('content-range'));
        final total = probe.statusCode == 206
            ? range?.$3
            : int.tryParse(probe.headers.value('content-length') ?? '');
        if (total == null ||
            total <= 0 ||
            (probe.statusCode == 206 && range?.$1 != 0)) {
          throw const AppFailure('invalidRange');
        }
        final tag = validator(probe.headers);
        final previous = job.streams[kind];
        final same =
            previous != null &&
            previous.size == total &&
            (tag != null && previous.validator != null
                ? tag == previous.validator
                : previous.url == url);
        var offset = await file.exists() ? await file.length() : 0;
        if (!same || offset > total) {
          await file.writeAsBytes([]);
          offset = 0;
        }
        job.streams[kind] = StreamIdentity(url, total, tag);
        progress(offset, total);
        if (offset == total) return total;

        final response = await _get(url, job.token, {
          if (offset > 0) 'Range': 'bytes=$offset-',
          if (offset > 0 && tag != null) 'If-Range': tag,
        });
        final responseRange = contentRange(
          response.headers.value('content-range'),
        );
        final returnedTag = validator(response.headers);
        if (response.statusCode == 206 &&
            (responseRange == null ||
                responseRange.$1 != offset ||
                responseRange.$3 != total ||
                (offset > 0 &&
                    tag != null &&
                    returnedTag != null &&
                    returnedTag != tag))) {
          await response.data!.stream.listen(null).cancel();
          throw const AppFailure('invalidRange');
        }
        if (response.statusCode == 200) offset = 0;
        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.data!.stream.listen(null).cancel();
          throw const AppFailure('invalidResponse');
        }
        final sink = await file.open(
          mode: offset == 0 ? FileMode.write : FileMode.append,
        );
        try {
          await for (final chunk in response.data!.stream) {
            if (job.token.isCancelled) throw job.token.cancelError!;
            await sink.writeFrom(chunk);
            offset += chunk.length;
            if (offset > total) throw const AppFailure('sizeMismatch');
            progress(offset, total);
          }
        } finally {
          await sink.close();
        }
        if (offset != total) throw const AppFailure('sizeMismatch');
        return total;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e) || attempt == 2 || e.response != null) {
          rethrow;
        }
        await Future.any([
          Future<void>.delayed(retryDelay),
          job.token.whenCancel,
        ]);
      }
    }
    throw const AppFailure('downloadFailed');
  }

  @override
  Future<void> run(DownloadJob job, void Function() changed) async {
    final o = job.options;
    if (job.pendingExports.isNotEmpty) {
      job.state = JobState.merging;
      job.stage = 'saving';
      changed();
      await _export(job);
      return;
    }
    final root = await workingDirectory(o.directory);
    final folder = o.flatDirectory ? '' : job.episode.folderName;
    final dir = Directory(p.join(root, folder));
    await dir.create(recursive: true);
    final basename = job.episode.filename(limit: o.limitTitle);
    final temp = p.join(dir.path, '.$basename-${job.id}');
    job.stage = 'resolving';
    changed();
    final watch = Stopwatch()..start();
    final progress = <String, (int, int)>{};
    void report(String kind, int received, int total) {
      progress[kind] = (received, total);
      job.received = progress.values.fold(0, (a, b) => a + b.$1);
      job.total = progress.values.fold(0, (a, b) => a + b.$2);
      if (watch.elapsedMilliseconds >= 100 || received == total) {
        watch.reset();
        changed();
      }
    }

    final staged = job.pendingExports;
    for (var refresh = 0; !o.onlyDanmaku && refresh < 2; refresh++) {
      final media = await api.play(job.episode, o, cancel: job.token);
      if (media.mp4 && o.onlyAudio) {
        throw const AppFailure('mp4AudioUnsupported');
      }
      final video = o.onlyAudio ? null : media.selectVideo(o.quality, o.codec);
      final audio = media.mp4 ? null : media.selectAudio(o.specialAudio);
      if (o.onlyAudio && audio == null) throw const AppFailure('noAudio');
      job.actualQuality = video?.quality;
      final audioExt = audio?.extension ?? 'm4a';
      final output = p.join(
        dir.path,
        '$basename.${o.onlyAudio ? audioExt : 'mp4'}',
      );
      final audioOutput = p.join(dir.path, '$basename.$audioExt');
      if (await File(output).exists() ||
          (!o.onlyAudio &&
              o.reserveAudio &&
              audio != null &&
              await File(audioOutput).exists())) {
        throw const AppFailure('fileExists');
      }
      try {
        if (video != null) {
          job.stage = 'videoDownload';
          changed();
          await downloadStream(
            video.url,
            File('$temp.video'),
            'video',
            job,
            (n, total) => report('video', n, total),
          );
        }
        if (audio != null) {
          job.stage = 'audioDownload';
          changed();
          await downloadStream(
            audio.url,
            File('$temp.$audioExt'),
            'audio',
            job,
            (n, total) => report('audio', n, total),
          );
        }
      } on DioException catch (e) {
        if (refresh == 0 &&
            [401, 403, 404, 410, 416].contains(e.response?.statusCode)) {
          job.stage = 'refreshing';
          changed();
          continue;
        }
        rethrow;
      }
      if (job.token.isCancelled) throw job.token.cancelError!;
      job.state = JobState.merging;
      job.stage = 'saving';
      changed();
      if (video != null && audio != null) {
        job.stage = 'merging';
        changed();
        final merged = '$temp.merge.mp4';
        if (await File(merged).exists()) await File(merged).delete();
        await merge([
          '-nostdin',
          '-n',
          '-i',
          '$temp.video',
          '-i',
          '$temp.$audioExt',
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-c',
          'copy',
          '-strict',
          'experimental',
          merged,
        ]);
        await _publishLocal(File(merged), output);
        await File('$temp.video').delete();
      } else if (video != null) {
        await _publishLocal(File('$temp.video'), output);
      }
      if (audio != null) {
        if (o.onlyAudio || o.reserveAudio) {
          await _publishLocal(File('$temp.$audioExt'), audioOutput);
          staged.add(audioOutput);
        } else {
          await File('$temp.$audioExt').delete();
        }
      }
      if (!o.onlyAudio) staged.add(output);
      break;
    }
    if (o.danmaku || o.onlyDanmaku) {
      job.stage = 'danmakuDownload';
      changed();
      try {
        final xml = await api.danmaku(job.episode.cid, cancel: job.token);
        final ass = File(p.join(dir.path, '$basename.ass'));
        if (await ass.exists()) throw const AppFailure('fileExists');
        await ass.writeAsString(danmakuToAss(xml), flush: true);
        staged.add(ass.path);
      } catch (_) {
        if (o.onlyDanmaku) rethrow;
        job.detail = 'danmakuFailed';
      }
    }
    job.stage = 'saving';
    changed();
    await _export(job);
  }

  Future<void> _export(DownloadJob job) async {
    while (job.pendingExports.isNotEmpty) {
      final file = job.pendingExports.first;
      final destination = await publishFile(
        file,
        job.options.directory,
        job.options.flatDirectory ? '' : job.episode.folderName,
      );
      job.outputs.add(destination);
      job.pendingExports.removeAt(0);
    }
  }

  Future<void> _publishLocal(File source, String output) async {
    if (await File(output).exists()) throw const AppFailure('fileExists');
    await source.rename(output);
  }

  @override
  void dispose() => dio.close(force: true);
}
