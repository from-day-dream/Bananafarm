import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/addon_provider.dart';
import '../providers/api_keys_provider.dart';
import '../providers/theme_provider.dart' as theme_provider;
import '../theme/app_theme.dart';
import '../utils/toast_utils.dart';
import 'package:file_picker/file_picker.dart';
import '../providers/settings_provider.dart';
import '../services/notification_service.dart';

/// Settings tab: provider API keys, render preferences, app preferences,
/// and the Blender add-on export. (Kept as ProfileScreen so existing
/// navigation keeps working — there is no user profile anymore.)
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late TextEditingController _portController;
  late TextEditingController _maxJobsController;
  final _vastKeyController = TextEditingController();
  final _runpodKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final currentPort = ref.read(addonConnectionStatusProvider).port;
    _portController = TextEditingController(text: currentPort.toString());
    _portController.addListener(() {
      setState(() {}); // Rebuild to show/hide tick button
    });
    _maxJobsController = TextEditingController(
      text: ref.read(settingsProvider).maxConcurrentJobs.toString(),
    );
    _maxJobsController.addListener(() {
      setState(() {});
    });
    for (final c in [
      _vastKeyController,
      _runpodKeyController,
    ]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _portController.dispose();
    _maxJobsController.dispose();
    _vastKeyController.dispose();
    _runpodKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(theme_provider.themeProvider);
    final addonStatus = ref.watch(addonConnectionStatusProvider);
    final apiKeys = ref.watch(apiKeysProvider);
    final isDarkMode = themeMode == theme_provider.ThemeMode.dark;

    // Check if port has changed
    final isPortChanged =
        _portController.text.isNotEmpty &&
        _portController.text != addonStatus.port.toString();

    final settings = ref.watch(settingsProvider);
    final isMaxJobsChanged = _maxJobsController.text.isNotEmpty &&
        _maxJobsController.text != settings.maxConcurrentJobs.toString();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ============ API Keys ============
          Text(
            'API Keys',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Connect your own GPU cloud accounts. Providers with a saved key '
            'appear in the GPU selection when submitting a job.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),

          _buildApiKeyCard(
            context,
            isDarkMode: isDarkMode,
            title: 'Vast.ai',
            subtitle: 'console.vast.ai → Account → API Keys',
            controller: _vastKeyController,
            isConfigured: apiKeys.hasVast,
            onSave: (value) async {
              await ref.read(apiKeysProvider.notifier).setVastKey(value);
              _vastKeyController.clear();
              _showSaved('Vast.ai');
            },
            onClear: () async {
              await ref.read(apiKeysProvider.notifier).setVastKey(null);
              _showCleared('Vast.ai');
            },
          ),
          const SizedBox(height: 8),

          _buildApiKeyCard(
            context,
            isDarkMode: isDarkMode,
            title: 'RunPod',
            subtitle: 'Unlocks both Secure and Community cloud',
            controller: _runpodKeyController,
            isConfigured: apiKeys.hasRunpod,
            onSave: (value) async {
              await ref.read(apiKeysProvider.notifier).setRunpodKey(value);
              _runpodKeyController.clear();
              _showSaved('RunPod');
            },
            onClear: () async {
              await ref.read(apiKeysProvider.notifier).setRunpodKey(null);
              _showCleared('RunPod');
            },
          ),
          const SizedBox(height: 24),

          // ============ Rendering ============
          Text(
            'Rendering',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          // Max concurrent renders
          _buildInputCard(
            context,
            isDarkMode: isDarkMode,
            icon: Icons.grid_view,
            title: 'Max Concurrent Renders',
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _maxJobsController,
                decoration: _inputDecoration(
                  isDarkMode,
                  suffixIcon: isMaxJobsChanged
                      ? _tickButton(() {
                          final value = int.tryParse(_maxJobsController.text);
                          if (value != null && value > 0 && value <= 20) {
                            ref
                                .read(settingsProvider.notifier)
                                .setMaxConcurrentJobs(value);
                            ToastUtils.showSuccess(
                              ScaffoldMessenger.of(context),
                              'Max concurrent renders set to $value',
                            );
                          } else {
                            ToastUtils.showError(
                              ScaffoldMessenger.of(context),
                              'Enter a number between 1 and 20',
                            );
                          }
                        })
                      : null,
                ),
                style: Theme.of(context).textTheme.bodyMedium,
                keyboardType: TextInputType.number,
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Download Location Card
          _buildInputCard(
            context,
            isDarkMode: isDarkMode,
            icon: Icons.folder_open,
            title: 'Download Location',
            child: SizedBox(
              height: 40,
              child: InkWell(
                onTap: () async {
                  String? selectedDirectory = await FilePicker.platform
                      .getDirectoryPath(
                        dialogTitle: 'Select Download Location',
                        initialDirectory:
                            ref.read(settingsProvider).downloadPath,
                      );

                  if (selectedDirectory != null) {
                    ref
                        .read(settingsProvider.notifier)
                        .setDownloadPath(selectedDirectory);
                  }
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDarkMode ? Colors.grey[900] : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color:
                          isDarkMode ? Colors.grey[700]! : Colors.grey[300]!,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          ref.watch(settingsProvider).downloadPath ??
                              'Default (Downloads)',
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        Icons.folder_open,
                        size: 16,
                        color:
                            isDarkMode ? Colors.grey[400] : Colors.grey[600],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ============ Blender Add-on ============
          Text(
            'Blender Add-on',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          // Port Input Card
          _buildInputCard(
            context,
            isDarkMode: isDarkMode,
            icon: Icons.dns,
            title: 'Addon Port',
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _portController,
                decoration: _inputDecoration(
                  isDarkMode,
                  suffixIcon: isPortChanged
                      ? _tickButton(() {
                          final newPort = int.tryParse(_portController.text);
                          if (newPort != null &&
                              newPort > 0 &&
                              newPort < 65536) {
                            ref
                                .read(addonConnectionStatusProvider.notifier)
                                .setPort(newPort);
                            ToastUtils.showSuccess(
                              ScaffoldMessenger.of(context),
                              'Port updated to $newPort',
                            );
                          } else {
                            ToastUtils.showError(
                              ScaffoldMessenger.of(context),
                              'Invalid port number',
                            );
                          }
                        })
                      : null,
                ),
                style: Theme.of(context).textTheme.bodyMedium,
                keyboardType: TextInputType.number,
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Save add-on to disk
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide.none,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.extension, color: AppTheme.primary),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Save Blender Add-on',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            'Export bananafarm.py to install in Blender',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    ],
                  ),
                  OutlinedButton(
                    onPressed: _exportAddon,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ============ Preferences ============
          Text(
            'Preferences',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          _buildSwitchCard(
            context,
            icon: isDarkMode ? Icons.dark_mode : Icons.light_mode,
            title: 'Dark Mode',
            subtitle: isDarkMode ? 'Enabled' : 'Disabled',
            value: isDarkMode,
            onChanged: (value) {
              final themeNotifier =
                  ref.read(theme_provider.themeProvider.notifier);
              if (value) {
                themeNotifier.setDark();
              } else {
                themeNotifier.setLight();
              }
            },
          ),
          const SizedBox(height: 8),

          _buildSwitchCard(
            context,
            icon: Icons.minimize,
            title: 'Minimize to Tray',
            subtitle: 'Hide window to tray',
            value: ref.watch(settingsProvider).minimizeToTray,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).setMinimizeToTray(value);
            },
          ),
          const SizedBox(height: 8),

          // A denied OS permission looks exactly like a broken app, so say
          // which one it is rather than leaving the switch reading "on" while
          // nothing arrives.
          _buildSwitchCard(
            context,
            icon: NotificationService().permissionGranted
                ? Icons.notifications_active
                : Icons.notifications_off,
            title: 'Notifications',
            subtitle: NotificationService().permissionGranted
                ? 'Get job updates'
                : 'Blocked by macOS — allow Bananafarm in '
                    'System Settings › Notifications',
            value: ref.watch(settingsProvider).showNotifications,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).setShowNotifications(value);
            },
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ============================================
  // API key cards
  // ============================================

  Widget _buildApiKeyCard(
    BuildContext context, {
    required bool isDarkMode,
    required String title,
    required String subtitle,
    required TextEditingController controller,
    required bool isConfigured,
    required Future<void> Function(String value) onSave,
    required Future<void> Function() onClear,
  }) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.vpn_key, color: AppTheme.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 8),
                          if (isConfigured) _configuredChip(context),
                        ],
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (isConfigured)
                  IconButton(
                    tooltip: 'Remove key',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => onClear(),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: TextField(
                controller: controller,
                obscureText: true,
                decoration: _inputDecoration(
                  isDarkMode,
                  hintText:
                      isConfigured ? '••••••••  (saved)' : 'Paste API key',
                  suffixIcon: controller.text.trim().isNotEmpty
                      ? _tickButton(() => onSave(controller.text.trim()))
                      : null,
                ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _configuredChip(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        'Configured',
        style: TextStyle(fontSize: 10, color: Colors.green),
      ),
    );
  }

  void _showSaved(String providerName) {
    ToastUtils.showSuccess(
        ScaffoldMessenger.of(context), '$providerName credentials saved');
  }

  void _showCleared(String providerName) {
    ToastUtils.showSuccess(
        ScaffoldMessenger.of(context), '$providerName credentials removed');
  }

  // ============================================
  // Add-on export
  // ============================================

  Future<void> _exportAddon() async {
    try {
      final data = await rootBundle.load('assets/addon/bananafarm.py');
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Blender Add-on',
        fileName: 'bananafarm.py',
        type: FileType.custom,
        allowedExtensions: ['py'],
      );
      if (savePath == null) return;
      await File(savePath).writeAsBytes(data.buffer.asUint8List());
      if (mounted) {
        ToastUtils.showSuccess(
          ScaffoldMessenger.of(context),
          'Add-on saved — install it via Blender > Preferences > Add-ons',
        );
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError(
            ScaffoldMessenger.of(context), 'Failed to save add-on: $e');
      }
    }
  }

  // ============================================
  // Shared widgets
  // ============================================

  InputDecoration _inputDecoration(bool isDarkMode,
      {String? hintText, Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hintText,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: isDarkMode ? Colors.grey[800]! : Colors.grey[300]!,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: isDarkMode ? Colors.grey[700]! : Colors.grey[300]!,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.primary),
      ),
      filled: true,
      fillColor: isDarkMode ? Colors.grey[900] : Colors.white,
      suffixIcon: suffixIcon,
    );
  }

  Widget _tickButton(VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.all(6.0),
      child: Material(
        color: AppTheme.primary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const Icon(
            Icons.arrow_forward,
            color: Colors.black,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildInputCard(
    BuildContext context, {
    required bool isDarkMode,
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  child,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, color: AppTheme.primary),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
            Switch(
              value: value,
              activeColor: AppTheme.primary,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}
