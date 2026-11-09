import 'package:flutter/material.dart';
import 'package:transport_core/transport_core.dart';
import 'package:transport_ui/transport_ui.dart';

import 'home.dart';

/// TransportApp — приложение пассажира.
/// Запуск с картой: flutter run --dart-define=MAPKIT_API_KEY=ваш-ключ
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupMapkit();
  final store = await PrefsStore.open();
  runApp(PassengerApp(data: DataStore(store)));
}

class PassengerApp extends StatelessWidget {
  const PassengerApp({super.key, required this.data});
  final DataStore data;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TransportApp',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(AppColors.passenger),
        home: HomeScreen(data: data),
      );
}
