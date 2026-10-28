import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../l10n/strings.dart';
import 'widgets.dart';

class ServiceAccessPage extends StatefulWidget {
  const ServiceAccessPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<ServiceAccessPage> createState() => _ServiceAccessPageState();
}

class _ServiceAccessPageState extends State<ServiceAccessPage> {
  final _key = TextEditingController();
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  void submit() {
    final c = widget.controller;
    if (c.busy || !_form.currentState!.validate()) return;
    final key = _key.text.trim();
    FocusScope.of(context).unfocus();
    _key.clear();
    c.connectService(key, newWorkspace: c.serviceAccess!.serviceSessionLost);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final access = c.serviceAccess!;
    final s = Strings.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Panel(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: 36,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'BiliDownloader',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        s(
                          access.serviceSessionLost
                              ? 'serviceWorkspaceLost'
                              : 'serviceAccessIntro',
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (access.requiresServiceKey)
                        TextFormField(
                          key: const ValueKey('service-access-key'),
                          controller: _key,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: s('serviceKey'),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? s('serviceKeyRequired')
                              : null,
                          onFieldSubmitted: (_) => submit(),
                        ),
                      if (c.error != null &&
                          ![
                            'serviceAccessRequired',
                            'serviceSessionExpired',
                          ].contains(c.error!.key)) ...[
                        const SizedBox(height: 12),
                        StatusBanner(s(c.error!.key), error: true),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: c.busy ? null : submit,
                        child: Text(
                          s(
                            access.serviceSessionLost
                                ? 'newServiceWorkspace'
                                : 'connectService',
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: c.busy
                            ? null
                            : () => c.perform(
                                () => c.queue.reconnect(force: true),
                              ),
                        child: Text(s('reconnectService')),
                      ),
                      if (c.busy) const LinearProgressIndicator(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
