import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/settings_store.dart';
import 'data/assets_repository.dart';
import 'data/shared_repository.dart';
import 'theme/vb_theme.dart';
import 'ui/shared_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsStore(prefs);
  await settings.load();
  final repo = SharedRepository(prefs, settings);
  // Cached content shows immediately; the first pull runs in the background.
  unawaited(repo.init());
  final assets = AssetsRepository(prefs, settings);
  runApp(VaultBridgeApp(repo: repo, settings: settings, assets: assets));
}

class VaultBridgeApp extends StatelessWidget {
  const VaultBridgeApp({
    super.key,
    required this.repo,
    required this.settings,
    required this.assets,
  });

  final SharedRepository repo;
  final SettingsStore settings;
  final AssetsRepository assets;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'VaultBridge',
        debugShowCheckedModeBanner: false,
        themeMode: settings.themeMode,
        theme: buildVbTheme(Brightness.light, monoEditor: settings.monoEditor),
        darkTheme: buildVbTheme(
          Brightness.dark,
          monoEditor: settings.monoEditor,
        ),
        home: SharedScreen(repo: repo, settings: settings, assets: assets),
      ),
    );
  }
}
