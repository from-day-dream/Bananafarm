import 'package:flutter_riverpod/flutter_riverpod.dart' as rp;
import '../models/gpu_offer.dart';
import '../models/render_provider.dart';
import '../services/providers/provider_service_factory.dart';
import 'api_keys_provider.dart';
import 'settings_provider.dart';

/// Live GPU list for one provider, fetched directly from the provider's API
/// with the user's key. Replaces the old get-all-gpus edge function.
final gpuOffersProvider = rp.FutureProvider.autoDispose
    .family<List<GpuOffer>, RenderProvider>((ref, provider) async {
  final keys = ref.watch(apiKeysProvider);
  final diskGb =
      ref.watch(settingsProvider.select((s) => s.instanceStorageGb));
  final service = buildProviderService(provider, keys);
  return service.listGpus(diskGb: diskGb);
});
