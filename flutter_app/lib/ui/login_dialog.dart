import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_controller.dart';
import '../core/bili_api.dart';
import '../core/models.dart';
import '../l10n/strings.dart';

class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key, required this.controller});
  final AppController controller;
  @override
  State<LoginDialog> createState() => LoginDialogState();
}

class LoginDialogState extends State<LoginDialog> {
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
