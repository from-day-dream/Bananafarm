import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart' as rp;

import '../models/instance_models.dart';
import '../models/render_provider.dart';
import '../services/providers/provider_service_factory.dart';
import 'api_keys_provider.dart';

/// Account balance per provider family, fetched with the user's own key.
///
/// Refreshes every minute while something is watching it (the dashboard),
/// and is invalidated by the job manager whenever an instance is created or
/// deleted, since those are the moments the balance's burn rate changes.
final balanceProvider = rp.FutureProvider.autoDispose
    .family<ProviderBalance, RenderProviderFamily>((ref, family) async {
  final timer = Timer(const Duration(minutes: 1), ref.invalidateSelf);
  ref.onDispose(timer.cancel);

  final keys = ref.watch(apiKeysProvider);
  // Both tiers of a family share one account; either service can answer.
  final service = buildProviderService(family.resolve(false), keys);
  return service.getBalance();
});
