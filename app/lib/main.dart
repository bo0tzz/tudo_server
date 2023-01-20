import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tudo_app/auth/auth_provider.dart';
import 'package:tudo_app/extensions.dart';
import 'package:tudo_app/settings/settings_provider.dart';
import 'package:tudo_app/util/build_info.dart';
import 'package:tudo_app/util/store.dart';
import 'package:tudo_app/util/themes.dart';

import 'common/value_builders.dart';
import 'contacts/contact_provider.dart';
import 'crdt/hive_adapters.dart';
import 'crdt/tudo_crdt.dart';
import 'lists/list_manager_page.dart';
import 'lists/list_provider.dart';
import 'sync/sync_provider.dart';

void main() async {
  // Emulate platform
  // debugDefaultTargetPlatformOverride = TargetPlatform.android;
  // debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

  WidgetsFlutterBinding.ensureInitialized();

  await _setSystemColors();

  final dir = PlatformX.isMobile
      ? (await getApplicationDocumentsDirectory()).path
      : 'store';
  Hive.init(dir);
  Hive.registerAdapter(HlcAdapter(1));

  await BuildInfo.init();

  final storeProvider = await StoreProvider.open();
  final crdt = await TudoCrdt.open('$dir/tudo.db');

  runApp(
    MultiProvider(
      providers: [
        Provider.value(value: storeProvider),
        Provider(create: (c) => SettingsProvider(c.storeProvider)),
        Provider(create: (c) => AuthProvider(c.storeProvider)),
        Provider(create: (c) => ContactProvider(c.authProvider.userId, crdt)),
        Provider(
            create: (c) =>
                ListProvider(c.authProvider.userId, crdt, c.storeProvider)),
        Provider(
            create: (c) => SyncProvider(c.authProvider, c.storeProvider, crdt)),
      ],
      child: const TudoApp(),
    ),
  );
}

class TudoApp extends StatefulWidget {
  const TudoApp({Key? key}) : super(key: key);

  @override
  State<TudoApp> createState() => _TudoAppState();
}

class _TudoAppState extends State<TudoApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    manageConnection(AppLifecycleState.resumed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    manageConnection(state);
  }

  @override
  Widget build(BuildContext context) {
    return ValueStreamBuilder<ThemeMode>(
      stream: context.settingsProvider.theme,
      builder: (_, theme) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'tudo',
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [
          Locale('en'),
          ...AppLocalizations.supportedLocales,
        ],
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: theme,
        home: const ListManagerPage(),
      ),
    );
  }

  void manageConnection(AppLifecycleState state) {
    final syncProvider = context.read<SyncProvider>();
    final appVisible = (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive);
    if (appVisible) {
      syncProvider.connect();
    } else {
      syncProvider.disconnect();
    }
  }
}

// Hack around a bug on earlier Android versions
// https://github.com/flutter/flutter/issues/90098
Future<void> _setSystemColors() async {
  final navigationBarColor = !Platform.isAndroid ||
          ((await DeviceInfoPlugin().androidInfo).version.sdkInt) >= 29
      ? Colors.transparent
      : Colors.black38;

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: navigationBarColor,
  ));
}
