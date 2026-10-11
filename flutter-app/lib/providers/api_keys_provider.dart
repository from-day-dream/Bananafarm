import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/render_provider.dart';
import '../services/api_keys_service.dart';

final apiKeysServiceProvider = Provider<ApiKeysService>((ref) {
  return ApiKeysService();
});

final apiKeysProvider =
    StateNotifierProvider<ApiKeysNotifier, ApiKeysState>((ref) {
  return ApiKeysNotifier(ref.watch(apiKeysServiceProvider));
});

/// Provider tiers the user has fully configured and that the app offers.
final configuredProvidersProvider = Provider<List<RenderProvider>>((ref) {
  return ref.watch(apiKeysProvider).configuredProviders;
});

class ApiKeysState {
  final bool isLoading;
  final String? vastKey;
  final String? runpodKey;
  final String? saladKey;
  final String? saladOrg;
  final String? saladProject;

  ApiKeysState({
    this.isLoading = true,
    this.vastKey,
    this.runpodKey,
    this.saladKey,
    this.saladOrg,
    this.saladProject,
  });

  bool get hasVast => vastKey != null && vastKey!.isNotEmpty;
  bool get hasRunpod => runpodKey != null && runpodKey!.isNotEmpty;
  bool get hasSalad =>
      saladKey != null &&
      saladKey!.isNotEmpty &&
      saladOrg != null &&
      saladOrg!.isNotEmpty &&
      saladProject != null &&
      saladProject!.isNotEmpty;

  /// Every tier the user can reach, not every provider — one Vast or RunPod
  /// key unlocks both that family's marketplaces. The GPU picker collapses
  /// these back to one dropdown entry per family.
  List<RenderProvider> get configuredProviders => [
        if (hasVast) RenderProvider.vast,
        if (hasVast) RenderProvider.vastSecure,
        if (hasRunpod) RenderProvider.runpodCommunity,
        if (hasRunpod) RenderProvider.runpodSecure,
        // Salad is withdrawn: its container groups reallocate across churning
        // consumer nodes, which wipes /tmp mid-job and takes finished frames
        // with it. The service, the enum value and the credential storage all
        // remain — only the offer is gone. Re-add this line to bring it back.
      ];

  bool isConfigured(RenderProvider provider) =>
      configuredProviders.contains(provider);

  ApiKeysState copyWith({
    bool? isLoading,
    String? vastKey,
    String? runpodKey,
    String? saladKey,
    String? saladOrg,
    String? saladProject,
  }) {
    return ApiKeysState(
      isLoading: isLoading ?? this.isLoading,
      vastKey: vastKey ?? this.vastKey,
      runpodKey: runpodKey ?? this.runpodKey,
      saladKey: saladKey ?? this.saladKey,
      saladOrg: saladOrg ?? this.saladOrg,
      saladProject: saladProject ?? this.saladProject,
    );
  }
}

class ApiKeysNotifier extends StateNotifier<ApiKeysState> {
  final ApiKeysService _service;

  ApiKeysNotifier(this._service) : super(ApiKeysState()) {
    _load();
  }

  Future<void> _load() async {
    final values = await Future.wait([
      _service.getVastKey(),
      _service.getRunpodKey(),
      _service.getSaladKey(),
      _service.getSaladOrg(),
      _service.getSaladProject(),
    ]);
    state = ApiKeysState(
      isLoading: false,
      vastKey: values[0],
      runpodKey: values[1],
      saladKey: values[2],
      saladOrg: values[3],
      saladProject: values[4],
    );
  }

  Future<void> setVastKey(String? value) async {
    await _service.setVastKey(value);
    await _load();
  }

  Future<void> setRunpodKey(String? value) async {
    await _service.setRunpodKey(value);
    await _load();
  }

  /// Clears stored Salad credentials once, on the first launch after Salad was
  /// withdrawn. Keyed so it never runs twice — a user who later re-enables
  /// Salad (see [ApiKeysState.configuredProviders]) should not have their new
  /// keys wiped by a migration that already ran.
  Future<void> purgeWithdrawnSaladCredentials() async {
    if (await _service.saladCredentialsPurged()) return;
    await _service.setSaladKey(null);
    await _service.setSaladOrg(null);
    await _service.setSaladProject(null);
    await _service.markSaladCredentialsPurged();
    await _load();
  }

  Future<void> setSaladCredentials({
    String? apiKey,
    String? organization,
    String? project,
  }) async {
    await _service.setSaladKey(apiKey);
    await _service.setSaladOrg(organization);
    await _service.setSaladProject(project);
    await _load();
  }
}
