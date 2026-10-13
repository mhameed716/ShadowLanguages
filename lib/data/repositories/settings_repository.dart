import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

/// Persists settings: preferences in `SharedPreferences`, the API key in the
/// Android Keystore (encrypted at rest, never backed up in plain text).
class SettingsRepository {
  SettingsRepository(this._prefs, this._secure);

  static const String _settingsKey = 'shadow_languages.settings.v1';
  static const String _apiKeyKey = 'shadow_languages.gemini_api_key';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  Future<AppSettings> load() async {
    final raw = _prefs.getString(_settingsKey);
    final apiKey = await _secure.read(key: _apiKeyKey) ?? '';
    if (raw == null || raw.isEmpty) {
      return AppSettings(apiKey: apiKey);
    }
    try {
      final decoded = _decode(raw);
      return AppSettings.fromJson(decoded, apiKey: apiKey);
    } catch (_) {
      return AppSettings(apiKey: apiKey);
    }
  }

  Future<void> save(AppSettings settings) async {
    await _prefs.setString(_settingsKey, _encode(settings.toJson()));
    final existing = await _secure.read(key: _apiKeyKey);
    if (settings.apiKey.isNotEmpty) {
      if (existing != settings.apiKey) {
        await _secure.write(key: _apiKeyKey, value: settings.apiKey.trim());
      }
    } else if (existing != null) {
      await _secure.delete(key: _apiKeyKey);
    }
  }

  Future<String?> readApiKey() => _secure.read(key: _apiKeyKey);

  Future<void> clearApiKey() => _secure.delete(key: _apiKeyKey);

  static Map<String, Object?> _decode(String raw) =>
      (jsonDecode(raw) as Map).cast<String, Object?>();

  static String _encode(Map<String, Object?> map) => jsonEncode(map);
}
