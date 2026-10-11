import 'package:bananafarm/models/job_model.dart';
import 'package:bananafarm/models/render_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// `RenderProviderX.fromId` throws on an unknown id, and `RenderJob.fromJson`
/// does not guard the call — so an id this function stops recognising makes
/// every saved job on disk unloadable, not just the affected one. Nothing
/// covered that before the secure/standard split added a value to the enum.
void main() {
  group('id round-trip', () {
    test('every value survives a write/read cycle', () {
      for (final provider in RenderProvider.values) {
        expect(RenderProviderX.fromId(provider.id), provider,
            reason: '${provider.name} did not round-trip through "${provider.id}"');
      }
    });

    test('ids are unique', () {
      final ids = RenderProvider.values.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate id: $ids');
    });
  });

  group('records written by older builds still load', () {
    test('"vast" stays the standard tier, not the datacenter one', () {
      // Before the split, Vast searches sent no datacenter filter — the wider
      // pool. Mapping this to vastSecure would retroactively claim those jobs
      // ran on trusted datacenter hosts, which is not what they searched.
      expect(RenderProviderX.fromId('vast'), RenderProvider.vast);
    });

    test('bare "runpod" still means the secure cloud', () {
      expect(RenderProviderX.fromId('runpod'), RenderProvider.runpodSecure);
    });

    test('an unknown id throws rather than guessing', () {
      expect(() => RenderProviderX.fromId('lambda'), throwsArgumentError);
    });
  });

  group('family <-> tier', () {
    test('resolve inverts family/isSecureTier for every value', () {
      for (final provider in RenderProvider.values) {
        expect(provider.family.resolve(provider.isSecureTier), provider,
            reason: '${provider.name} did not survive the family round-trip');
      }
    });

    test('each family resolves to a distinct pair', () {
      for (final family in RenderProviderFamily.values) {
        final off = family.resolve(false);
        final on = family.resolve(true);
        expect(off.family, family);
        expect(on.family, family);
        if (family.supportsSecure) {
          expect(on, isNot(off), reason: '${family.name} needs two tiers');
          expect(on.isSecureTier, isTrue);
          expect(off.isSecureTier, isFalse);
        } else {
          // A family with one tier ignores the flag, so the picker can carry
          // a stale `secure` across a provider change without normalising it.
          expect(on, off, reason: '${family.name} has only one tier');
          expect(on.isSecureTier, isFalse);
        }
      }
    });

    test('Salad is the single-tier family; Vast and RunPod are not', () {
      expect(RenderProviderFamily.salad.supportsSecure, isFalse);
      expect(RenderProviderFamily.vast.supportsSecure, isTrue);
      expect(RenderProviderFamily.runpod.supportsSecure, isTrue);
    });
  });

  group('saved jobs', _legacyJobRecords);

  test('both tiers of a family reach the same container PROVIDER value', () {
    // The container branches its bind host on this, and the marketplace tier
    // is invisible to it.
    expect(RenderProvider.vastSecure.containerProviderName,
        RenderProvider.vast.containerProviderName);
    expect(RenderProvider.runpodSecure.containerProviderName,
        RenderProvider.runpodCommunity.containerProviderName);
  });
}

/// The actual failure this design guards against: a job record written before
/// the split must still deserialize. `RenderJob.fromJson` calls `fromId`
/// unguarded, so one unrecognised id throws out of the whole job load.
void _legacyJobRecords() {
  Map<String, dynamic> record(String providerId) => {
        'id': 'job-1',
        'status': 'completed',
        'provider': providerId,
        'gpu_name': 'RTX 4090',
        'price_per_hour': 0.4,
        'gpu_offer': {
          'provider': providerId,
          'gpu_name': 'RTX 4090',
          'gpu_id': 'RTX 4090',
          'price_per_hour': 0.4,
        },
        'api_token': 'tok',
        'blender_version': '4.2.1',
        'render_params': <String, dynamic>{},
        'created_at': DateTime.utc(2025, 1, 1).toIso8601String(),
      };

  test('a pre-split "vast" job still loads, tier and all', () {
    final job = RenderJob.fromJson(record('vast'));
    expect(job.provider, RenderProvider.vast);
    expect(job.provider.isSecureTier, isFalse);
    expect(job.gpuOffer?.provider, RenderProvider.vast);
  });

  test('a legacy bare "runpod" job still loads', () {
    expect(RenderJob.fromJson(record('runpod')).provider,
        RenderProvider.runpodSecure);
  });

  test('a job written by this build round-trips through disk', () {
    for (final provider in RenderProvider.values) {
      final restored =
          RenderJob.fromJson(RenderJob.fromJson(record(provider.id)).toJson());
      expect(restored.provider, provider);
    }
  });
}
