import 'package:test/test.dart';
import 'package:transport_core/transport_core.dart';

/// Правила водителя в приложении — те же, что на сервере.
void main() {
  late DateTime clock;
  late DriverStore s;

  setUp(() {
    clock = DateTime(2026, 11, 21, 9);
    s = DriverStore(MemoryStore(), clock: () => clock);
  });

  Future<String?> code(Future<Object?> Function() f) async {
    try {
      await f();
      return null;
    } on DriverError catch (e) {
      return e.code;
    }
  }

  test('вход: номер и код из 4 цифр', () async {
    expect(await code(() => s.signIn('12', '1234')), 'BAD_PHONE');
    expect(await code(() => s.signIn('+374 91 123456', '12')), 'BAD_CODE');
    await s.signIn('+374 91 123456', '0000');
    expect(s.phone, '+37491123456');
  });

  test('анкета: без машины и всех документов не отправить; одобрить можно только отправленную', () async {
    expect(await code(s.submit), 'BAD_ARGUMENT');
    await s.saveApplication(DriverApplication(car: 'Kia Rio', carColor: 'серая', plate: '11 AA 111', taxId: '0123', seats: 4));
    expect(await code(s.submit), 'DOCUMENTS_MISSING');
    for (final k in driverDocuments.keys.take(4)) {
      await s.setDocument(k);
    }
    expect(await code(s.submit), 'DOCUMENTS_MISSING');
    expect(await code(() => s.setDocument('passport')), 'BAD_DOCUMENT_KIND');
    expect(await code(() => s.review(approve: true)), 'NOT_PENDING');
    await s.setDocument('selfie');
    await s.submit();
    expect(s.application.status, ApplicationStatus.pending);
    expect(await code(() => s.review(approve: false, reason: ' ')), 'REASON_REQUIRED');
    await s.review(approve: false, reason: 'фото прав нечитаемо');
    expect(s.application.rejectReason, 'фото прав нечитаемо');
    await s.submit();
    await s.review(approve: true);
    expect(s.approved, isTrue);
    expect(await code(() => s.setDocument('selfie')), 'DRIVER_ALREADY_APPROVED');
  });

  test('карта для выплат: первая сразу, новая через сутки; нужен код из SMS', () async {
    expect(await code(() => s.setPayoutCard(number: '4111', holder: 'Aram', smsCode: '1234')), 'BAD_CARD_NUMBER');
    expect(await code(() => s.setPayoutCard(number: '4111111111111111', holder: ' ', smsCode: '1234')), 'BAD_HOLDER_NAME');
    expect(await code(() => s.setPayoutCard(number: '4111111111111111', holder: 'Aram', smsCode: '')), 'REAUTH_REQUIRED');
    final first = await s.setPayoutCard(number: '4111 1111 1111 4821', holder: 'aram', smsCode: '1234');
    expect([first.brand, first.last4, first.holder, first.activeFrom], ['Visa', '4821', 'ARAM', clock]);
    final second = await s.setPayoutCard(number: '5555555555550001', holder: 'Aram', smsCode: '1234');
    expect(second.activeFrom, clock.add(const Duration(hours: 24)));
    expect(s.payoutCard!.last4, '0001');
  });

  test('блокировка, оценки и заявки на маршруты', () async {
    await s.block('Сурен');
    await s.block('Сурен');
    expect(s.blocked.keys, ['Сурен']);
    expect(s.isBlocked('Сурен'), isTrue);
    await s.unblock('Сурен');
    expect(s.isBlocked('Сурен'), isFalse);

    expect(await code(() => s.rate('t1', 'front', 6)), 'BAD_RATING');
    await s.rate('t1', 'front', 4);
    expect(await code(() => s.rate('t1', 'front', 5)), 'ALREADY_RATED');
    expect(s.ratingOf('t1', 'front'), 4);

    expect(await code(() => s.requestRoute(from: 'Н', to: 'Опера')), 'BAD_ARGUMENT');
    for (var i = 0; i < DriverStore.maxOpenRequests; i++) {
      await s.requestRoute(from: 'Место $i', to: 'Центр');
    }
    expect(await code(() => s.requestRoute(from: 'Шестое', to: 'Центр')), 'TOO_MANY_REQUESTS');
    expect(s.routeRequests.first.from, 'Место 4', reason: 'новые сверху');

    await s.cancelTrip('t9');
    expect(s.cancelledTrips, {'t9'});
    await s.reset();
    expect(s.blocked, isEmpty);
    expect(s.application.status, ApplicationStatus.none);
  });

  test('минимальная цена маршрута: задана в демо-маршрутах, без неё равна базовой', () {
    final m1 = Demo.routeById('M1')!;
    expect([m1.price, m1.minPrice, m1.maxPrice], [500, 400, 1500]);
    const r = RouteDef(id: 'X', color: 0, price: 700, minutes: 10, from: Demo.republicSquare, to: Demo.republicSquare);
    expect(r.minPrice, 700);
  });
}
