import 'package:flutter_test/flutter_test.dart';
import 'package:bananafarm/providers/addon_provider.dart';

void main() {
  final now = DateTime(2026, 1, 1, 12, 0, 0);

  group('addonSeenRecently', () {
    test('never-seen addon is not connected', () {
      expect(addonSeenRecently(null, now: now), isFalse);
    });

    test('fresh heartbeat counts as connected', () {
      expect(addonSeenRecently(now.subtract(const Duration(seconds: 15)), now: now), isTrue);
    });

    test('heartbeat close to the window edge counts as connected', () {
      expect(
        addonSeenRecently(
          now.subtract(const Duration(seconds: 44)),
          now: now,
        ),
        isTrue,
      );
    });

    test('three missed beats flips the badge to inactive', () {
      expect(
        addonSeenRecently(
          now.subtract(const Duration(seconds: 46)),
          now: now,
        ),
        isFalse,
      );
    });

    test('exactly at the window boundary is not connected', () {
      expect(
        addonSeenRecently(
          now.subtract(const Duration(seconds: 45)),
          now: now,
        ),
        isFalse,
      );
    });
  });
}
