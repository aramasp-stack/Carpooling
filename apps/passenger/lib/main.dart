import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transport_server/transport_server.dart';
import 'package:transport_ui/transport_ui.dart';

import 'home.dart';
import 'login.dart';
import 'reminders.dart';
import 'repo.dart';

/// TransportApp — приложение пассажира. Данные — с сервера, вход по номеру телефона.
/// Сборка с картой: flutter run --dart-define-from-file=../../mapkit.json
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Экран не поворачивается: приложение всегда вертикальное.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await setupMapkit();
  await ServerApi.init();
  await TripReminders.init();
  runApp(const PassengerApp());
}

class PassengerApp extends StatelessWidget {
  const PassengerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TransportApp',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(AppColors.passenger),
        home: const AuthGate(),
      );
}

/// Без входа приложением пользоваться нельзя: сначала номер, код из SMS и имя.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

enum _Gate { checking, login, name, home }

class _AuthGateState extends State<AuthGate> {
  final api = ServerApi.instance;
  final repo = PassengerRepo();
  _Gate gate = _Gate.checking;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    repo.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (!api.signedIn) {
      setState(() => gate = _Gate.login);
      return;
    }
    try {
      final p = await api.myProfile();
      setState(() => gate = p == null ? _Gate.name : _Gate.home);
    } on ServerError {
      // Нет связи: войти можно и без проверки профиля — экран поиска покажет ошибку и кнопку «Повторить».
      setState(() => gate = _Gate.home);
    }
  }

  Future<void> _signOut() async {
    await repo.signOut();
    if (mounted) setState(() => gate = _Gate.login);
  }

  @override
  Widget build(BuildContext context) => switch (gate) {
        _Gate.checking => const Scaffold(body: Center(child: CircularProgressIndicator())),
        _Gate.login => LoginScreen(onSignedIn: () => setState(() => gate = _Gate.home)),
        _Gate.name => LoginScreen(askNameOnly: true, onSignedIn: () => setState(() => gate = _Gate.home)),
        _Gate.home => HomeScreen(repo: repo, onSignOut: _signOut),
      };
}
