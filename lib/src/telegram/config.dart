import 'dart:io';

// Настройки прокси — как config.json у Flowseal/tg-ws-proxy (utils/default_config.py,
// ui/settings_form.py): те же поля, значения по умолчанию и проверки. Нет того, что
// у лаунчера своё (автозапуск, тема, язык, обновления), и HTTP/2 для медиа.

/// Порт прокси по умолчанию.
const defaultTelegramProxyPort = 1080;

/// DC → IP по умолчанию: веб-версия Telegram для DC 2 и 4 (--dc-ip у tg-ws-proxy).
const defaultTelegramDcIp = ['2:149.154.167.220', '4:149.154.167.220'];

class TelegramProxyConfig {
  const TelegramProxyConfig({
    this.host = '127.0.0.1',
    this.port = defaultTelegramProxyPort,
    this.secret = '',
    this.dcIp = defaultTelegramDcIp,
    this.cfproxy = true,
    this.cfproxyUserDomainEnabled = false,
    this.cfproxyUserDomains = const [],
    this.cfproxyWorkerEnabled = false,
    this.cfproxyWorkerDomains = const [],
    this.noSecure = false,
    this.verbose = false,
    this.bufKb = 256,
    this.poolSize = 4,
    this.logMaxMb = 5,
  });

  /// Адрес, на котором прокси принимает подключения.
  final String host;
  final int port;

  /// Ключ: 32 hex-символа; пустой — создаётся при первом запуске.
  final String secret;

  /// Правила «номер:IP» — куда идёт WebSocket для DC.
  final List<String> dcIp;

  /// Cloudflare-прокси для недоступных дата-центров.
  final bool cfproxy;

  /// Свои домены вместо списка tg-ws-proxy.
  final bool cfproxyUserDomainEnabled;
  final List<String> cfproxyUserDomains;

  /// Домены Cloudflare Worker (name.account.workers.dev).
  final bool cfproxyWorkerEnabled;
  final List<String> cfproxyWorkerDomains;

  /// Порт 80 без TLS для CF-прокси и CF Worker.
  final bool noSecure;

  /// Подробный лог: каждая сессия и неудачные подключения.
  final bool verbose;

  /// Буфер приёма и передачи сокетов, КБ.
  final int bufKb;

  /// Готовых WebSocket на каждый DC; 0 — без прямого WebSocket к DC.
  final int poolSize;

  /// Размер файла лога, после которого он начинается заново.
  final int logMaxMb;

  /// DC → IP; правила проверены при сохранении, кривые пропускаются.
  Map<int, String> get webSocketIps => {
    for (final rule in dcIp)
      if (parseDcIpRule(rule) case (final dc, final ip)) dc: ip,
  };

  /// Свои домены CF-прокси, если включены.
  List<String> get userCloudflareDomains =>
      cfproxyUserDomainEnabled ? cfproxyUserDomains : const [];

  /// Домены CF Worker, если включены.
  List<String> get workerDomains =>
      cfproxyWorkerEnabled ? cfproxyWorkerDomains : const [];

  /// Адрес в ссылке для Telegram на этом компьютере.
  String get linkHost => host == '0.0.0.0' ? '127.0.0.1' : host;

  TelegramProxyConfig copyWith({
    String? host,
    int? port,
    String? secret,
    List<String>? dcIp,
    bool? cfproxy,
    bool? cfproxyUserDomainEnabled,
    List<String>? cfproxyUserDomains,
    bool? cfproxyWorkerEnabled,
    List<String>? cfproxyWorkerDomains,
    bool? noSecure,
    bool? verbose,
    int? bufKb,
    int? poolSize,
    int? logMaxMb,
  }) => TelegramProxyConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    secret: secret ?? this.secret,
    dcIp: dcIp ?? this.dcIp,
    cfproxy: cfproxy ?? this.cfproxy,
    cfproxyUserDomainEnabled:
        cfproxyUserDomainEnabled ?? this.cfproxyUserDomainEnabled,
    cfproxyUserDomains: cfproxyUserDomains ?? this.cfproxyUserDomains,
    cfproxyWorkerEnabled: cfproxyWorkerEnabled ?? this.cfproxyWorkerEnabled,
    cfproxyWorkerDomains: cfproxyWorkerDomains ?? this.cfproxyWorkerDomains,
    noSecure: noSecure ?? this.noSecure,
    verbose: verbose ?? this.verbose,
    bufKb: bufKb ?? this.bufKb,
    poolSize: poolSize ?? this.poolSize,
    logMaxMb: logMaxMb ?? this.logMaxMb,
  );

  /// Ключи — как в config.json у tg-ws-proxy.
  Map<String, Object> toJson() => {
    'host': host,
    'port': port,
    'secret': secret,
    'dc_ip': dcIp,
    'cfproxy': cfproxy,
    'cfproxy_user_domain_enabled': cfproxyUserDomainEnabled,
    'cfproxy_user_domain': cfproxyUserDomains,
    'cfproxy_worker_enabled': cfproxyWorkerEnabled,
    'cfproxy_worker_domain': cfproxyWorkerDomains,
    'no_secure': noSecure,
    'verbose': verbose,
    'buf_kb': bufKb,
    'pool_size': poolSize,
    'log_max_mb': logMaxMb,
  };

  /// Чего нет или что не того типа — по умолчанию.
  factory TelegramProxyConfig.fromJson(Map<Object?, Object?> j) {
    const d = TelegramProxyConfig();
    List<String> strings(Object? v, List<String> or) =>
        v is List ? [for (final x in v) ?(x is String ? x : null)] : or;
    int number(Object? v, int or) => v is num ? v.toInt() : or;
    return TelegramProxyConfig(
      host: j['host'] as String? ?? d.host,
      port: number(j['port'], d.port),
      secret: j['secret'] as String? ?? d.secret,
      dcIp: strings(j['dc_ip'], d.dcIp),
      cfproxy: j['cfproxy'] as bool? ?? d.cfproxy,
      cfproxyUserDomainEnabled:
          j['cfproxy_user_domain_enabled'] as bool? ??
          d.cfproxyUserDomainEnabled,
      cfproxyUserDomains: strings(
        j['cfproxy_user_domain'],
        d.cfproxyUserDomains,
      ),
      cfproxyWorkerEnabled:
          j['cfproxy_worker_enabled'] as bool? ?? d.cfproxyWorkerEnabled,
      cfproxyWorkerDomains: strings(
        j['cfproxy_worker_domain'],
        d.cfproxyWorkerDomains,
      ),
      noSecure: j['no_secure'] as bool? ?? d.noSecure,
      verbose: j['verbose'] as bool? ?? d.verbose,
      bufKb: number(j['buf_kb'], d.bufKb),
      poolSize: number(j['pool_size'], d.poolSize),
      logMaxMb: number(j['log_max_mb'], d.logMaxMb),
    );
  }
}

/// «номер:IP» → (DC, IPv4); null — не правило (как parse_dc_ip_list у tg-ws-proxy).
(int, String)? parseDcIpRule(String rule) {
  final i = rule.indexOf(':');
  if (i < 0) return null;
  final dc = int.tryParse(rule.substring(0, i).trim());
  final ip = rule.substring(i + 1).trim();
  final address = InternetAddress.tryParse(ip);
  if (dc == null || address == null) return null;
  if (address.type != InternetAddressType.IPv4) return null;
  return (dc, ip);
}

/// Список доменов из поля: через запятую, точку с запятой или пробел, без повторов.
List<String> splitDomains(String text) {
  final seen = <String>{};
  return [
    for (final raw in text.split(RegExp(r'[\s,;]+')))
      if (raw.trim().toLowerCase() case final d when d.isNotEmpty)
        if (seen.add(d)) d,
  ];
}

/// Значения формы настроек — текстом, как ввёл человек.
class TelegramConfigForm {
  const TelegramConfigForm({
    required this.host,
    required this.port,
    required this.secret,
    required this.dcIp,
    required this.cfproxy,
    required this.cfproxyUserDomainEnabled,
    required this.cfproxyUserDomains,
    required this.cfproxyWorkerEnabled,
    required this.cfproxyWorkerDomains,
    required this.noSecure,
    required this.verbose,
    required this.bufKb,
    required this.poolSize,
    required this.logMaxMb,
  });

  factory TelegramConfigForm.of(TelegramProxyConfig c) => TelegramConfigForm(
    host: c.host,
    port: '${c.port}',
    secret: c.secret,
    dcIp: c.dcIp.join('\n'),
    cfproxy: c.cfproxy,
    cfproxyUserDomainEnabled: c.cfproxyUserDomainEnabled,
    cfproxyUserDomains: c.cfproxyUserDomains.join(', '),
    cfproxyWorkerEnabled: c.cfproxyWorkerEnabled,
    cfproxyWorkerDomains: c.cfproxyWorkerDomains.join(', '),
    noSecure: c.noSecure,
    verbose: c.verbose,
    bufKb: '${c.bufKb}',
    poolSize: '${c.poolSize}',
    logMaxMb: '${c.logMaxMb}',
  );

  final String host;
  final String port;
  final String secret;
  final String dcIp;
  final bool cfproxy;
  final bool cfproxyUserDomainEnabled;
  final String cfproxyUserDomains;
  final bool cfproxyWorkerEnabled;
  final String cfproxyWorkerDomains;
  final bool noSecure;
  final bool verbose;
  final String bufKb;
  final String poolSize;
  final String logMaxMb;

  /// Те же значения — изменений в форме нет.
  bool sameAs(TelegramConfigForm o) =>
      host == o.host &&
      port == o.port &&
      secret == o.secret &&
      dcIp == o.dcIp &&
      cfproxy == o.cfproxy &&
      cfproxyUserDomainEnabled == o.cfproxyUserDomainEnabled &&
      cfproxyUserDomains == o.cfproxyUserDomains &&
      cfproxyWorkerEnabled == o.cfproxyWorkerEnabled &&
      cfproxyWorkerDomains == o.cfproxyWorkerDomains &&
      noSecure == o.noSecure &&
      verbose == o.verbose &&
      bufKb == o.bufKb &&
      poolSize == o.poolSize &&
      logMaxMb == o.logMaxMb;

  /// Ошибки по полям; пусто — можно сохранять. Тексты — как у tg-ws-proxy.
  Map<String, String> validate() {
    final errors = <String, String>{};
    final address = InternetAddress.tryParse(host.trim());
    if (address == null || address.type != InternetAddressType.IPv4) {
      errors['host'] = 'Некорректный IP-адрес.';
    }
    final p = int.tryParse(port.trim());
    if (p == null || p < 1 || p > 65535) {
      errors['port'] = 'Порт должен быть числом 1-65535';
    }
    final s = secret.trim();
    if (s.length != 32) {
      errors['secret'] =
          'Ключ должен содержать ровно 32 hex-символа (16 байт).';
    } else if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) {
      errors['secret'] =
          'Ключ должен состоять только из hex-символов (0-9, a-f).';
    }
    for (final rule in _lines(dcIp)) {
      if (!rule.contains(':')) {
        errors['dcIp'] = 'Неверный формат DC:IP: $rule';
        break;
      }
      if (parseDcIpRule(rule) == null) {
        errors['dcIp'] = 'Неверная запись DC:IP: $rule';
        break;
      }
    }
    if (cfproxyUserDomainEnabled && splitDomains(cfproxyUserDomains).isEmpty) {
      errors['cfproxyUserDomains'] = 'Укажите хотя бы один домен.';
    }
    if (cfproxyWorkerEnabled && splitDomains(cfproxyWorkerDomains).isEmpty) {
      errors['cfproxyWorkerDomains'] = 'Укажите хотя бы один домен.';
    }
    final buf = int.tryParse(bufKb.trim());
    if (buf == null || buf < 4 || buf > 65536) {
      errors['bufKb'] = 'Число от 4 до 65536';
    }
    final pool = int.tryParse(poolSize.trim());
    if (pool == null || pool < 0 || pool > 32) {
      errors['poolSize'] = 'Число от 0 до 32';
    }
    final log = int.tryParse(logMaxMb.trim());
    if (log == null || log < 1 || log > 1024) {
      errors['logMaxMb'] = 'Число от 1 до 1024';
    }
    return errors;
  }

  /// Настройки из проверенной формы ([validate] пуст).
  TelegramProxyConfig toConfig() => TelegramProxyConfig(
    host: host.trim(),
    port: int.parse(port.trim()),
    secret: secret.trim().toLowerCase(),
    dcIp: _lines(dcIp).toList(),
    cfproxy: cfproxy,
    cfproxyUserDomainEnabled: cfproxyUserDomainEnabled,
    cfproxyUserDomains: splitDomains(cfproxyUserDomains),
    cfproxyWorkerEnabled: cfproxyWorkerEnabled,
    cfproxyWorkerDomains: splitDomains(cfproxyWorkerDomains),
    noSecure: noSecure,
    verbose: verbose,
    bufKb: int.parse(bufKb.trim()),
    poolSize: int.parse(poolSize.trim()),
    logMaxMb: int.parse(logMaxMb.trim()),
  );

  static Iterable<String> _lines(String text) =>
      text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
}
