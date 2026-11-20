/// Отказы сервера понятными словами.
///
/// Серверная функция отказывает исключением с кодом ЗАГЛАВНЫМИ буквами (например SEAT_TAKEN).
/// Приложение показывает человеку не код, а объяснение и что делать дальше.
library;

import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Отказ или сбой, который можно показать человеку.
class ServerError implements Exception {
  ServerError(this.code, this.text);

  /// Код отказа сервера (SEAT_TAKEN …) или NETWORK / AUTH / UNKNOWN.
  final String code;

  /// Что сказать человеку.
  final String text;

  @override
  String toString() => text;
}

const _texts = <String, String>{
  'NOT_SIGNED_IN': 'Войдите по номеру телефона.',
  'NO_PROFILE': 'Укажите имя, чтобы продолжить.',
  'BLOCKED': 'Учётная запись заблокирована. Обратитесь в поддержку.',
  'BAD_NAME': 'Имя — от 1 до 60 символов.',
  'PHONE_TAKEN': 'Этот номер уже занят другой учётной записью.',
  'NO_PHONE': 'Не удалось определить номер телефона. Войдите заново.',
  'TRIP_NOT_FOUND': 'Рейс больше недоступен.',
  'TRIP_CLOSED': 'Продажа мест на этот рейс закрыта.',
  'OWN_TRIP': 'Нельзя купить место в собственном рейсе.',
  'SEAT_TAKEN': 'Это место только что купили. Выберите другое.',
  'BAD_SEATS': 'Выберите места ещё раз.',
  'CARD_NOT_FOUND': 'Карта не найдена. Выберите другую карту.',
  'CARD_DECLINED': 'Банк отказал в оплате. Попробуйте другую карту.',
  'BANK_UNAVAILABLE': 'Банк сейчас не отвечает. Попробуйте через минуту.',
  'BAD_CARD_NUMBER': 'Номер карты — 16 цифр.',
  'TOO_MANY_CARDS': 'Можно привязать не больше пяти карт.',
  'IDEM_KEY_REUSED': 'Выберите места ещё раз.',
  'BOOKING_NOT_FOUND': 'Бронь не найдена.',
  'NOT_CANCELLABLE': 'Эту бронь уже нельзя отменить.',
  'TRIP_ALREADY_STARTED': 'Рейс уже начался — отменить бронь нельзя.',
  'TRIP_NOT_FINISHED': 'Оценить водителя можно после поездки.',
  'ALREADY_RATED': 'Вы уже оценили эту поездку.',
  'BAD_RATING': 'Оценка — от 1 до 5 звёзд.',
};

/// Перевести любую ошибку обращения к серверу в [ServerError].
ServerError serverError(Object e) {
  if (e is ServerError) return e;
  if (e is PostgrestException) {
    final code = RegExp(r'^[A-Z][A-Z0-9_]+').stringMatch(e.message) ?? 'UNKNOWN';
    return ServerError(code, _texts[code] ?? 'Сервер не выполнил действие. Попробуйте ещё раз.');
  }
  if (e is AuthException) {
    final m = e.message.toLowerCase();
    if (m.contains('expired') || m.contains('invalid') || m.contains('token')) {
      return ServerError('AUTH', 'Код не подходит или устарел. Проверьте код или запросите новый.');
    }
    if (m.contains('rate') || m.contains('too many') || m.contains('seconds')) {
      return ServerError('AUTH', 'Слишком часто. Подождите минуту и запросите код снова.');
    }
    if (m.contains('phone') && (m.contains('disabled') || m.contains('provider') || m.contains('unsupported'))) {
      return ServerError('AUTH', 'Вход по телефону на сервере ещё не включён.');
    }
    return ServerError('AUTH', 'Не удалось войти: ${e.message}');
  }
  if (e is SocketException || e is TimeoutException || e is HttpException) {
    return ServerError('NETWORK', 'Нет связи с сервером. Проверьте интернет и попробуйте ещё раз.');
  }
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('Connection')) {
    return ServerError('NETWORK', 'Нет связи с сервером. Проверьте интернет и попробуйте ещё раз.');
  }
  return ServerError('UNKNOWN', 'Что-то пошло не так. Попробуйте ещё раз.');
}

/// Текст для кода отказа, который сервер вернул в ответе (а не исключением), например CARD_DECLINED.
String reasonText(String code) => _texts[code] ?? 'Сервер не выполнил действие.';
