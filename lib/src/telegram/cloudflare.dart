import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../app_info.dart';

// Cloudflare-прокси — как в Flowseal/tg-ws-proxy (proxy/config.py, proxy/balancer.py):
// домены на Cloudflare, у которых kws1…kws5 и kws203 ведут на дата-центры Telegram.
// Сами домены в лаунчере не хранятся: список скачивается с GitHub tg-ws-proxy при
// запуске прокси и лежит в кэше в той же записи, что у tg-ws-proxy. Открытые имена —
// только в памяти изолята прокси; в журнал они не пишутся.

/// Список доменов tg-ws-proxy.
const cloudflareDomainsUrl =
    'https://raw.githubusercontent.com/Flowseal/tg-ws-proxy/main/.github/cfproxy-domains.txt';

/// Меньше — список битый, оставляем прежний (как у tg-ws-proxy).
const cloudflareMinDomains = 3;

/// Дата-центры, для которых у доменов есть записи kwsN.
const _dcs = [1, 2, 3, 4, 5, 203];

/// Кэш списка рядом с настройками лаунчера.
String cloudflareCachePath() {
  final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
  return p.join(appData, 'ZapretLauncher', 'telegram-cloudflare.txt');
}

/// Строка списка → домен. Запись tg-ws-proxy (`_dd`): буквы имени сдвинуты по
/// алфавиту на число букв в нём, а «.com» стоит вместо настоящей зоны.
String decodeCloudflareDomain(String line) {
  if (!line.endsWith('.com')) return line;
  final name = line.substring(0, line.length - 4);
  bool letter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  final shift = name.codeUnits.where(letter).length;
  final out = StringBuffer();
  for (final c in name.codeUnits) {
    if (!letter(c)) {
      out.writeCharCode(c);
      continue;
    }
    final base = c >= 97 ? 97 : 65;
    out.writeCharCode((c - base - shift) % 26 + base);
  }
  return '$out${String.fromCharCodes(const [46, 99, 111, 46, 117, 107])}';
}

/// Домены из текста списка: без пустых строк и «#», проверенные и без повторов.
List<String> parseCloudflareList(String text) {
  final seen = <String>{};
  return [
    for (final raw in const LineSplitter().convert(text))
      if (raw.trim() case final line
          when line.isNotEmpty && !line.startsWith('#'))
        if (decodeCloudflareDomain(line).toLowerCase() case final d
            when _validDomain(d) && seen.add(d))
          d,
  ];
}

bool _validDomain(String d) {
  if (d.isEmpty || d.length > 253) return false;
  final labels = d.split('.');
  if (labels.length < 2) return false;
  final label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  if (!labels.every(label.hasMatch)) return false;
  final tld = labels.last;
  return tld.length >= 2 && tld.contains(RegExp('[a-z]'));
}

/// Домены и какой сейчас у каждого дата-центра: удачный остаётся первым, остальные —
/// вразброс, чтобы подключения расходились по доменам.
class CloudflareDomains {
  CloudflareDomains([List<String> domains = const [], Random? random])
    : _random = random ?? Random() {
    update(domains);
  }

  final Random _random;
  List<String> _domains = const [];
  final _byDc = <int, String>{};

  bool get isEmpty => _domains.isEmpty;
  int get length => _domains.length;

  void update(List<String> domains) {
    if (domains.length == _domains.length &&
        domains.toSet().containsAll(_domains)) {
      return;
    }
    _domains = List.unmodifiable(domains);
    _byDc.clear();
    if (_domains.isEmpty) return;
    for (final dc in _dcs) {
      _byDc[dc] = _domains[_random.nextInt(_domains.length)];
    }
  }

  /// Домены для [dc]: сначала текущий.
  Iterable<String> forDc(int dc) sync* {
    final current = _byDc[dc];
    if (current != null && _domains.contains(current)) yield current;
    for (final d in [..._domains]..shuffle(_random)) {
      if (d != current) yield d;
    }
  }

  /// Через [domain] подключились — с него и начинаем для [dc].
  void use(int dc, String domain) => _byDc[dc] = domain;
}

/// Откуда брать список: адрес и файл кэша; null — не скачивать или не кэшировать.
class CloudflareSource {
  const CloudflareSource({this.url = cloudflareDomainsUrl, this.cachePath});

  /// Без Cloudflare-прокси — например, в тестах.
  const CloudflareSource.off() : url = null, cachePath = null;

  final String? url;
  final String? cachePath;
}

/// Наполняет [domains]: сразу из кэша, потом свежим списком с GitHub — при запуске
/// прокси и раз в час, пока он работает.
class CloudflareRefresher {
  CloudflareRefresher(
    this.domains,
    this.source, {
    this.onLog,
    this.every = const Duration(hours: 1),
  });

  final CloudflareDomains domains;
  final CloudflareSource source;
  final void Function(String line)? onLog;
  final Duration every;

  HttpClient? _http;
  Timer? _timer;

  /// Кэш читается сразу; скачивание идёт в фоне — прокси его не ждёт.
  void start() {
    _loadCache();
    if (source.url == null) return;
    unawaited(refresh());
    _timer = Timer.periodic(every, (_) => unawaited(refresh()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _http?.close(force: true);
    _http = null;
  }

  void _loadCache() {
    final path = source.cachePath;
    if (path == null) return;
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final list = parseCloudflareList(file.readAsStringSync());
      if (list.length >= cloudflareMinDomains) domains.update(list);
    } on Object {
      // Битый кэш — дождёмся свежего списка.
    }
  }

  Future<void> refresh() async {
    final url = source.url;
    if (url == null) return;
    final http = _http ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = '${AppInfo.name}/${AppInfo.version}';
    try {
      // Случайный хвост — мимо кэша GitHub, как у tg-ws-proxy.
      final r = Random();
      final bust = String.fromCharCodes([
        for (var i = 0; i < 7; i++) 97 + r.nextInt(26),
      ]);
      final request = await http.getUrl(Uri.parse('$url?$bust'));
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('ответ ${response.statusCode}');
      }
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 15));
      final list = parseCloudflareList(text);
      if (list.length < cloudflareMinDomains) {
        _log('Список доменов Cloudflare не подошёл — оставляю прежний');
        return;
      }
      domains.update(list);
      _saveCache(text);
      _log('Cloudflare: доменов ${list.length}');
    } on Object catch (e) {
      _log(
        domains.isEmpty
            ? 'Список доменов Cloudflare не скачался ($e) — без Cloudflare'
            : 'Список доменов Cloudflare не скачался ($e) — беру из кэша',
      );
    }
  }

  /// В кэш — текст как есть: в той же записи, без открытых имён.
  void _saveCache(String text) {
    final path = source.cachePath;
    if (path == null) return;
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    } on Object {
      // Без кэша просто скачаем снова при следующем запуске.
    }
  }

  void _log(String line) => onLog?.call(line);
}
