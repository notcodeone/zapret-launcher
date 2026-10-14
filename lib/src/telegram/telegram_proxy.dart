import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'cloudflare.dart';
import 'proxy_server.dart';
import 'upstream.dart';

export 'proxy_server.dart' show TelegramProxyStats;

/// Порт прокси по умолчанию — как у tg-ws-proxy, чтобы инструкции совпадали.
const defaultTelegramProxyPort = 1443;

/// Новый секрет прокси: 16 случайных байт в hex.
String generateTelegramSecret() {
  final r = Random.secure();
  return [
    for (var i = 0; i < 16; i++)
      r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Секрет из настроек годится: 32 hex-символа.
bool isTelegramSecret(String? s) =>
    s != null && RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(s);

/// Ссылка, по которой Telegram Desktop сам добавит прокси. «dd» перед секретом —
/// режим со случайной длиной пакетов, как у tg-ws-proxy.
String telegramProxyLink({required int port, required String secret}) =>
    'tg://proxy?server=127.0.0.1&port=$port&secret=dd$secret';

class TelegramProxyException implements Exception {
  const TelegramProxyException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message: $detail';
}

/// Прокси в отдельном изоляте: работа с сетью и шифрование не тормозят окно,
/// а сбой в прокси не роняет лаунчер.
class TelegramProxy {
  TelegramProxy({
    this.onLog,
    this.onStats,
    this.onCrash,
    CloudflareSource? cloudflare,
  }) : cloudflare =
           cloudflare ?? CloudflareSource(cachePath: cloudflareCachePath());

  /// Откуда брать домены Cloudflare-прокси: скачиваются при каждом запуске.
  final CloudflareSource cloudflare;

  /// Строка для журнала из прокси.
  void Function(String line)? onLog;
  void Function(TelegramProxyStats stats)? onStats;

  /// Изолят прокси завершился сам — не по [stop].
  void Function()? onCrash;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _messages;
  ReceivePort? _exit;
  ReceivePort? _errors;
  Completer<void>? _stopped;
  bool _stopping = false;

  TelegramProxyStats _stats = const TelegramProxyStats();
  TelegramProxyStats get stats => _stats;

  bool get running => _commands != null;

  /// Запускает прокси и ждёт, пока он начнёт слушать порт.
  Future<void> start({required String secret, required int port}) async {
    if (_isolate != null) await stop();
    final messages = _messages = ReceivePort();
    final exit = _exit = ReceivePort();
    final errors = _errors = ReceivePort();
    final ready = Completer<void>();
    _stopping = false;
    _stats = const TelegramProxyStats();

    messages.listen((msg) {
      switch (msg) {
        case ['ready', final SendPort commands]:
          _commands = commands;
          if (!ready.isCompleted) ready.complete();
        case ['error', final String message, final String? detail]:
          if (!ready.isCompleted) {
            ready.completeError(
              TelegramProxyException(message, detail: detail),
            );
          }
        case ['log', final String line]:
          onLog?.call(line);
        case ['stats', final Map<Object?, Object?> m]:
          _stats = TelegramProxyStats.fromMap(m);
          onStats?.call(_stats);
      }
    });
    errors.listen((e) {
      if (e is List && e.isNotEmpty) onLog?.call('Сбой прокси: ${e.first}');
    });
    exit.listen((_) {
      // Упал уже работающий прокси; не запустившийся — это ошибка start().
      final crashed = !_stopping && _commands != null;
      _cleanup();
      if (!ready.isCompleted) {
        ready.completeError(
          const TelegramProxyException('Прокси для Telegram не запустился'),
        );
      } else if (crashed) {
        onCrash?.call();
      }
    });

    _isolate = await Isolate.spawn(
      _proxyMain,
      [
        messages.sendPort,
        secret,
        port,
        cloudflare.url ?? '',
        cloudflare.cachePath ?? '',
      ],
      onExit: exit.sendPort,
      onError: errors.sendPort,
      debugName: 'telegram-proxy',
    );
    try {
      await ready.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      await stop();
      throw const TelegramProxyException('Прокси для Telegram не запустился');
    }
  }

  /// Останавливает прокси; соединения Telegram рвутся.
  Future<void> stop() async {
    final isolate = _isolate;
    if (isolate == null) return;
    _stopping = true;
    final stopped = _stopped = Completer<void>();
    final commands = _commands;
    if (commands != null) {
      commands.send('stop');
      // Изолят закроет сокеты и выйдет сам; не дождались — убиваем.
      await stopped.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => isolate.kill(priority: Isolate.immediate),
      );
    } else {
      isolate.kill(priority: Isolate.immediate);
    }
    _cleanup();
  }

  void _cleanup() {
    _messages?.close();
    _exit?.close();
    _errors?.close();
    _messages = _exit = _errors = null;
    _commands = null;
    _isolate = null;
    _stats = const TelegramProxyStats();
    final stopped = _stopped;
    _stopped = null;
    if (stopped != null && !stopped.isCompleted) stopped.complete();
  }
}

/// Точка входа изолята: [SendPort, секрет hex, порт, адрес списка Cloudflare,
/// файл кэша] — пустые строки, если без них. Непойманная ошибка в одной сессии
/// не должна ронять весь прокси — пишем её в журнал и работаем дальше.
Future<void> _proxyMain(List<Object> args) async {
  final out = args[0] as SendPort;
  String? orNull(Object s) => s == '' ? null : s as String;
  await runZonedGuarded(
    () => _runProxy(
      out,
      args[1] as String,
      args[2] as int,
      CloudflareSource(url: orNull(args[3]), cachePath: orNull(args[4])),
    ),
    (e, _) => out.send(['log', 'Ошибка прокси: $e']),
  );
}

Future<void> _runProxy(
  SendPort out,
  String secret,
  int port,
  CloudflareSource cloudflare,
) async {
  void log(String line) => out.send(['log', line]);
  final domains = CloudflareDomains();
  final refresher = CloudflareRefresher(domains, cloudflare, onLog: log);
  final server = TelegramProxyServer(
    secret: _hex(secret),
    port: port,
    connector: DirectTelegramConnector(cloudflare: domains),
    onLog: log,
  );
  try {
    await server.start();
  } on SocketException catch (e) {
    out.send([
      'error',
      _inUse(e)
          ? 'Порт $port занят другой программой'
          : 'Не удалось открыть порт $port',
      e.osError?.message ?? e.message,
    ]);
    Isolate.exit();
  }

  // Порт открыт — теперь домены: из кэша сразу, свежие — в фоне.
  refresher.start();
  final commands = ReceivePort();
  out.send(['ready', commands.sendPort]);
  var last = '';
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    final m = server.stats.toMap();
    final key = m.values.join(',');
    if (key == last) return;
    last = key;
    out.send(['stats', m]);
  });
  await for (final cmd in commands) {
    if (cmd == 'stop') break;
  }
  timer.cancel();
  refresher.stop();
  await server.stop();
  Isolate.exit();
}

/// Порт занят: WSAEADDRINUSE в Windows, EADDRINUSE в Linux и macOS. Если порт
/// занят в этом же процессе, Dart отказывает сам, без кода ошибки системы.
bool _inUse(SocketException e) =>
    const {10048, 98, 48}.contains(e.osError?.errorCode) ||
    '${e.message} ${e.osError?.message}'.contains('binding multiple times');

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
