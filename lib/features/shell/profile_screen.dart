import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final auth = ref.read(authControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My profile')),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load profile: $e')),
        data: (p) {
          final username = (p?['username'] ?? '') as String;
          final displayName = (p?['display_name'] ?? username) as String;
          final createdAt = (p?['created_at'] ?? '') as String;
          final isAdmin = (p?['role'] ?? 'viewer') == 'admin';
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: CircleAvatar(
                  radius: 40,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text(
                    displayName.isEmpty
                        ? '?'
                        : displayName.characters.first.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 32,
                        color: Colors.white,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(displayName,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              Center(
                child: Text('@$username',
                    style: const TextStyle(color: Color(0xFF5B6B7B))),
              ),
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: (isAdmin
                            ? const Color(0xFF1668A8)
                            : const Color(0xFF5B6B7B))
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isAdmin ? 'Administrator' : 'Viewer',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isAdmin
                            ? const Color(0xFF1668A8)
                            : const Color(0xFF5B6B7B)),
                  ),
                ),
              ),
              if (createdAt.isNotEmpty) ...[
                const SizedBox(height: 4),
                Center(
                  child: Text('Member since ${createdAt.split('T').first}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF8A97A3))),
                ),
              ],
              const SizedBox(height: 24),
              Card(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: Color(0xFFE2E9F0)),
                ),
                child: ListTile(
                  leading: Icon(isAdmin
                      ? Icons.verified_user_outlined
                      : Icons.visibility_outlined),
                  title: Text(isAdmin ? 'Administrator' : 'Viewer'),
                  subtitle: Text(isAdmin
                      ? 'Can add and edit products, records and sales.'
                      : 'Read-only access. You can still record movements.'),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => auth.signOut(),
                icon: const Icon(Icons.logout),
                label: const Text('Log out'),
              ),
            ],
          );
        },
      ),
    );
  }
}
