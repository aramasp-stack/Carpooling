import 'package:flutter/material.dart';
import 'package:transport_core/transport_core.dart';
import 'package:transport_ui/transport_ui.dart';

import 'home.dart';

/// TransportApp — приложение водителя. Демо-водитель — Арам.
/// Запуск с картой: flutter run --dart-define=MAPKIT_API_KEY=ваш-ключ
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupMapkit();
  final store = await PrefsStore.open();
  runApp(DriverApp(data: DataStore(store)));
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key, required this.data});
  final DataStore data;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TransportApp Водитель',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(AppColors.driver),
        home: DriverHome(data: data),
      );
}
