import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uni_links/uni_links.dart';

import 'list_manager/list_manager_page.dart';
import 'list_manager/list_provider.dart';
import 'util/hive/hive_adapters.dart';
import 'util/random_id.dart';
import 'util/sync_manager.dart';

void main() async {
  // Emulate platform
  // debugDefaultTargetPlatformOverride = TargetPlatform.android;
  // debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));

  final nodeId = generateRandomId(32);

  try {
    final dir = Platform.isAndroid || Platform.isIOS
        ? (await getApplicationDocumentsDirectory()).path
        : 'store';
    Hive.init(dir);
  } catch (_) {
    // Is web
    Hive.init('');
  }

  // Adapters
  Hive.registerAdapter(RecordAdapter(0));
  Hive.registerAdapter(ModRecordAdapter(1));
  Hive.registerAdapter(HlcAdapter(2, nodeId));
  Hive.registerAdapter(ToDoAdapter(3));
  Hive.registerAdapter(ColorAdapter(4));

  final listManager = await ListProvider.open(nodeId);
  _monitorDeeplinks(listManager);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: listManager),
        ChangeNotifierProxyProvider<ListProvider, SyncManager>(
          create: (_) => SyncManager(),
          update: (_, listManager, syncManager) =>
              syncManager..listManager = listManager,
        )
      ],
      child: MyApp(),
    ),
  );
}

void _monitorDeeplinks(ListProvider listManager) {
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      getInitialLink().then((link) async {
        if (link != null) {
          print('Initial link: $link');
          await listManager.import(link);
        }
      });
      getLinksStream().listen((link) async {
        print('Stream link: $link');
        await listManager.import(link);
      }).onError((e) => print(e));
    }
  } catch (_) {}
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  Timer reconnectTimer;

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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // themeMode: ThemeMode.light,
      title: 'tudo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.blue,
        primaryColor: Colors.blue,
        brightness: Brightness.dark,
      ),
      home: ListManagerPage(),
    );
  }

  void manageConnection(AppLifecycleState state) {
    final syncManager = context.read<SyncManager>();
    final appVisible = (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive);
    if (appVisible) {
      if (!(reconnectTimer?.isActive ?? false)) {
        reconnectTimer =
            Timer.periodic(Duration(seconds: 10), (_) => syncManager.connect());
        syncManager.connect();
      }
    } else {
      reconnectTimer?.cancel();
      syncManager.disconnect();
    }
  }
}
