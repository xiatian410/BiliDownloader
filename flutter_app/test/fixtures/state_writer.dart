// A separate process lets tests exercise OS locks and forced termination.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bili_downloader/core/file_state_store.dart';

Future<void> main(List<String> args) async {
  var interrupt = false;
  final store = FileStateStore(
    args.single,
    beforeReplace: (_) async {
      if (interrupt) {
        stdout.writeln('replacing');
        await Completer<void>().future;
      }
    },
  );
  await store.read();
  await store.write({'value': 1});
  stdout.writeln('locked');
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  interrupt = true;
  await store.write({'value': 2});
}
