import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import '../theme/app_theme.dart';
import '../utils/toast_utils.dart';

/// Installs the bundled Blender add-on (shipped with this app version) into
/// a detected Blender installation's scripts/addons folder.
class AddonConfigModal extends ConsumerStatefulWidget {
  const AddonConfigModal({Key? key}) : super(key: key);

  @override
  ConsumerState<AddonConfigModal> createState() => _AddonConfigModalState();
}

class _AddonConfigModalState extends ConsumerState<AddonConfigModal> {
  final TextEditingController _locationController = TextEditingController();
  bool _isLoading = false;
  List<String> _detectedVersions = [];
  String? _rootBlenderPath;

  @override
  void initState() {
    super.initState();
    _initBlenderDetection();
  }

  Future<void> _initBlenderDetection() async {
    String rootPath = '';
    Map<String, String> env = Platform.environment;

    if (Platform.isMacOS) {
      final home = env['HOME'];
      if (home != null) {
        rootPath = path.join(home, 'Library', 'Application Support', 'Blender');
      }
    } else if (Platform.isWindows) {
      final appData = env['APPDATA'];
      if (appData != null) {
        rootPath = path.join(appData, 'Blender Foundation', 'Blender');
      }
    } else if (Platform.isLinux) {
      final home = env['HOME'];
      if (home != null) {
        rootPath = path.join(home, '.config', 'blender');
      }
    }

    if (rootPath.isNotEmpty) {
      _rootBlenderPath = rootPath;
      await _scanForVersions(rootPath);
    }
  }

  Future<void> _scanForVersions(String rootPath) async {
    final dir = Directory(rootPath);
    if (await dir.exists()) {
      try {
        final List<FileSystemEntity> entities = await dir.list().toList();
        final List<String> versions = [];

        for (var entity in entities) {
          if (entity is Directory) {
            final folderName = path.basename(entity.path);
            // Simple check for version-like folder names (e.g., "3.6", "4.0")
            if (RegExp(r'^\d+\.\d+$').hasMatch(folderName)) {
              versions.add(folderName);
            }
          }
        }

        // Sort versions descending (newest first)
        versions.sort((a, b) => b.compareTo(a));

        if (mounted) {
          setState(() {
            _detectedVersions = versions;
            // Auto-select the newest version if available and location is empty
            if (versions.isNotEmpty && _locationController.text.isEmpty) {
              _locationController.text = path.join(rootPath, versions.first);
            } else if (_locationController.text.isEmpty) {
              _locationController.text = rootPath;
            }
          });
        }
      } catch (e) {
        print('Error scanning for Blender versions: $e');
      }
    } else {
      if (mounted && _locationController.text.isEmpty) {
        setState(() {
          _locationController.text = rootPath;
        });
      }
    }
  }

  Future<void> _pickLocation() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Blender Location',
      initialDirectory: _locationController.text.isNotEmpty
          ? _locationController.text
          : _rootBlenderPath,
    );

    if (selectedDirectory != null) {
      setState(() {
        _locationController.text = selectedDirectory;
      });
    }
  }

  void _selectVersion(String version) {
    if (_rootBlenderPath != null) {
      setState(() {
        _locationController.text = path.join(_rootBlenderPath!, version);
      });
    }
  }

  Future<void> _installAddon() async {
    if (_locationController.text.isEmpty) {
      ToastUtils.showError(ScaffoldMessenger.of(context),
          'Please select a Blender location first');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final data = await rootBundle.load('assets/addon/bananafarm.py');

      // Construct path: {Blender Location}/scripts/addons/
      final addonsPath =
          path.join(_locationController.text, 'scripts', 'addons');
      final addonsDir = Directory(addonsPath);

      if (!await addonsDir.exists()) {
        await addonsDir.create(recursive: true);
      }

      final savePath = path.join(addonsPath, 'bananafarm.py');
      await File(savePath).writeAsBytes(data.buffer.asUint8List());

      if (mounted) {
        ToastUtils.showSuccess(
          ScaffoldMessenger.of(context),
          'Addon installed to: .../scripts/addons/bananafarm.py — enable it '
          'in Blender > Preferences > Add-ons',
        );
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError(
            ScaffoldMessenger.of(context), 'Failed to install addon: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Configure Addon',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Detected Installations Section
            if (_detectedVersions.isNotEmpty) ...[
              Text(
                'Blender Installations Found',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _detectedVersions.map((version) {
                  final isSelected = _rootBlenderPath != null &&
                      _locationController.text ==
                          path.join(_rootBlenderPath!, version);
                  return InkWell(
                    onTap: () => _selectVersion(version),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppTheme.primary.withOpacity(0.2)
                            : (isDark ? Colors.grey[800] : Colors.grey[200]),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color:
                              isSelected ? AppTheme.primary : Colors.transparent,
                        ),
                      ),
                      child: Text(
                        'Blender $version',
                        style: TextStyle(
                          color: isSelected
                              ? AppTheme.primary
                              : (isDark ? Colors.white : Colors.black),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],

            // Location Section
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _locationController,
                    readOnly: true,
                    decoration: InputDecoration(
                      hintText: 'Select Blender version folder...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _pickLocation,
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Select Folder',
                  style: IconButton.styleFrom(
                    backgroundColor:
                        isDark ? Colors.grey[800] : Colors.grey[200],
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Install bundled add-on
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isLoading ? null : _installAddon,
                icon: _isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.extension),
                label: const Text('Install Add-on'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Installs the add-on version bundled with this app.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
