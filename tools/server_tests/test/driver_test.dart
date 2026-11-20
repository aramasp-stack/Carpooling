// Правила водителя (ТЗ, раздел 5): документы, карта для выплат, блокировка пассажиров,
// заявки на маршруты, оценка пассажиров.
import 'package:server_tests/harness.dart';
import 'package:server_tests/invariants.dart';
import 'package:test/test.dart';

void main() {
  late World w;
  late String route;

  setUpAll(() async {
    w = await World.create('tt_driver');
    route = await w.newRoute('D1');
  });

  tearDownAll(() => w.close());

  tearDown(() async {
    expect(await violations(w), isEmpty, reason: 'целостность после теста');
  });

  Future<DateTime> inMinutes(int m) async => (await w.now()).add(Duration(minutes: m));

  /// Водитель, который только подал анкету (без документов, карты и одобрения).
  Future<Actor> applicant(String name) async {
    final a = await w.newUser(name);
    await a.q("select apply_driver(@c, @k, @p, '{front,rl,rr}', @t)", {'c': 'Kia Rio', 'k': 'серая', 'p': '11 AA 111', 't': '0123'});
    return a;
  }

  group('документы и проверка', () {
    test('одобрить можно только анкету со всеми пятью документами', () async {
      final a = await applicant('Без документов');
      const review = 'select staff_review_driver(@d::uuid, true)';
      expect(await w.verifier.refusal(review, {'d': a.id}), 'DOCUMENTS_MISSING');
      await a.q("select driver_save_document('license', @p)", {'p': '${a.id}/license.jpg'});
      expect(await w.verifier.refusal(review, {'d': a.id}), 'DOCUMENTS_MISSING', reason: 'одного документа мало');
      await a.uploadDocuments();
      expect(await w.verifier.refusal(review, {'d': a.id}), isNull);
      expect(await w.scalar("select status::text from drivers where user_id = @d::uuid", {'d': a.id}), 'approved');
      // отклонить можно и без документов
      final b = await applicant('Отклоняемый');
      expect(await w.verifier.refusal("select staff_review_driver(@d::uuid, false, 'нет документов')", {'d': b.id}), isNull);
    });

    test('документ кладётся только в свою папку; после одобрения документы не меняются', () async {
      final a = await applicant('Аккуратный');
      const save = 'select driver_save_document(@k, @p)';
      expect(await a.refusal(save, {'k': 'passport', 'p': '${a.id}/x.jpg'}), 'BAD_DOCUMENT_KIND');
      final other = await w.newPassenger('Чужая папка');
      expect(await a.refusal(save, {'k': 'selfie', 'p': '${other.id}/selfie.jpg'}), 'BAD_DOCUMENT_PATH');
      expect(await a.refusal(save, {'k': 'selfie', 'p': '${a.id}/../${other.id}/s.jpg'}), 'BAD_DOCUMENT_PATH');
      expect(await a.refusal(save, {'k': 'selfie', 'p': null}), 'BAD_DOCUMENT_PATH');
      expect(await other.refusal(save, {'k': 'selfie', 'p': '${other.id}/s.jpg'}), 'NOT_A_DRIVER');
      await a.uploadDocuments();
      await w.verifier.q('select staff_review_driver(@d::uuid, true)', {'d': a.id});
      expect(await a.refusal(save, {'k': 'selfie', 'p': '${a.id}/new.jpg'}), 'DRIVER_ALREADY_APPROVED');
    });

    test('документы видят только сам водитель и проверяющий', () async {
      final a = await applicant('Скрытный');
      await a.uploadDocuments();
      final stranger = await w.newDriver('Посторонний водитель');
      Future<int> seen(Actor x) async =>
          await x.one('select count(*)::int from driver_documents where driver_id = @d::uuid', {'d': a.id}) as int;
      expect(await seen(a), 5);
      expect(await seen(w.verifier), 5);
      expect(await seen(stranger), 0);
      expect(await seen(w.support), 0);
      expect(await seen(w.finance), 0);
    });
  });

  group('карта для выплат', () {
    test('нужен свежий вход по SMS; первая карта действует сразу, новая — через сутки', () async {
      final a = await applicant('Новичок');
      const set = 'select driver_set_payout_card_sim(@n, @h)';
      a.smsAge = const Duration(minutes: 11);
      expect(await a.refusal(set, {'n': '4111111111111111', 'h': 'Novichok'}), 'REAUTH_REQUIRED');
      a.smsAge = const Duration(minutes: 2);
      expect(await a.refusal(set, {'n': '4111', 'h': 'Novichok'}), 'BAD_CARD_NUMBER');
      expect(await a.refusal(set, {'n': '4111111111111111', 'h': ' '}), 'BAD_HOLDER_NAME');
      final first = await a.one(set, {'n': '4111 1111 1111 1234', 'h': 'novichok'}) as String;
      final card = (await a.q('select last4, holder_name, active_from <= app_now() from payout_cards where id = @c::uuid', {'c': first})).first;
      expect(card.toList(), ['1234', 'NOVICHOK', true]);
      // новая карта: старая снята сразу, новая заработает через 24 часа
      final second = await a.one(set, {'n': '5555555555555678', 'h': 'Novichok'}) as String;
      expect(await w.scalar('select removed_at is not null from payout_cards where id = @c::uuid', {'c': first}), isTrue);
      expect(await w.scalar("select active_from - app_now() > interval '23 hours' from payout_cards where id = @c::uuid", {'c': second}), isTrue);
      expect(await w.scalar("select count(*)::int from payout_cards where driver_id = @d::uuid and removed_at is null", {'d': a.id}), 1);
      // метку банка приложение не видит
      expect(await a.refusal('select token from payout_cards'), '42501');
      // пассажир карту для выплат не привязывает
      final p = await w.newPassenger('Не водитель');
      expect(await p.refusal(set, {'n': '4111111111111111', 'h': 'X Y'}), 'NOT_A_DRIVER');
    });

    test('выплата только на действующую карту; после смены карты деньги ждут сутки', () async {
      final d = await w.newDriver('Выплатной');
      final p = await w.newPassenger('Платящий');
      final trip = await d.createTrip(route, await inMinutes(60));
      await p.book(trip, ['front']);
      await w.advance(const Duration(minutes: 60));
      await d.q('select driver_start_trip(@t::uuid)', {'t': trip});
      await d.q('select driver_finish_trip(@t::uuid)', {'t': trip});
      // водитель сменил карту прямо перед начислением
      final newCard = await d.setPayoutCard('5555555555550001');
      await w.advance(const Duration(hours: 24, minutes: 1));
      await w.finance.q('select accrue_due()');
      // новая карта вступает в силу почти в то же время: проверяем, что выплата ушла именно на неё и один раз
      await w.advance(const Duration(minutes: 1));
      await w.finance.q('select finance_create_payouts()');
      final paid = await w.scalar('select coalesce(sum(amount), 0)::int from payouts where driver_id = @d::uuid', {'d': d.id}) as int;
      expect(paid, MoneySplitLike.driverShare(600));
      expect(await w.scalar('select count(distinct card_id)::int from payouts where driver_id = @d::uuid', {'d': d.id}), 1);
      expect(await w.scalar('select card_id::text from payouts where driver_id = @d::uuid limit 1', {'d': d.id}), newCard);
    });

    test('без карты выплата не создаётся, начисленное ждёт', () async {
      final a = await applicant('Без карты');
      await a.uploadDocuments();
      await w.verifier.q('select staff_review_driver(@d::uuid, true)', {'d': a.id});
      final p = await w.newPassenger('Пассажир без карты у водителя');
      final trip = await a.createTrip(route, await inMinutes(60));
      await p.book(trip, ['front']);
      await w.advance(const Duration(minutes: 60));
      await a.q('select driver_start_trip(@t::uuid)', {'t': trip});
      await a.q('select driver_finish_trip(@t::uuid)', {'t': trip});
      await w.advance(const Duration(hours: 25));
      await w.finance.q('select accrue_due()');
      await w.finance.q('select finance_create_payouts()');
      expect(await w.scalar('select count(*)::int from payouts where driver_id = @d::uuid', {'d': a.id}), 0);
      final e = await a.one('select driver_earnings()') as Map;
      expect(e['to_pay'], MoneySplitLike.driverShare(600));
      // привязал карту — следующая выплата уходит
      await a.setPayoutCard();
      await w.finance.q('select finance_create_payouts()');
      expect(await w.scalar('select coalesce(sum(amount), 0)::int from payouts where driver_id = @d::uuid', {'d': a.id}),
          MoneySplitLike.driverShare(600));
    });
  });

  group('блокировка пассажиров', () {
    test('заблокированный не видит рейсов водителя и не может купить; о блокировке не узнаёт', () async {
      final d = await w.newDriver('Строгий');
      final other = await w.newDriver('Другой водитель');
      final rude = await w.newPassenger('Грубиян');
      final polite = await w.newPassenger('Вежливый');
      final past = await d.createTrip(route, await inMinutes(30));
      await rude.book(past, ['front']);
      final next = await d.createTrip(route, await inMinutes(300));
      final foreign = await other.createTrip(route, await inMinutes(300));

      // чужого человека заблокировать нельзя
      expect(await d.refusal('select driver_block_passenger(@p::uuid)', {'p': polite.id}), 'PASSENGER_NOT_FOUND');
      await d.q('select driver_block_passenger(@p::uuid)', {'p': rude.id});
      await d.q('select driver_block_passenger(@p::uuid)', {'p': rude.id}); // повтор ничего не ломает

      Future<int> sees(Actor a, String trip) async =>
          await a.one('select count(*)::int from trips where id = @t::uuid', {'t': trip}) as int;
      Future<int> seats(Actor a, String trip) async =>
          await a.one('select count(*)::int from trip_seats where trip_id = @t::uuid', {'t': trip}) as int;

      expect(await sees(rude, next), 0, reason: 'новый рейс водителя скрыт');
      expect(await seats(rude, next), 0, reason: 'и места этого рейса тоже');
      expect(await sees(rude, past), 1, reason: 'рейс, на который уже куплен билет, виден');
      expect(await sees(rude, foreign), 1, reason: 'рейсы других водителей видны');
      expect(await rude.one('select count(*)::int from driver_public where user_id = @d::uuid', {'d': d.id}), 0);
      expect(await sees(polite, next), 1);
      // покупка: тот же отказ, что и для несуществующего рейса
      try {
        await rude.book(next, ['front']);
        fail('заблокированный купил место');
      } on Refused catch (e) {
        expect(e.code, 'TRIP_NOT_FOUND');
      }
      // таблицу блокировок пассажир не видит
      expect(await rude.one('select count(*)::int from driver_blocks'), 0);
      // уже оплаченное место блокировка не отменила
      expect(await w.scalar("select count(*)::int from bookings where passenger_id = @p::uuid and status = 'paid'", {'p': rude.id}), 1);

      // список заблокированных и разблокировка
      final list = await d.q('select passenger_name from driver_blocked_passengers()');
      expect(list.map((r) => r.first).toList(), ['Грубиян']);
      await d.q('select driver_unblock_passenger(@p::uuid)', {'p': rude.id});
      expect(await sees(rude, next), 1);
      expect((await rude.book(next, ['rl']))['status'], 'paid');
    });
  });

  group('заявки на маршруты', () {
    test('водитель предлагает маршрут, модератор принимает или отклоняет с причиной', () async {
      final d = await applicant('Первопроходец');
      const req = 'select driver_request_route(@f, @t, @c)';
      expect(await d.refusal(req, {'f': ' ', 't': 'Опера', 'c': null}), 'BAD_ARGUMENT');
      final r1 = await d.one(req, {'f': 'Норк', 't': 'Опера', 'c': 'утром много людей'}) as String;
      final r2 = await d.one(req, {'f': 'Аван', 't': 'Ереван Молл', 'c': null}) as String;
      for (var i = 0; i < 3; i++) {
        await d.one(req, {'f': 'Место $i', 't': 'Центр', 'c': null});
      }
      expect(await d.refusal(req, {'f': 'Шестая', 't': 'Центр', 'c': null}), 'TOO_MANY_REQUESTS');

      const review = 'select staff_review_route_request(@r::uuid, @a::boolean, @why)';
      expect(await d.refusal(review, {'r': r1, 'a': 'true', 'why': null}), 'FORBIDDEN');
      expect(await w.moderator.refusal(review, {'r': r2, 'a': 'false', 'why': ' '}), 'REASON_REQUIRED');
      await w.moderator.q(review, {'r': r1, 'a': 'true', 'why': null});
      await w.moderator.q(review, {'r': r2, 'a': 'false', 'why': 'такой маршрут уже есть: M7'});
      expect(await w.moderator.refusal(review, {'r': r1, 'a': 'false', 'why': 'передумал'}), 'ALREADY_REVIEWED');

      final mine = await d.q('select status, reason from route_requests where id = @r::uuid', {'r': r2});
      expect(mine.first.toList(), ['rejected', 'такой маршрут уже есть: M7']);
      final other = await w.newDriver('Сосед');
      expect(await other.one('select count(*)::int from route_requests where driver_id = @d::uuid', {'d': d.id}), 0);
      // место освободилось — можно снова предлагать
      expect(await d.refusal(req, {'f': 'Шестая', 't': 'Центр', 'c': null}), isNull);
    });
  });

  group('оценка пассажиров', () {
    test('водитель оценивает пассажира один раз после рейса; пассажир видит только общий рейтинг', () async {
      final d = await w.newDriver('Оценщик');
      final p = await w.newPassenger('Оцениваемый');
      final trip = await d.createTrip(route, await inMinutes(60));
      final b = (await p.book(trip, ['front']))['booking_id'] as String;
      const rate = 'select driver_rate_passenger(@b::uuid, @s::int)';
      expect(await d.refusal(rate, {'b': b, 's': '4'}), 'TRIP_NOT_FINISHED');
      await w.advance(const Duration(minutes: 60));
      await d.q('select driver_start_trip(@t::uuid)', {'t': trip});
      await d.q('select driver_finish_trip(@t::uuid)', {'t': trip});
      expect(await d.refusal(rate, {'b': b, 's': '6'}), 'BAD_RATING');
      final stranger = await w.newDriver('Чужой оценщик');
      expect(await stranger.refusal(rate, {'b': b, 's': '1'}), 'BOOKING_NOT_FOUND');
      await d.q(rate, {'b': b, 's': '3'});
      expect(await d.refusal(rate, {'b': b, 's': '5'}), 'ALREADY_RATED');
      expect(await p.one('select passenger_rating::text from profiles where id = @p::uuid', {'p': p.id}), '3.0');
      expect(await p.refusal('select driver_rating from bookings'), '42501', reason: 'саму оценку пассажир не видит');
      // водитель видит рейтинг в списке пассажиров
      final row = (await d.q('select passenger_rating::text from trip_passengers(@t::uuid)', {'t': trip})).first;
      expect(row.first, '3.0');
    });
  });
}

/// Доля водителя с суммы по текущим настройкам (10 % и 4 %), с округлением в пользу водителя.
class MoneySplitLike {
  static int driverShare(int kept) => kept - (kept * 10) ~/ 100 - (kept * 4) ~/ 100;
}
