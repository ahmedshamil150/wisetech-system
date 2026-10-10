import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../data/data_era.dart';
import '../shell/app_shell.dart';

/// Shown once to an admin after their first login so they can pick which
/// era to work in; the choice is remembered and switchable from the
/// profile menu. Viewers skip this and always get the current data.
class EraChoiceScreen extends ConsumerStatefulWidget {
  const EraChoiceScreen({super.key});

  @override
  ConsumerState<EraChoiceScreen> createState() => _EraChoiceScreenState();
}

class _EraChoiceScreenState extends ConsumerState<EraChoiceScreen> {
  @override
  Widget build(BuildContext context) {
    final auth = ref.read(authControllerProvider);
    final profile = ref.watch(profileProvider);
    final name = profile.maybeWhen(
          data: (p) => (p?['display_name'] ?? p?['username'] ?? '') as String,
          orElse: () => '',
        );
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose data view'),
        actions: [
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: () => auth.signOut(),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    name.isEmpty ? 'Welcome' : 'Welcome, $name',
                    style: textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Which stock view should we open?',
                    style: textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  _EraCard(
                    icon: Icons.archive_outlined,
                    title: 'Before 14-9-2026',
                    subtitle: 'The old stock as it was on 13 September 2026',
                    onTap: () => _choose(context, DataEra.before),
                  ),
                  const SizedBox(height: 12),
                  _EraCard(
                    icon: Icons.inventory_2_outlined,
                    title: 'After 14-9-2026',
                    subtitle:
                        'The current stock after the batch of 14 September',
                    onTap: () => _choose(context, DataEra.after),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'You can switch views any time from your profile menu.',
                    style: textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _choose(BuildContext context, DataEra era) async {
    ref.read(dataEraProvider.notifier).set(era);
    if (context.mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AppShell()),
      );
    }
  }
}

class _EraCard extends StatelessWidget {
  const _EraCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: colors.primary.withValues(alpha: 0.12),
                child: Icon(icon, color: colors.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: colors.outline),
            ],
          ),
        ),
      ),
    );
  }
}
