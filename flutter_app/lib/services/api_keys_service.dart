import 'local_storage_service.dart';

/// Local storage for the user's GPU provider API keys.
///
/// Stored via shared_preferences (LocalStorageService) rather than the OS
/// keystore: flutter_secure_storage's Windows plugin requires the ATL
/// component, which isn't part of a default Visual Studio Build Tools
/// install. Keys are therefore in plaintext local app data, not encrypted
/// at rest. Salad's org/project names are not secrets but are co-located
/// here to keep provider credentials in one place.
class ApiKeysService {
  static const _vastKeyKey = 'vast_api_key';
  static const _runpodKeyKey = 'runpod_api_key';
  static const _saladKeyKey = 'salad_api_key';
  static const _saladOrgKey = 'salad_org_name';
  static const _saladProjectKey = 'salad_project_name';

  LocalStorageService get _storage => LocalStorageService();

  Future<String?> getVastKey() async => _storage.getString(_vastKeyKey);
  Future<String?> getRunpodKey() async => _storage.getString(_runpodKeyKey);
  Future<String?> getSaladKey() async => _storage.getString(_saladKeyKey);
  Future<String?> getSaladOrg() async => _storage.getString(_saladOrgKey);
  Future<String?> getSaladProject() async =>
      _storage.getString(_saladProjectKey);

  Future<void> setVastKey(String? value) => _write(_vastKeyKey, value);
  Future<void> setRunpodKey(String? value) => _write(_runpodKeyKey, value);
  Future<void> setSaladKey(String? value) => _write(_saladKeyKey, value);
  Future<void> setSaladOrg(String? value) => _write(_saladOrgKey, value);
  Future<void> setSaladProject(String? value) => _write(_saladProjectKey, value);

  /// Marks the one-time clear of Salad credentials after Salad was withdrawn
  /// from the app, so the migration runs once rather than on every launch.
  static const _saladPurgedKey = 'salad_credentials_purged';

  Future<bool> saladCredentialsPurged() async =>
      _storage.getBool(_saladPurgedKey) ?? false;

  Future<void> markSaladCredentialsPurged() async =>
      _storage.saveBool(_saladPurgedKey, true);

  Future<void> _write(String key, String? value) async {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await _storage.saveString(key, '');
    } else {
      await _storage.saveString(key, trimmed);
    }
  }
}
