import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'bili_api.dart';
import 'danmaku.dart';
import 'download_job.dart';
import 'models.dart';
import 'media_merge.dart';
import 'process_merge.dart';
import 'attachments.dart';
import 'subtitles.dart';
export 'media_merge.dart';
export 'process_merge.dart';

Future<String> directWorkingDirectory(String directory) async => directory;
Future<String> directPublishFile(
  String file,
  String destination,
  String folder,
) async => file;

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
                : previous.matchesUrl(url));
        var offset = await file.exists() ? await file.length() : 0;
        if (!same || offset > total) {
          await file.writeAsBytes([]);
          offset = 0;
        }
        job.streams[kind] = StreamIdentity(url, total, tag);
        await job.checkpoint();
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
    if (job.token.isCancelled) throw job.token.cancelError!;
    job.mergeProgress = null;
    if (job.detail.startsWith('merge') || job.detail == 'stoppingMerge') {
      job.detail = '';
    }
    final o = job.options;
    // Resolve publication intentions before deciding whether any media is missing.
    await _recoverPublications(job);
    if (job.publications.keys.any((path) => path.endsWith('.ass'))) {
      job.commentsPrepared = true;
    }
    if (job.expectedMediaOutputs.isNotEmpty &&
        job.expectedMediaOutputs.every(job.publications.containsKey)) {
      job.mediaPrepared = true;
    }
    // Compatibility with an in-memory export retry created before publication manifests.
    if (job.pendingExports.isNotEmpty && job.publications.isEmpty) {
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
      final previous = progress[kind]?.$1 ?? 0;
      progress[kind] = (received, total);
      job.received = progress.values.fold(0, (a, b) => a + b.$1);
      job.total = progress.values.fold(0, (a, b) => a + b.$2);
      if ((previous == 0 && received > 0) ||
          watch.elapsedMilliseconds >= 100 ||
          received == total) {
        watch.reset();
        changed();
      }
    }

    for (
      var refresh = 0;
      !o.onlyDanmaku && !job.mediaPrepared && refresh < 2;
      refresh++
    ) {
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
      job.expectedMediaOutputs
        ..clear()
        ..add(output);
      if (!o.onlyAudio && o.reserveAudio && audio != null) {
        job.expectedMediaOutputs.add(audioOutput);
      }
      await job.checkpoint();
      if ((await File(output).exists() &&
              !job.publications.containsKey(output)) ||
          (!o.onlyAudio &&
              o.reserveAudio &&
              audio != null &&
              await File(audioOutput).exists() &&
              !job.publications.containsKey(audioOutput))) {
        throw const AppFailure('fileExists');
      }
      try {
        if (video != null && !job.publications.containsKey(output)) {
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
        if (audio != null &&
            (!job.publications.containsKey(
                  o.onlyAudio ? audioOutput : output,
                ) ||
                (!o.onlyAudio &&
                    o.reserveAudio &&
                    !job.publications.containsKey(audioOutput)))) {
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
      if (video != null &&
          audio != null &&
          !job.publications.containsKey(output)) {
        job.stage = 'merging';
        changed();
        final merged = '$temp.merge.mp4';
        if (await File(merged).exists()) await File(merged).delete();
        await merge(
          [
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
          ],
          cancel: job.token,
          onProgress: (progress) {
            job.mergeProgress = progress;
            changed();
          },
          onStopping: (reason) {
            job.state = JobState.pausing;
            job.stage = 'stoppingMerge';
            if (reason != 'stoppingMerge') job.detail = reason;
            changed();
          },
        ).whenComplete(() {
          if (job.detail.startsWith('merge')) job.detail = '';
        });
        await _publishLocal(File(merged), output, job);
        await File('$temp.video').delete();
      } else if (video != null && !job.publications.containsKey(output)) {
        await _publishLocal(File('$temp.video'), output, job);
      }
      if (audio != null) {
        if (o.onlyAudio || o.reserveAudio) {
          if (!job.publications.containsKey(audioOutput)) {
            await _publishLocal(File('$temp.$audioExt'), audioOutput, job);
          }
        } else {
          if (await File('$temp.$audioExt').exists()) {
            await File('$temp.$audioExt').delete();
          }
        }
      }
      job.mediaPrepared = true;
      await job.checkpoint();
      break;
    }
    if ((o.danmaku || o.onlyDanmaku) && !job.commentsPrepared) {
      job.stage = 'danmakuDownload';
      changed();
      try {
        final xml = await api.danmaku(job.episode.cid, cancel: job.token);
        final ass = File(p.join(dir.path, '$basename.ass'));
        if (!job.publications.containsKey(ass.path)) {
          final temporary = File('$temp.ass');
          await temporary.writeAsString(danmakuToAss(xml), flush: true);
          await _publishLocal(temporary, ass.path, job);
        }
        job.commentsPrepared = true;
        await job.checkpoint();
      } catch (e) {
        if (o.onlyDanmaku ||
            job.token.isCancelled ||
            (e is AppFailure && e.key.startsWith('history'))) {
          rethrow;
        }
        job.detail = 'danmakuFailed';
      }
    }
    await _attachments(job, dir.path, basename, temp, changed);
    await _subtitles(job, dir.path, basename, temp, changed);
    job.stage = 'saving';
    changed();
    await _export(job);
  }

  Future<void> _attachments(
    DownloadJob job,
    String directory,
    String basename,
    String temp,
    void Function() changed,
  ) async {
    for (final kind in [
      if (job.options.autoCover) 'cover',
      if (job.options.nfo) 'nfo',
    ]) {
      if (job.token.isCancelled) throw job.token.cancelError!;
      final result = job.attachments.putIfAbsent(kind, AttachmentResult.new);
      if (result.state == AttachmentState.completed) continue;
      // A saved publication intention can outlive a process interruption.
      if (result.output != null &&
          job.publications.containsKey(result.output)) {
        result.state = AttachmentState.completed;
        result.error = null;
        await job.checkpoint();
        changed();
        continue;
      }
      job.state = JobState.running;
      job.stage = 'attachments';
      job.mergeProgress = null;
      result.state = AttachmentState.working;
      result.error = null;
      await job.checkpoint();
      changed();
      try {
        late File temporary;
        if (kind == 'cover') {
          final cover = await api.fetchCover(
            job.episode.cover,
            cancel: job.token,
          );
          result.output = p.join(
            directory,
            '$basename-poster.${cover.extension}',
          );
          temporary = File('$temp.cover');
          await temporary.writeAsBytes(cover.bytes, flush: true);
        } else {
          result.output = p.join(directory, '$basename.nfo');
          temporary = File('$temp.nfo');
          await temporary.writeAsString(videoNfo(job.episode), flush: true);
        }
        await _publishLocal(temporary, result.output!, job);
        result.state = AttachmentState.completed;
      } catch (e) {
        _attachmentFailure(job, result, e);
      }
      await job.checkpoint();
      changed();
    }
  }

  void _attachmentFailure(
    DownloadJob job,
    AttachmentResult result,
    Object error,
  ) {
    if (job.token.isCancelled) {
      result.state = AttachmentState.pending;
      throw job.token.cancelError!;
    }
    if (error is AppFailure && error.key.startsWith('history')) throw error;
    result.state = error is AppFailure && error.key == 'subtitleEmpty'
        ? AttachmentState.unavailable
        : AttachmentState.failed;
    result.error = error is AppFailure
        ? error
        : error is DioException
        ? AppFailure(
            error.response == null ? 'networkError' : 'httpError',
            error.response?.statusCode?.toString() ?? error.type.name,
          )
        : const AppFailure('saveFailed');
  }

  Future<void> _subtitles(
    DownloadJob job,
    String directory,
    String basename,
    String temp,
    void Function() changed,
  ) async {
    if (job.options.subtitles == 'off') return;
    if (!validSubtitleSelection(job.options.subtitles)) {
      throw const AppFailure('invalidSubtitleSelection');
    }
    if (job.token.isCancelled) throw job.token.cancelError!;
    List<SubtitleTrack>? available;
    job.state = JobState.running;
    job.stage = 'attachments';
    job.mergeProgress = null;
    if (job.subtitleTracks.isEmpty) {
      final group =
          job.attachments.putIfAbsent('subtitles', AttachmentResult.new)
            ..state = AttachmentState.working
            ..error = null;
      await job.checkpoint();
      changed();
      try {
        available = await api.subtitles(job.episode, cancel: job.token);
        final selected = available
            .where(
              (t) =>
                  job.options.subtitles == 'all' ||
                  t.language.toLowerCase() ==
                      job.options.subtitles.toLowerCase(),
            )
            .toList();
        if (selected.isEmpty) {
          group.state = AttachmentState.unavailable;
          group.error = available.isEmpty
              ? const AppFailure('noSubtitles')
              : AppFailure(
                  'subtitleLanguageUnavailable',
                  job.options.subtitles,
                );
        } else {
          job.subtitleTracks.addAll(
            selected.map((t) => SubtitleTrack.fromJson(t.toJson())),
          );
          job.attachments.remove('subtitles');
          for (final track in job.subtitleTracks) {
            job.attachments[track.key] = AttachmentResult()
              ..label = '${track.label} [${track.language}]'
              ..automatic = track.automatic;
          }
        }
      } catch (error) {
        _attachmentFailure(job, group, error);
      }
      await job.checkpoint();
      changed();
      if (job.subtitleTracks.isEmpty) return;
    }
    final pending = <SubtitleTrack>[];
    for (final track in job.subtitleTracks) {
      final result = job.attachments[track.key]!;
      if (result.state == AttachmentState.completed) continue;
      if (result.output != null &&
          job.publications.containsKey(result.output)) {
        result.state = AttachmentState.completed;
        result.error = null;
        await job.checkpoint();
        changed();
      } else {
        pending.add(track);
      }
    }
    if (pending.isEmpty) return;
    try {
      available ??= await api.subtitles(job.episode, cancel: job.token);
    } catch (error) {
      for (final track in pending) {
        _attachmentFailure(job, job.attachments[track.key]!, error);
      }
      await job.checkpoint();
      changed();
      return;
    }
    for (final track in pending) {
      if (job.token.isCancelled) throw job.token.cancelError!;
      final result = job.attachments[track.key]!
        ..state = AttachmentState.working
        ..error = null;
      await job.checkpoint();
      changed();
      try {
        final matches = available.where(
          (t) => t.key.toLowerCase() == track.key.toLowerCase(),
        );
        if (matches.isEmpty) throw const AppFailure('subtitleSourceChanged');
        final current = matches.first;
        if (current.locked) throw const AppFailure('subtitleLocked');
        final content = await api.fetchSubtitle(current, cancel: job.token);
        final duplicate =
            job.subtitleTracks
                .where(
                  (t) =>
                      t.language.toLowerCase() == track.language.toLowerCase(),
                )
                .length >
            1;
        final suffix =
            '${track.language}${duplicate ? '.${track.id}' : ''}.srt';
        result.output = p.join(directory, '$basename.$suffix');
        final temporary = File('$temp.$suffix');
        await temporary.writeAsString(content, flush: true);
        await _publishLocal(temporary, result.output!, job);
        result.state = AttachmentState.completed;
      } catch (error) {
        _attachmentFailure(job, result, error);
      }
      await job.checkpoint();
      changed();
    }
  }

  Future<void> _export(DownloadJob job) async {
    while (job.pendingExports.isNotEmpty) {
      if (job.token.isCancelled) throw job.token.cancelError!;
      final file = job.pendingExports.first;
      final destination = await publishFile(
        file,
        job.options.directory,
        job.options.flatDirectory ? '' : job.episode.folderName,
      );
      if (!job.outputs.contains(destination)) job.outputs.add(destination);
      job.exportedFiles[file] = destination;
      job.pendingExports.removeAt(0);
      await job.checkpoint();
      if (destination.startsWith('content://') && await File(file).exists()) {
        await File(file).delete();
      }
    }
    if (job.token.isCancelled) throw job.token.cancelError!;
  }

  Future<void> _publishLocal(
    File source,
    String output,
    DownloadJob job,
  ) async {
    if (await FileSystemEntity.type(output, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const AppFailure('fileExists');
    }
    final proof = Publication(
      source.path,
      await source.length(),
      (await sha256.bind(source.openRead()).first).toString(),
    );
    if (job.token.isCancelled) throw job.token.cancelError!;
    job.publications[output] = proof;
    await job.checkpoint();
    await _finishPublication(job, output, proof);
  }

  Future<void> _finishPublication(
    DownloadJob job,
    String output,
    Publication proof,
  ) async {
    if (job.exportedFiles.containsKey(output)) return;
    final target = File(output);
    if (await FileSystemEntity.type(output, followLinks: false) !=
        FileSystemEntityType.notFound) {
      if (await FileSystemEntity.type(output, followLinks: false) !=
              FileSystemEntityType.file ||
          await target.length() != proof.size ||
          (await sha256.bind(target.openRead()).first).toString() !=
              proof.digest) {
        throw const AppFailure('fileExists');
      }
    } else {
      final source = File(proof.source);
      if (!await source.exists() ||
          await source.length() != proof.size ||
          (await sha256.bind(source.openRead()).first).toString() !=
              proof.digest) {
        throw const AppFailure('outputMissing');
      }
      if (job.token.isCancelled) throw job.token.cancelError!;
      await source.rename(output);
    }
    if (!job.pendingExports.contains(output)) job.pendingExports.add(output);
    await job.checkpoint();
  }

  Future<void> _recoverPublications(DownloadJob job) async {
    for (final entry in job.publications.entries) {
      await _finishPublication(job, entry.key, entry.value);
    }
  }

  @override
  void dispose() => dio.close(force: true);
}
