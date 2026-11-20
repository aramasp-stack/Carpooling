import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transport_server/transport_server.dart';
import 'package:transport_ui/transport_ui.dart';

/// Вход пассажира: номер телефона → код из SMS → имя (только в первый раз).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSignedIn, this.askNameOnly = false});

  /// Вход выполнен и имя указано.
  final VoidCallback onSignedIn;

  /// Номер уже подтверждён, осталось указать имя.
  final bool askNameOnly;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Step { phone, code, name }

class _LoginScreenState extends State<LoginScreen> {
  final api = ServerApi.instance;
  final phoneCtl = TextEditingController();
  final codeCtl = TextEditingController();
  final nameCtl = TextEditingController();
  late _Step step = widget.askNameOnly ? _Step.name : _Step.phone;
  bool busy = false;
  String? error;

  /// Номер в международном виде: +374 и 8 цифр.
  String get phone => '+374${phoneCtl.text.replaceAll(RegExp(r'[^0-9]'), '')}';
  bool get phoneOk => RegExp(r'^\+374[0-9]{8}$').hasMatch(phone);

  @override
  void dispose() {
    phoneCtl.dispose();
    codeCtl.dispose();
    nameCtl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await f();
    } on ServerError catch (e) {
      if (mounted) setState(() => error = e.text);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _sendCode() => _run(() async {
        if (!phoneOk) throw ServerError('BAD_PHONE', 'Введите 8 цифр номера после +374.');
        await api.sendCode(phone);
        codeCtl.clear();
        setState(() => step = _Step.code);
      });

  Future<void> _verify() => _run(() async {
        final code = codeCtl.text.trim();
        if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) throw ServerError('BAD_CODE', 'Код из SMS — 6 цифр.');
        await api.verifyCode(phone, code);
        final p = await api.myProfile();
        if (p == null) {
          setState(() => step = _Step.name);
        } else {
          widget.onSignedIn();
        }
      });

  Future<void> _saveName() => _run(() async {
        final name = nameCtl.text.trim();
        if (name.isEmpty) throw ServerError('BAD_NAME', 'Напишите, как к вам обращаться.');
        await api.register(name);
        widget.onSignedIn();
      });

  @override
  Widget build(BuildContext context) {
    const accent = AppColors.passenger;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            const Icon(Icons.directions_car_filled_rounded, size: 56, color: accent),
            const SizedBox(height: 14),
            const Text('TransportApp', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text('Места в машинах по маршрутам Еревана',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: AppColors.muted)),
            const SizedBox(height: 36),
            ...switch (step) {
              _Step.phone => _phoneStep(),
              _Step.code => _codeStep(),
              _Step.name => _nameStep(),
            },
            if (error != null) ...[
              const SizedBox(height: 14),
              Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(String text, VoidCallback onPressed) => FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : Text(text, style: const TextStyle(fontSize: 16)),
      );

  List<Widget> _phoneStep() => [
        const Text('Вход по номеру телефона', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        TextField(
          // Своё поле на каждом шаге: иначе остаётся клавиатура прошлого шага (цифры вместо букв).
          key: const ValueKey('phone'),
          controller: phoneCtl,
          autofocus: true,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')), LengthLimitingTextInputFormatter(11)],
          decoration: const InputDecoration(labelText: 'Номер телефона', prefixText: '+374 ', hintText: '77 123456'),
          onSubmitted: (_) => _sendCode(),
        ),
        const SizedBox(height: 16),
        _button('Получить код', _sendCode),
        const SizedBox(height: 12),
        const Text('Пришлём код по SMS. Номер не показывается водителям.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.muted)),
      ];

  List<Widget> _codeStep() => [
        Text('Код отправлен на ${phone.substring(0, 4)} ${phone.substring(4)}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        TextField(
          // Своё поле на каждом шаге: иначе остаётся клавиатура прошлого шага (цифры вместо букв).
          key: const ValueKey('code'),
          controller: codeCtl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          decoration: const InputDecoration(labelText: 'Код из SMS', counterText: ''),
          onSubmitted: (_) => _verify(),
        ),
        const SizedBox(height: 16),
        _button('Войти', _verify),
        TextButton(
          onPressed: busy ? null : () => setState(() => step = _Step.phone),
          child: const Text('Другой номер'),
        ),
      ];

  List<Widget> _nameStep() => [
        const Text('Как к вам обращаться?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        TextField(
          // Своё поле на каждом шаге: иначе остаётся клавиатура прошлого шага (цифры вместо букв).
          key: const ValueKey('name'),
          controller: nameCtl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          inputFormatters: [LengthLimitingTextInputFormatter(60)],
          decoration: const InputDecoration(labelText: 'Имя'),
          onSubmitted: (_) => _saveName(),
        ),
        const SizedBox(height: 8),
        const Text('Имя увидит водитель вашего рейса.', style: TextStyle(fontSize: 13, color: AppColors.muted)),
        const SizedBox(height: 16),
        _button('Продолжить', _saveName),
      ];
}
