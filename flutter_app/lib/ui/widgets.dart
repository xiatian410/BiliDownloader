import 'package:flutter/material.dart';

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = 20});
  final Widget child;
  final double padding;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: EdgeInsets.all(padding), child: child),
  );
}

class StatusBanner extends StatelessWidget {
  const StatusBanner(
    this.message, {
    super.key,
    this.error = false,
    this.onClose,
  });
  final String message;
  final bool error;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? Icons.error_outline : Icons.info_outline,
            size: 20,
            color: error
                ? colors.onErrorContainer
                : colors.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              container: true,
              liveRegion: true,
              label: message,
              excludeSemantics: true,
              child: SelectableText(
                message,
                style: TextStyle(
                  color: error
                      ? colors.onErrorContainer
                      : colors.onSecondaryContainer,
                ),
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
  }
}

class PageHeading extends StatelessWidget {
  const PageHeading(this.title, this.subtitle, {super.key});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

String fileSize(int n) => n >= 1073741824
    ? '${(n / 1073741824).toStringAsFixed(2)} GiB'
    : n >= 1048576
    ? '${(n / 1048576).toStringAsFixed(1)} MiB'
    : '${(n / 1024).toStringAsFixed(1)} KiB';
