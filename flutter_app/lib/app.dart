import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_controller.dart';
import 'core/bili_api.dart';
import 'core/download_job.dart';
import 'core/models.dart';
import 'l10n/strings.dart';
import 'platform/platform.dart' as platform;

class BiliDownloaderApp extends StatelessWidget {
  const BiliDownloaderApp({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => MaterialApp(
      title: 'BiliDownloader',
      debugShowCheckedModeBanner: false,
      locale: Locale(controller.settings.locale),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: false,
        brightness: Brightness.light,
        fontFamily: 'HarmonyOS Sans SC',
        primarySwatch: Colors.blueGrey,
        scaffoldBackgroundColor: const Color(0xfff5f5f5),
        canvasColor: const Color(0xfffafafa),
        inputDecorationTheme: const InputDecorationTheme(
          isDense: true,
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            foregroundColor: const Color(0xff202020),
            backgroundColor: const Color(0xffeeeeee),
            elevation: 0,
            minimumSize: const Size(48, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(3),
              side: const BorderSide(color: Color(0xffd5d5d5)),
            ),
          ),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 15, height: 1.5),
        ),
      ),
      home: controller.initializing
          ? Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/icon.png', width: 48, height: 48),
                    const SizedBox(height: 16),
                    const Text('BiliDownloader'),
                    const SizedBox(height: 16),
                    const CircularProgressIndicator(),
                  ],
                ),
              ),
            )
          : _Home(controller: controller),
    ),
  );
}

class _Home extends StatefulWidget {
  const _Home({required this.controller});
  final AppController controller;
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _selection = TextEditingController();
  AppController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !kIsWeb &&
        c.settings.clipboard &&
        c.step == 0 &&
        _input.text.isEmpty) {
      unawaited(_paste(onlyValid: true));
    }
  }

  Future<void> _paste({bool onlyValid = false}) async {
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (mounted &&
          text != null &&
          (!onlyValid || VideoId.parse(text) != null)) {
        setState(() => _input.text = text);
      }
    } catch (e) {
      if (!onlyValid) c.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([c, c.queue]),
    builder: (context, _) {
      final s = Strings.of(context);
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1050),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: Row(
                      children: [
                        Image.asset('assets/icon.png', width: 24, height: 24),
                        const SizedBox(width: 8),
                        const Text(
                          'BiliDownloader',
                          style: TextStyle(fontSize: 16),
                        ),
                        const Spacer(),
                        const Text(
                          '2.0.0',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: ['input', 'downloads', 'settings', 'about']
                        .indexed
                        .map(
                          (e) => Expanded(
                            child: InkWell(
                              key: ValueKey('tab-${e.$1}'),
                              onTap: () => c.setTab(e.$1),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: c.tab == e.$1
                                      ? const Color(0xfffafafa)
                                      : const Color(0xffeeeeee),
                                  border: Border.all(
                                    color: const Color(0xffdddddd),
                                  ),
                                ),
                                child: Text(
                                  s(e.$2),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: c.tab == e.$1
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  if (c.busy) const LinearProgressIndicator(minHeight: 2),
                  if (c.error != null)
                    _message(
                      '${s(c.error!.key)}${c.error!.detail.isEmpty ? '' : '\n${c.error!.detail}'}',
                      error: true,
                      onClose: c.clearError,
                    ),
                  if (c.notice != null) _message(s(c.notice!)),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      decoration: BoxDecoration(
                        color: const Color(0xfffafafa),
                        border: Border.all(color: const Color(0xffdddddd)),
                      ),
                      child: Material(
                        color: const Color(0xfffafafa),
                        child: switch (c.tab) {
                          0 => _wizard(s),
                          1 => _downloads(s),
                          2 => _settings(s),
                          _ => _about(s),
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _message(String text, {bool error = false, VoidCallback? onClose}) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: error ? const Color(0xffffeeee) : const Color(0xfff1f3f5),
          border: Border.all(
            color: error ? const Color(0xffcc9999) : const Color(0xffcccccc),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                text,
                style: TextStyle(
                  fontSize: 13,
                  color: error ? const Color(0xff9c2222) : Colors.black87,
                ),
              ),
            ),
            if (onClose != null)
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
      );

  Widget _wizard(Strings s) {
    final valid = VideoId.parse(_input.text);
    final body = switch (c.step) {
      0 => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (kIsWeb) _message(s('webNotice')),
          Text(s('inputPrompt'), style: const TextStyle(fontSize: 17)),
          const SizedBox(height: 8),
          Text(s('inputHint')),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('video-input'),
            controller: _input,
            onChanged: (_) => setState(() {}),
            onSubmitted: valid == null || c.busy
                ? null
                : (_) => c.resolve(_input.text),
            decoration: InputDecoration(
              hintText: 'BV… / av… / md… / ep…',
              suffixIcon: IconButton(
                tooltip: s('paste'),
                onPressed: () => _paste(),
                icon: const Icon(Icons.content_paste, size: 20),
              ),
            ),
          ),
          if (valid != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${s('matched')}: ${valid.label}',
                style: const TextStyle(fontSize: 13, color: Colors.blueGrey),
              ),
            ),
        ],
      ),
      1 => _details(s),
      2 => _episodes(s),
      _ => _options(s),
    };
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: double.infinity, child: body),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (c.step > 0) ...[
                OutlinedButton(
                  onPressed: c.busy ? null : c.back,
                  child: Text(s('back')),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: ElevatedButton(
                  key: const ValueKey('wizard-next'),
                  onPressed: c.busy
                      ? null
                      : switch (c.step) {
                          0 =>
                            valid == null ? null : () => c.resolve(_input.text),
                          1 => c.nextFromDetails,
                          2 => c.selected.isEmpty ? null : c.loadOptions,
                          _ => kIsWeb ? null : c.enqueue,
                        },
                  child: Text(s(c.step == 3 ? 'submit' : 'next')),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _details(Strings s) {
    final info = c.info!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info.cover.isNotEmpty)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 270),
              child: Image.network(
                info.cover,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.video_library_outlined, size: 80),
              ),
            ),
          ),
        const SizedBox(height: 12),
        SelectableText(
          info.title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        SelectableText(info.id),
        if (info.author.isNotEmpty) Text('${s('author')}: ${info.author}'),
        const SizedBox(height: 12),
        SelectableText(info.description),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: kIsWeb || c.busy
              ? null
              : () => c.perform(() async {
                  final r = await c.api.dio.get<List<int>>(
                    info.cover,
                    options: Options(
                      responseType: ResponseType.bytes,
                      headers: biliHeaders,
                    ),
                  );
                  await platform.saveBytes(
                    Uint8List.fromList(r.data!),
                    '${safeFilename(info.title)}.jpg',
                    c.settings.directory,
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(s('saved'))));
                  }
                }),
          icon: const Icon(Icons.image_outlined, size: 18),
          label: Text(s('saveCover')),
        ),
      ],
    );
  }

  Widget _episodes(Strings s) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(s('episodes'), style: const TextStyle(fontSize: 18)),
      Wrap(
        spacing: 12,
        children: [
          TextButton(onPressed: c.selectAll, child: Text(s('selectAll'))),
          TextButton(onPressed: c.invertSelection, child: Text(s('invert'))),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _selection,
              decoration: InputDecoration(hintText: s('selectionHint')),
              onSubmitted: c.selectionText,
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => c.selectionText(_selection.text),
            child: Text(s('apply')),
          ),
        ],
      ),
      const SizedBox(height: 12),
      ...c.info!.episodes.indexed.map(
        (e) => CheckboxListTile(
          key: ValueKey('episode-${e.$1}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text('${e.$2.number}. ${e.$2.name}'),
          value: c.selected.contains(e.$1),
          onChanged: (v) => c.changeSelection(e.$1, v == true),
        ),
      ),
    ],
  );

  Widget _drop<T>(
    String label,
    T value,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T?> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: items,
      onChanged: c.busy ? null : onChanged,
    ),
  );
  List<DropdownMenuItem<int>> get _codecs => const [
    DropdownMenuItem(value: 7, child: Text('H.264 / AVC')),
    DropdownMenuItem(value: 12, child: Text('H.265 / HEVC')),
    DropdownMenuItem(value: 13, child: Text('AV1')),
  ];
  Widget _toggle(
    Strings s,
    String key,
    bool value,
    ValueChanged<bool> changed,
  ) => CheckboxListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    controlAffinity: ListTileControlAffinity.leading,
    title: Text(s(key)),
    value: value,
    onChanged: (v) {
      changed(v == true);
      unawaited(c.saveSettings());
    },
  );

  Widget _directory(Strings s) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s('directory')),
        const SizedBox(height: 5),
        SelectableText(
          c.settings.directory.isEmpty ? '—' : c.settings.directory,
          style: const TextStyle(fontSize: 13),
        ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: kIsWeb || c.busy
                  ? null
                  : () => c.perform(() async {
                      final d = await platform.chooseDirectory();
                      if (d != null) {
                        c.settings.directory = d;
                        await c.saveSettings();
                      }
                    }),
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(s('chooseDirectory')),
            ),
            TextButton(
              onPressed: kIsWeb || c.busy
                  ? null
                  : () => c.perform(
                      () => platform.openDirectory(c.settings.directory),
                    ),
              child: Text(s('openDirectory')),
            ),
          ],
        ),
        if (platform.isAndroid)
          Text(
            s('androidStorage'),
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
      ],
    ),
  );

  Widget _options(Strings s) {
    final media = c.media!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _drop(
          s('quality'),
          c.quality,
          media.qualities
              .map((q) => DropdownMenuItem(value: q.id, child: Text(q.label)))
              .toList(),
          (v) => setState(() => c.quality = v!),
        ),
        _drop(s('codec'), c.settings.codec, _codecs, (v) {
          c.settings.codec = v!;
          c.saveSettings();
        }),
        _drop(s('specialAudio'), c.specialAudio, [
          DropdownMenuItem(value: '', child: Text(s('original'))),
          if (media.flac != null)
            const DropdownMenuItem(value: 'flac', child: Text('Hi-Res / FLAC')),
          if (media.dolby != null)
            const DropdownMenuItem(value: 'dolby', child: Text('Dolby')),
        ], (v) => setState(() => c.specialAudio = v!)),
        if (media.languages.isNotEmpty)
          _drop(s('aiLanguage'), c.audioLanguage, [
            DropdownMenuItem(value: '', child: Text(s('original'))),
            ...media.languages.entries.map(
              (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
            ),
          ], (v) => setState(() => c.audioLanguage = v!)),
        _directory(s),
        const Divider(),
        _toggle(
          s,
          'onlyAudio',
          c.settings.onlyAudio,
          (v) => c.settings.onlyAudio = v,
        ),
        _toggle(
          s,
          'danmaku',
          c.settings.danmaku,
          (v) => c.settings.danmaku = v,
        ),
        const Divider(),
        ...((c.selected.toList()..sort()).map(
          (i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${c.info!.episodes[i].number}. ${c.info!.episodes[i].name}',
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    FilterChip(
                      label: Text(s('onlyAudio')),
                      selected: c.audioOnlyOverrides[i] ?? c.settings.onlyAudio,
                      onSelected: (v) =>
                          setState(() => c.audioOnlyOverrides[i] = v),
                    ),
                    FilterChip(
                      label: Text(s('danmaku')),
                      selected: c.danmakuOverrides[i] ?? c.settings.danmaku,
                      onSelected: (v) =>
                          setState(() => c.danmakuOverrides[i] = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
        )),
        if (kIsWeb) _message(s('webDownloadUnsupported')),
      ],
    );
  }

  Widget _downloads(Strings s) => Column(
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: c.queue.clearCompleted,
          child: Text(s('clearCompleted')),
        ),
      ),
      Expanded(
        child: c.queue.jobs.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.download_outlined,
                      size: 48,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 12),
                    Text(s('emptyQueue')),
                    Text(
                      s('emptyHint'),
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: c.queue.jobs.length,
                itemBuilder: (context, i) {
                  final job = c.queue.jobs[i];
                  final status = job.error == null
                      ? s(job.active ? job.stage : job.state.name)
                      : '${s(job.error!.key)} ${job.error!.detail}';
                  return Container(
                    margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: const Color(0xffdddddd)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          job.episode.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          job.episode.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: job.total > 0
                              ? (job.received / job.total).clamp(0, 1)
                              : 0,
                          minHeight: 7,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          status,
                          style: TextStyle(
                            fontSize: 13,
                            color: job.error == null
                                ? Colors.black87
                                : Colors.red.shade700,
                          ),
                        ),
                        if (job.detail.isNotEmpty)
                          Text(
                            s(job.detail),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.orange,
                            ),
                          ),
                        Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '${_size(job.received)} / ${_size(job.total)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            if (job.actualQuality != null)
                              Text(
                                '${s('actualQuality')}: ${job.actualQuality}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            if (job.canPause)
                              IconButton(
                                tooltip: s('pause'),
                                onPressed: () => c.queue.pause(job),
                                icon: const Icon(Icons.pause),
                              ),
                            if ([
                              JobState.paused,
                              JobState.failed,
                            ].contains(job.state))
                              IconButton(
                                tooltip: s(
                                  job.state == JobState.paused
                                      ? 'resume'
                                      : 'retry',
                                ),
                                onPressed: () => c.queue.resume(job),
                                icon: Icon(
                                  job.state == JobState.paused
                                      ? Icons.play_arrow
                                      : Icons.refresh,
                                ),
                              ),
                            IconButton(
                              tooltip: s('openDirectory'),
                              onPressed: () => c.perform(
                                () => platform.openDirectory(
                                  job.exportedDirectory ??
                                      job.options.directory,
                                ),
                              ),
                              icon: const Icon(Icons.folder_open),
                            ),
                            if (platform.isAndroid &&
                                job.state == JobState.completed &&
                                job.outputs.any(
                                  (p) => !p.startsWith('content://'),
                                ))
                              TextButton(
                                onPressed: c.busy
                                    ? null
                                    : () => c.perform(() async {
                                        final directory = await platform
                                            .chooseDirectory();
                                        if (directory == null) return;
                                        for (
                                          var n = 0;
                                          n < job.outputs.length;
                                          n++
                                        ) {
                                          if (job.outputs[n].startsWith(
                                            'content://',
                                          )) {
                                            continue;
                                          }
                                          job.outputs[n] = await platform
                                              .publishFile(
                                                job.outputs[n],
                                                directory,
                                                safeFilename(
                                                  job.episode.title,
                                                  limit: job.options.limitTitle,
                                                ),
                                              );
                                        }
                                        job.exportedDirectory = directory;
                                      }),
                                child: Text(s('exportFiles')),
                              ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Widget _settings(Strings s) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      _directory(s),
      const Divider(),
      Row(
        children: [
          Expanded(child: Text(s(c.loggedIn ? 'loggedIn' : 'loggedOut'))),
          if (c.loggedIn)
            TextButton(
              onPressed: c.busy ? null : c.logout,
              child: Text(s('logout')),
            ),
          ElevatedButton(
            onPressed: kIsWeb || c.busy
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (_) => _LoginDialog(controller: c),
                  ),
            child: Text(s('login')),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        s('membership'),
        style: const TextStyle(fontSize: 13, color: Colors.black54),
      ),
      const Divider(height: 28),
      _drop(
        s('language'),
        c.settings.locale,
        const [
          DropdownMenuItem(value: 'zh', child: Text('简体中文')),
          DropdownMenuItem(value: 'en', child: Text('English')),
        ],
        (v) {
          c.settings.locale = v!;
          c.saveSettings();
        },
      ),
      _drop(
        s('concurrency'),
        c.settings.concurrency,
        List.generate(
          8,
          (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
        ),
        (v) {
          c.settings.concurrency = v!;
          c.saveSettings();
        },
      ),
      _drop(s('codec'), c.settings.codec, _codecs, (v) {
        c.settings.codec = v!;
        c.saveSettings();
      }),
      _toggle(
        s,
        'onlyAudio',
        c.settings.onlyAudio,
        (v) => c.settings.onlyAudio = v,
      ),
      _toggle(
        s,
        'reserveAudio',
        c.settings.reserveAudio,
        (v) => c.settings.reserveAudio = v,
      ),
      _toggle(s, 'danmaku', c.settings.danmaku, (v) => c.settings.danmaku = v),
      _toggle(s, 'ultra', c.settings.ultra, (v) => c.settings.ultra = v),
      _toggle(s, 'dolby', c.settings.dolby, (v) => c.settings.dolby = v),
      _toggle(
        s,
        'clipboard',
        c.settings.clipboard,
        (v) => c.settings.clipboard = v,
      ),
      _toggle(
        s,
        'limitTitle',
        c.settings.limitTitle,
        (v) => c.settings.limitTitle = v,
      ),
      if (kIsWeb) _message(s('webNotice')),
    ],
  );

  Widget _about(Strings s) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Image.asset('assets/icon.png', width: 72, height: 72),
      ),
      const SizedBox(height: 16),
      const Text('BiliDownloader 2.0.0', style: TextStyle(fontSize: 24)),
      const SizedBox(height: 12),
      Text(s('aboutText')),
      const SizedBox(height: 12),
      Text(s('membership')),
      const SizedBox(height: 20),
      TextButton(
        onPressed: () => launchUrl(
          Uri.parse('https://github.com/xiatian410/BiliDownloader'),
        ),
        child: Text(s('project')),
      ),
      TextButton(
        onPressed: () => showLicensePage(
          context: context,
          applicationName: 'BiliDownloader',
          applicationVersion: '2.0.0',
          applicationLegalese: 'Original project © 2021–2026 Majjcom · MIT',
        ),
        child: Text(s('licenses')),
      ),
      if (kIsWeb) _message(s('webNotice')),
    ],
  );
  String _size(int n) => n >= 1073741824
      ? '${(n / 1073741824).toStringAsFixed(2)} GiB'
      : n >= 1048576
      ? '${(n / 1048576).toStringAsFixed(1)} MiB'
      : '${(n / 1024).toStringAsFixed(1)} KiB';
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog({required this.controller});
  final AppController controller;
  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  CancelToken? _token;
  LoginQr? _qr;
  String _status = 'loading';
  AppFailure? _error;
  bool _finished = false;
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _token?.cancel('dialog closed');
    super.dispose();
  }

  Future<void> _start() async {
    _token?.cancel();
    final token = _token = CancelToken();
    setState(() {
      _qr = null;
      _error = null;
      _status = 'loading';
      _finished = false;
    });
    try {
      final qr = await widget.controller.api.generateQr(cancel: token);
      if (!mounted || token.isCancelled) return;
      setState(() {
        _qr = qr;
        _status = 'scanQr';
      });
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      for (
        var count = 0;
        count < 150 && DateTime.now().isBefore(deadline);
        count++
      ) {
        if (token.isCancelled) throw token.cancelError!;
        final response = await widget.controller.api.pollQr(qr, cancel: token);
        if (!mounted || token.isCancelled) return;
        if (response.code == 0) {
          await widget.controller.acceptLogin(response.cookies);
          if (mounted) Navigator.of(context).pop();
          return;
        }
        if (response.code == 86038) break;
        if (![86101, 86090].contains(response.code)) {
          throw AppFailure('invalidLogin', '${response.code}');
        }
        setState(
          () => _status = response.code == 86090 ? 'confirmLogin' : 'scanQr',
        );
        await Future.any([
          Future<void>.delayed(const Duration(milliseconds: 1200)),
          token.whenCancel,
        ]);
      }
      if (mounted && !token.isCancelled) {
        setState(() {
          _status = 'qrExpired';
          _finished = true;
        });
      }
    } catch (e) {
      if (mounted && !token.isCancelled) {
        setState(() {
          _error = e is AppFailure ? e : AppFailure('networkError');
          _finished = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return AlertDialog(
      title: Text(s('login')),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_qr != null)
              QrImageView(
                data: _qr!.url,
                size: 240,
                backgroundColor: Colors.white,
              )
            else if (!_finished)
              const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(s(_error?.key ?? _status)),
          ],
        ),
      ),
      actions: [
        if (_finished) TextButton(onPressed: _start, child: Text(s('retry'))),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s('cancel')),
        ),
      ],
    );
  }
}
