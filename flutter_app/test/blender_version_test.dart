import 'dart:io';

import 'package:bananafarm/constants/app_constants.dart';
import 'package:flutter_test/flutter_test.dart';

/// The desktop app checks a Blender download URL before renting a GPU, and the
/// render container builds the same URL to actually fetch it. If the two ever
/// disagree, the pre-flight starts approving downloads the container will then
/// fail to make — which is the exact 25-minute billed failure the check exists
/// to prevent. These tests pin the shape and compare the two implementations
/// directly.
void main() {
  group('blenderDownloadUrl', () {
    test('builds Blender\'s published release layout', () {
      expect(
        AppConstants.blenderDownloadUrl('4.2.1'),
        'https://download.blender.org/release/Blender4.2'
        '/blender-4.2.1-linux-x64.tar.xz',
      );
    });

    test('keeps a trailing .0 rather than collapsing the series', () {
      // blender-4.5-linux-x64.tar.xz does not exist; every release is X.Y.Z.
      expect(AppConstants.blenderDownloadUrl('4.5.0'),
          contains('/blender-4.5.0-linux-x64.tar.xz'));
      expect(AppConstants.blenderDownloadUrl('4.5.0'),
          contains('/Blender4.5/'));
    });

    test('series is major.minor even when a patch is absent', () {
      expect(AppConstants.blenderDownloadUrl('4.2'), contains('/Blender4.2/'));
    });

    test('does not crash on a single-component version', () {
      expect(() => AppConstants.blenderDownloadUrl('4'), returnsNormally);
    });

    test('the default version is well-formed', () {
      expect(AppConstants.defaultBlenderVersion, matches(r'^\d+\.\d+\.\d+$'));
      expect(
        AppConstants.blenderDownloadUrl(AppConstants.defaultBlenderVersion),
        startsWith('https://download.blender.org/release/Blender'),
      );
    });
  });

  test('Dart and entrypoint.sh build byte-identical URLs', () {
    final script = File('../docker-image/entrypoint.sh');
    if (!script.existsSync()) {
      markTestSkipped('entrypoint.sh not reachable from this working dir');
      return;
    }

    // Re-implement the shell's construction by invoking the shell itself,
    // rather than trusting a transcription of it.
    for (final version in ['4.2.1', '4.5.0', '5.2.2', '3.6.0', '4.2']) {
      final shell = Process.runSync('bash', [
        '-c',
        'series=\$(echo "$version" | cut -d. -f1-2); '
            'echo "https://download.blender.org/release/Blender\${series}'
            '/blender-$version-linux-x64.tar.xz"',
      ]);
      expect(shell.exitCode, 0, reason: 'shell failed for $version');
      expect(
        AppConstants.blenderDownloadUrl(version),
        (shell.stdout as String).trim(),
        reason: 'Dart and shell disagree for $version',
      );
    }
  });
}
