import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Endpoint URL and device ID live in shared_preferences; the API key lives in
/// secure storage (Keychain / Android Keystore).
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs, {FlutterSecureStorage? secure})
    : _secure =
          secure ??
          const FlutterSecureStorage(
            // Plain login keychain on macOS: avoids the Keychain Sharing
            // entitlement, which would require a provisioning profile.
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const _endpointKey = 'settings.endpoint';
  static const _deviceIdKey = 'settings.deviceId';
  static const _apiKeyKey = 'settings.apiKey';
  static const _themeKey = 'settings.theme';
  static const _monoKey = 'settings.monoEditor';
  static const _deviceNameKey = 'settings.deviceName';

  String? _apiKey;

  Future<void> load() async {
    _apiKey = await _secure.read(key: _apiKeyKey);
    if (_prefs.getString(_deviceIdKey) == null) {
      await _prefs.setString(_deviceIdKey, 'flutter-${const Uuid().v4()}');
    }
  }

  /// Base URL of the function domain, without the `/shared` path.
  String get endpoint => _prefs.getString(_endpointKey) ?? '';
  String get apiKey => _apiKey ?? '';
  String get deviceId => _prefs.getString(_deviceIdKey)!;

  /// System / light / dark.
  ThemeMode get themeMode => switch (_prefs.getString(_themeKey)) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  /// Edit tab font: mono (default) or sans.
  bool get monoEditor => _prefs.getBool(_monoKey) ?? true;

  /// Friendly name shown on conflicts from this device.
  String get deviceName => _prefs.getString(_deviceNameKey) ?? '';

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString(_themeKey, mode.name);
    notifyListeners();
  }

  Future<void> setMonoEditor(bool mono) async {
    await _prefs.setBool(_monoKey, mono);
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    await _prefs.setString(_deviceNameKey, name.trim());
    notifyListeners();
  }

  /// Forget the connection (keeps device id and appearance).
  Future<void> disconnect() async {
    await _prefs.remove(_endpointKey);
    await _secure.delete(key: _apiKeyKey);
    _apiKey = null;
    notifyListeners();
  }

  bool get isConfigured => endpoint.isNotEmpty && apiKey.isNotEmpty;

  Future<void> save({required String endpoint, required String apiKey}) async {
    var url = endpoint.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/shared'))
      url = url.substring(0, url.length - '/shared'.length);
    await _prefs.setString(_endpointKey, url);
    await _secure.write(key: _apiKeyKey, value: apiKey.trim());
    _apiKey = apiKey.trim();
    notifyListeners();
  }
}
