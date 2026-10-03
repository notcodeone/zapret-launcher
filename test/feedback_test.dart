import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/app.dart';
import 'package:zapret_launcher/src/controller.dart';
import 'package:zapret_launcher/src/feedback/feedback.dart';
import 'package:zapret_launcher/src/location/profiles.dart';
import 'package:zapret_launcher/src/settings.dart';
import 'package:zapret_launcher/src/ui/ui.dart';
import 'package:zapret_launcher/src/zapret/bundle.dart';
import 'package:zapret_launcher/src/zapret/runner.dart';

import 'helpers.dart';

/// Ничего не запущено — систему тесты не трогают.
class _IdleRunner extends ZapretRunner {
  @override
  RuntimeStatus status() =>
      const RuntimeStatus(processes: [], service: null, serviceStrategy: null);
  @override
  Future<void> stopAll() async {}
  @override
  Future<void> killProcesses() async {}
}

/// Сервер поддержки понарошку: выдаёт задачи, проверяет решение, запоминает обращения.
class _FakeServer {
  /// Сложность задачи: невысокая — тесты не ждут.
  final int difficulty = 8;
  final posts = <Map<String, dynamic>>[];
  int challenges = 0;

  /// Ответ на следующее обращение вместо 201 — например, устаревшая задача.
  http.Response? Function(int attempt)? reply;

  late final client = MockClient((req) async {
    if (req.method == 'GET' && req.url.path == '/v1/challenge') {
      challenges++;
      return http.Response(
        jsonEncode({
          'challenge': 'test.$challenges',
          'difficulty': difficulty,
          'expiresIn': 300,
        }),
        200,
      );
    }
    if (req.method == 'POST' && req.url.path == '/v1/feedback') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      posts.add(body);
      final pow = body['pow'] as Map<String, dynamic>;
      final hash = sha256
          .convert(utf8.encode('${pow['challenge']}:${pow['nonce']}'))
          .bytes;
      expect(_zeroBits(hash), greaterThanOrEqualTo(difficulty));
      final custom = reply?.call(posts.length);
      if (custom != null) return custom;
      return http.Response(jsonEncode({'id': 41 + posts.length}), 201);
    }
    return http.Response('', 404);
  });
}

int _zeroBits(List<int> bytes) {
  var n = 0;
  for (final b in bytes) {
    if (b == 0) {
      n += 8;
      continue;
    }
    var x = b;
    while (x & 0x80 == 0) {
      n++;
      x <<= 1;
    }
    break;
  }
  return n;
}

http.Response _json(int status, Map<String, Object> body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('proof-of-work: эталонные векторы сервера', () {
    expect(solvePow('1.1700000300.8.AAAAAAAAAAAAAAAA.test', 8), '123');
    expect(solvePow('1.1700000300.16.AAAAAAAAAAAAAAAA.test', 16), '61144');
  });

  test('журнал обезличивается: пользователь, компьютер, профиль, IPv4', () {
    final env = {
      'USERPROFILE': r'C:\Users\Ivan',
      'APPDATA': r'C:\Users\Ivan\AppData\Roaming',
      'USERNAME': 'Ivan',
      'COMPUTERNAME': 'DESKTOP-ABC123',
    };
    final out = anonymizeLocal(
      r'C:\Users\Ivan\AppData\Roaming\ZapretLauncher на DESKTOP-ABC123, '
      r'D:\Users\Petr\x, адрес 192.168.1.5',
      environment: env,
    );
    expect(out, contains(r'%APPDATA%\ZapretLauncher'));
    expect(out, contains('<host>'));
    expect(out, contains('%USERPROFILE%'));
    expect(out, contains('<ip>'));
    expect(out, isNot(contains('Ivan')));
    expect(out, isNot(contains('Petr')));
  });

  group('FeedbackClient', () {
    test('отправляет обращение и возвращает номер', () async {
      final server = _FakeServer();
      final client = FeedbackClient(server: 'https://s', client: server.client);
      final id = await client.send(
        kind: FeedbackKind.idea,
        text: 'Покажите стратегию в трее',
      );
      expect(id, 42);
      final body = server.posts.single;
      expect(body['kind'], 'idea');
      expect(body['text'], 'Покажите стратегию в трее');
      // Без согласия — ни сведений, ни журнала.
      expect(body.containsKey('details'), isFalse);
      expect(body.containsKey('log'), isFalse);
    });

    test(
      'устаревшая задача — один повтор сразу, второй раз — ошибка',
      () async {
        final server = _FakeServer()
          ..reply = (n) => n == 1
              ? _json(400, {
                  'error': 'pow_expired',
                  'message': 'Задача устарела',
                })
              : null;
        final client = FeedbackClient(
          server: 'https://s',
          client: server.client,
        );
        expect(
          await client.send(kind: FeedbackKind.bug, text: 'Не работает'),
          43,
        );
        expect(server.challenges, 2);

        final always = _FakeServer()
          ..reply = (_) => _json(400, {
            'error': 'pow_used',
            'message': 'Задача уже использована',
          });
        final again = FeedbackClient(
          server: 'https://s',
          client: always.client,
        );
        await expectLater(
          again.send(kind: FeedbackKind.bug, text: 'Не работает'),
          throwsA(
            isA<FeedbackException>().having(
              (e) => e.message,
              'message',
              'Задача уже использована',
            ),
          ),
        );
        expect(always.challenges, 2);
      },
    );

    test('слишком часто — сообщение сервера и время ожидания', () async {
      final server = _FakeServer()
        ..reply = (_) => _json(429, {
          'error': 'rate_limited',
          'retryAfter': 1800,
          'message': 'Слишком много обращений, попробуйте через 30 минут',
        });
      final client = FeedbackClient(server: 'https://s', client: server.client);
      await expectLater(
        client.send(kind: FeedbackKind.bug, text: 'Текст'),
        throwsA(
          isA<FeedbackException>()
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(minutes: 30),
              )
              .having((e) => e.message, 'message', contains('30 минут')),
        ),
      );
    });

    test(
      'сбой сервера или сети — понятное сообщение, без подробностей',
      () async {
        final down = FeedbackClient(
          server: 'https://s',
          client: MockClient((_) async => http.Response('oops', 502)),
        );
        await expectLater(
          down.send(kind: FeedbackKind.bug, text: 'Текст'),
          throwsA(
            isA<FeedbackException>().having(
              (e) => e.message,
              'message',
              'Не удалось отправить обращение, попробуйте позже.',
            ),
          ),
        );
        final offline = FeedbackClient(
          server: 'https://s',
          client: MockClient((_) => throw const SocketException('нет сети')),
        );
        await expectLater(
          offline.send(kind: FeedbackKind.bug, text: 'Текст'),
          throwsA(isA<FeedbackException>()),
        );
      },
    );

    test('сервер не задан — отправки нет', () async {
      final client = FeedbackClient(server: '');
      expect(client.configured, isFalse);
      await expectLater(
        client.send(kind: FeedbackKind.bug, text: 'Текст'),
        throwsA(isA<FeedbackException>()),
      );
    });
  });

  group('Обратная связь в лаунчере', () {
    late Directory tmp;
    late String root;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('zl-fb-');
      root = p.join(tmp.path, 'zapret');
      File(p.join(root, 'bin', 'winws.exe')).createSync(recursive: true);
      File(p.join(root, 'general (ALT2).bat'))
          .writeAsStringSync('"%BIN%winws.exe" --wf-tcp=80');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    AppController make(_FakeServer server) {
      final store = SettingsStore(path: p.join(tmp.path, 's.json'))
        ..save(
          AppSettings(
            zapretDir: root,
            autoCheckUpdates: false,
            profiles: [
              NetworkProfile(
                asn: 'AS1',
                name: 'Дача Ивановых',
                lastSeen: DateTime(2026),
              ),
            ],
          ),
        );
      return AppController(
        toasts: ToastController(),
        store: store,
        runner: _IdleRunner(),
        isElevated: () => true,
        guardFactory: quietGuard,
        watchNetworkEvents: false,
        launcherAutostart: FakeAutostart(),
        bundle: ZapretBundle(Directory(p.join(tmp.path, 'no-bundle'))),
        builtinZapretDir: p.join(tmp.path, 'builtin'),
        feedback: FeedbackClient(server: 'https://s', client: server.client),
      );
    }

    testWidgets(
      'сведения — только разрешённые поля, журнал без названий сетей',
      (tester) async {
        final server = _FakeServer();
        final c = make(server);
        await tester.runAsync(() async {
          c.init();
          await c.prepared;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        const allowed = {
          'launcher',
          'zapret',
          'zapretSource',
          'running',
          'mode',
          'strategy',
          'gameFilter',
          'ipset',
          'windows',
          'provider',
          'networkGuard',
          'profilesEnabled',
          'watchdog',
          'autoUpdateZapret',
        };
        final details = c.feedbackDetails();
        expect(allowed.containsAll(details.keys), isTrue);
        expect(details['strategy'], 'general (ALT2)');
        expect(details['mode'], 'process');
        expect(details['zapretSource'], 'custom');

        // Ошибка с путём профиля и названием своей сети попадает в журнал обезличенной.
        final home = Platform.environment['USERPROFILE'];
        await tester.runAsync(
          () => c.sendFeedback(
            kind: FeedbackKind.bug,
            text: '  Не запускается  ',
            attach: true,
          ),
        );
        final body = server.posts.single;
        expect(body['text'], 'Не запускается');
        expect((body['details'] as Map).keys.toSet(), details.keys.toSet());
        final log = c.feedbackLog();
        expect(log, isNot(contains('Дача Ивановых')));
        if (home != null) expect(log, isNot(contains(home)));
        expect(log, contains('Отправлено обращение №42'));
        c.dispose();
        c.toasts.dispose();
      },
    );

    testWidgets('форма: текст → «Отправить» → номер обращения', (tester) async {
      final server = _FakeServer();
      final c = make(server)..init();
      tester.view.physicalSize = const Size(560, 640);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        ZapretLauncherApp(controller: c, initialRoute: '/settings/feedback'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Обратная связь'), findsWidgets);

      // Пока текста нет — отправлять нечего.
      final fab = find.widgetWithText(NcFab, 'Отправить');
      expect(tester.widget<NcFab>(fab).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'Discord не открывается');
      await tester.pump();
      expect(tester.widget<NcFab>(fab).onPressed, isNotNull);
      await tester.runAsync(() async {
        tester.widget<NcFab>(fab).onPressed!();
        while (c.sendingFeedback || server.posts.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      expect(find.text('Обращение №42 отправлено'), findsOneWidget);
      expect(server.posts.single['kind'], 'bug');
      expect(server.posts.single.containsKey('details'), isFalse);

      await tester.pumpWidget(const SizedBox());
      c.dispose();
      c.toasts.dispose();
      tester.view.reset();
    });
  });
}
