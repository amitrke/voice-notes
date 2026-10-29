import 'package:flutter/material.dart';

/// Warns that a summary or clinical note predates the current recordings.
class StaleBanner extends StatelessWidget {
  final String message;
  final bool busy;
  final VoidCallback onRegenerate;
  const StaleBanner({
    super.key,
    required this.message,
    required this.busy,
    required this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.update, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Text(
                  'Out of date',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(message, style: TextStyle(color: scheme.onErrorContainer)),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy ? null : onRegenerate,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(busy ? 'Working…' : 'Regenerate'),
            ),
          ],
        ),
      ),
    );
  }
}
