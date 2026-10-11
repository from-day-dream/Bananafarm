import '../../models/render_provider.dart';
import '../../providers/api_keys_provider.dart';
import 'gpu_provider_service.dart';
import 'runpod_api_service.dart';
import 'salad_api_service.dart';
import 'vast_api_service.dart';

/// Build the API client for [provider] from the user's stored credentials.
/// Throws [ProviderApiException] when the required keys are not configured.
GpuProviderService buildProviderService(
    RenderProvider provider, ApiKeysState keys) {
  switch (provider) {
    case RenderProvider.vast:
    case RenderProvider.vastSecure:
      if (!keys.hasVast) {
        throw ProviderApiException(provider, 'API key not configured');
      }
      return VastApiService(apiKey: keys.vastKey!, provider: provider);
    case RenderProvider.runpodSecure:
    case RenderProvider.runpodCommunity:
      if (!keys.hasRunpod) {
        throw ProviderApiException(provider, 'API key not configured');
      }
      return RunpodApiService(apiKey: keys.runpodKey!, provider: provider);
    case RenderProvider.salad:
      if (!keys.hasSalad) {
        throw ProviderApiException(
            provider, 'API key / organization / project not configured');
      }
      return SaladApiService(
        apiKey: keys.saladKey!,
        organization: keys.saladOrg!,
        project: keys.saladProject!,
      );
  }
}
