import 'dart:async';
import 'dart:io';

import 'strategy.dart';

/// Сайт для проверки — строка из utils/targets.txt.
class ProbeTarget {
  const ProbeTarget(this.name, this.url);

  /// Ключ из targets.txt, например «DiscordGateway».
  final String name;
  final Uri url;

  /// Сервис, к которому относится сайт: Discord, YouTube, Google, Cloudflare…
  String get group {
    final m = RegExp(r'^(Discord|YouTube|Google|Cloudflare|Telegram)', caseSensitive: false)
        .firstMatch(name);
    if (m == null) return 'Другие';
    final g = m[1]!.toLowerCase();
    return const {
      'discord': 'Discord',
      'youtube': 'YouTube',
      'google': 'Google',
      'cloudflare': 'Cloudflare',
      'telegram': 'Telegram',
    }[g]!;
  }

  @override
  String toString() => '$name ($url)';
}

/// Сайты по умолчанию — те же, что в targets.txt репозитория.
final defaultProbeTargets = [
  ProbeTarget('DiscordMain', Uri.parse('https://discord.com')),
  ProbeTarget('DiscordGateway', Uri.parse('https://gateway.discord.gg')),
  ProbeTarget('DiscordCDN', Uri.parse('https://cdn.discordapp.com')),
  ProbeTarget('DiscordUpdates', Uri.parse('https://updates.discord.com')),
  ProbeTarget('YouTubeWeb', Uri.parse('https://www.youtube.com')),
  ProbeTarget('YouTubeShort', Uri.parse('https://youtu.be')),
  ProbeTarget('YouTubeImage', Uri.parse('https://i.ytimg.com')),
  ProbeTarget('YouTubeVideoRedirect', Uri.parse('https://redirector.googlevideo.com')),
  ProbeTarget('GoogleMain', Uri.parse('https://www.google.com')),
  ProbeTarget('GoogleGstatic', Uri.parse('https://www.gstatic.com')),
  ProbeTarget('CloudflareWeb', Uri.parse('https://www.cloudflare.com')),
  ProbeTarget('CloudflareCDN', Uri.parse('https://cdnjs.cloudflare.com')),
];

/// Разбор targets.txt: `Ключ = "https://…"`. Строки `PING:` пропускаем —
/// пинг не показывает, работает ли обход.
List<ProbeTarget> parseTargets(String text) {
  final re = RegExp(r'^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]+)"');
  final out = <ProbeTarget>[];
  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line.trimLeft().startsWith('#')) continue;
    final m = re.firstMatch(line);
    if (m == null) continue;
    final value = m[2]!.trim();
    if (!value.startsWith('http://') && !value.startsWith('https://')) continue;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) continue;
    out.add(ProbeTarget(m[1]!, uri));
  }
  return out;
}

enum ProbeOutcome {
  /// Ответ получен.
  ok,

  /// Соединение не устанавливается или сбрасывается — похоже на блокировку.
  blocked,

  /// Данные пошли и встали — «заморозка» после 16–20 КБ.
  stalled,

  /// Чужой сертификат — провайдер подменяет DNS или ответ.
  spoofed,

  /// Адрес сайта не находится.
  noHost,
}

class TargetResult {
  const TargetResult(this.target, this.outcome, {this.latency, this.bytes = 0, this.detail});

  final ProbeTarget target;
  final ProbeOutcome outcome;

  /// Время до первого байта ответа.
  final Duration? latency;
  final int bytes;
  final String? detail;

  bool get ok => outcome == ProbeOutcome.ok;
}

/// Проверка одного сайта: TLS, ответ и до 64 КБ данных.
///
/// HEAD-запроса мало: часть блокировок пропускает рукопожатие и первые
/// 16–20 КБ, а потом соединение замирает. Поэтому читаем тело ответа.
class HttpProber {
  HttpProber({
    this.timeout = const Duration(seconds: 6),
    this.connectTimeout = const Duration(seconds: 3),
    this.readLimit = 64 * 1024,
  });

  final Duration timeout;
  final Duration connectTimeout;
  final int readLimit;

  final _clients = <HttpClient>{};

  /// Обрывает все текущие проверки (при отмене подбора).
  void abortAll() {
    for (final c in _clients.toList()) {
      c.close(force: true);
    }
    _clients.clear();
  }

  Future<TargetResult> check(ProbeTarget target) async {
    // Новый клиент на каждую проверку: соединение не переживает смену стратегии.
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 1)
      ..autoUncompress = false
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/140.0 Safari/537.36';
    _clients.add(client);
    final sw = Stopwatch()..start();
    var bytes = 0;
    Duration? firstByte;
    final deadline = Timer(timeout, () => client.close(force: true));
    try {
      final req = await client.getUrl(target.url);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final resp = await req.close();
      firstByte = sw.elapsed;
      await for (final chunk in resp) {
        bytes += chunk.length;
        if (bytes >= readLimit) break;
      }
      return TargetResult(target, ProbeOutcome.ok, latency: firstByte, bytes: bytes);
    } on HandshakeException catch (e) {
      final msg = e.toString();
      if (msg.contains('CERTIFICATE')) {
        return TargetResult(target, ProbeOutcome.spoofed, detail: 'Чужой сертификат');
      }
      return TargetResult(target, ProbeOutcome.blocked, detail: 'TLS не установился');
    } on SocketException catch (e) {
      final lookup = e.message.contains('lookup') || (e.osError?.errorCode == 11001);
      if (lookup) return TargetResult(target, ProbeOutcome.noHost, detail: 'Адрес не найден');
      return _interrupted(target, firstByte, bytes, sw, e.osError?.message ?? e.message);
    } on HttpException catch (e) {
      return _interrupted(target, firstByte, bytes, sw, e.message);
    } on Object catch (e) {
      return _interrupted(target, firstByte, bytes, sw, e.toString());
    } finally {
      deadline.cancel();
      _clients.remove(client);
      client.close(force: true);
    }
  }

  TargetResult _interrupted(
      ProbeTarget target, Duration? firstByte, int bytes, Stopwatch sw, String detail) {
    if (firstByte != null && bytes > 0) {
      return TargetResult(target, ProbeOutcome.stalled,
          latency: firstByte, bytes: bytes, detail: 'Обрывается после ${bytes ~/ 1024} КБ');
    }
    final timedOut = sw.elapsed >= timeout - const Duration(milliseconds: 100);
    return TargetResult(target, ProbeOutcome.blocked,
        detail: timedOut ? 'Нет ответа за ${timeout.inSeconds} с' : detail);
  }
}

/// Результат одной стратегии (или проверки без обхода, если [strategy] == null).
class StrategyResult {
  const StrategyResult({required this.strategy, required this.targets, this.failedToStart = false});

  final Strategy? strategy;
  final List<TargetResult> targets;

  /// winws.exe с этой стратегией не запустился.
  final bool failedToStart;

  int get okCount => targets.where((t) => t.ok).length;
  int get total => targets.length;

  /// Средняя задержка по открывшимся сайтам — для выбора среди равных.
  Duration get averageLatency {
    final l = [for (final t in targets) if (t.ok && t.latency != null) t.latency!];
    if (l.isEmpty) return const Duration(days: 1);
    return Duration(microseconds: l.fold<int>(0, (s, d) => s + d.inMicroseconds) ~/ l.length);
  }

  /// Сколько сайтов сервиса открылось и сколько всего.
  Map<String, (int ok, int total)> get byGroup {
    final map = <String, (int, int)>{};
    for (final t in targets) {
      final (ok, total) = map[t.target.group] ?? (0, 0);
      map[t.target.group] = (ok + (t.ok ? 1 : 0), total + 1);
    }
    return map;
  }

  /// Лучше ли эта стратегия, чем [other]: больше открытых сайтов, затем быстрее.
  bool betterThan(StrategyResult other) {
    if (okCount != other.okCount) return okCount > other.okCount;
    return averageLatency < other.averageLatency;
  }
}

/// Что умеет окружение подбора. В приложении — winws.exe и настоящие запросы,
/// в тестах — подделка.
abstract interface class ProbeEnvironment {
  /// Запускает winws.exe со стратегией. false — не запустился.
  Future<bool> start(Strategy strategy);

  /// Останавливает winws.exe.
  Future<void> stop();

  Future<TargetResult> check(ProbeTarget target);

  /// Прервать идущие проверки.
  void abort();
}

class AutoPickProgress {
  const AutoPickProgress({required this.index, required this.total, this.current, this.baseline, required this.results});

  /// Сколько стратегий уже проверено.
  final int index;
  final int total;

  /// Стратегия, которая проверяется сейчас; null — проверка без обхода.
  final Strategy? current;
  final StrategyResult? baseline;
  final List<StrategyResult> results;
}

class AutoPickReport {
  const AutoPickReport({required this.baseline, required this.results, required this.cancelled});

  final StrategyResult baseline;

  /// В порядке проверки.
  final List<StrategyResult> results;
  final bool cancelled;

  /// Лучшая стратегия — если она открывает больше, чем без обхода.
  StrategyResult? get best {
    StrategyResult? best;
    for (final r in results) {
      if (r.failedToStart) continue;
      if (best == null || r.betterThan(best)) best = r;
    }
    if (best == null || best.okCount <= baseline.okCount) return null;
    return best;
  }

  /// От лучшей к худшей.
  List<StrategyResult> get ranked {
    final list = [...results];
    list.sort((a, b) {
      if (a.failedToStart != b.failedToStart) return a.failedToStart ? 1 : -1;
      if (a.betterThan(b)) return -1;
      if (b.betterThan(a)) return 1;
      return 0;
    });
    return list;
  }
}

class NoInternetException implements Exception {
  const NoInternetException();
}

/// Перебор стратегий: сначала проверка без обхода, затем каждая стратегия по очереди.
class AutoPick {
  AutoPick({required this.env, required this.strategies, required this.targets});

  final ProbeEnvironment env;
  final List<Strategy> strategies;
  final List<ProbeTarget> targets;

  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    env.abort();
  }

  Future<List<TargetResult>> _checkAll() => Future.wait([for (final t in targets) env.check(t)]);

  Future<AutoPickReport> run({void Function(AutoPickProgress progress)? onProgress}) async {
    final results = <StrategyResult>[];
    onProgress?.call(AutoPickProgress(index: 0, total: strategies.length, results: results));

    await env.stop();
    final baseline = StrategyResult(strategy: null, targets: await _checkAll());
    if (_cancelled) {
      return AutoPickReport(baseline: baseline, results: results, cancelled: true);
    }
    // Ни один адрес не нашёлся — дело не в блокировках, а в сети.
    if (baseline.targets.every((t) => t.outcome == ProbeOutcome.noHost)) {
      throw const NoInternetException();
    }
    // Всё открывается и так — сравнивать стратегии не с чем.
    if (baseline.okCount == baseline.total) {
      onProgress?.call(AutoPickProgress(
          index: 0, total: strategies.length, baseline: baseline, results: results));
      return AutoPickReport(baseline: baseline, results: results, cancelled: false);
    }

    for (var i = 0; i < strategies.length; i++) {
      final s = strategies[i];
      onProgress?.call(AutoPickProgress(
          index: i, total: strategies.length, current: s, baseline: baseline, results: results));
      try {
        final started = await env.start(s);
        if (_cancelled) break;
        if (!started) {
          results.add(StrategyResult(strategy: s, targets: const [], failedToStart: true));
          continue;
        }
        final checked = await _checkAll();
        if (_cancelled) break;
        results.add(StrategyResult(strategy: s, targets: checked));
      } finally {
        await env.stop();
      }
    }
    onProgress?.call(AutoPickProgress(
        index: results.length, total: strategies.length, baseline: baseline, results: results));
    return AutoPickReport(baseline: baseline, results: results, cancelled: _cancelled);
  }
}
