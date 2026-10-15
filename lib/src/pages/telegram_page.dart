import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../telegram/telegram_proxy.dart';
import '../ui/ui.dart';
import 'common.dart';

/// Кратко — для строки на главной и в «Экспериментальных функциях».
String telegramLine(AppController c) {
  final config = c.settings.telegram;
  return switch (c.telegramState) {
    TelegramProxyState.off =>
      'Прокси для Telegram Desktop, когда он не грузится.',
    TelegramProxyState.starting => 'Прокси запускается…',
    TelegramProxyState.on => 'Прокси на ${config.linkHost}:${config.port}.',
    TelegramProxyState.failed =>
      '${c.telegramError?.title ?? 'Прокси не запустился'}.',
  };
}

/// «Экспериментальные функции» → «Прокси для Telegram»: включить, подключить в
/// Telegram и настройки — те же, что у TG WS Proxy (Flowseal/tg-ws-proxy).
class TelegramPage extends StatefulWidget {
  const TelegramPage({super.key});

  @override
  State<TelegramPage> createState() => _TelegramPageState();
}

class _TelegramPageState extends State<TelegramPage> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _secret = TextEditingController();
  final _dcIp = TextEditingController();
  final _cfDomains = TextEditingController();
  final _workerDomains = TextEditingController();
  final _bufKb = TextEditingController();
  final _poolSize = TextEditingController();
  final _logMaxMb = TextEditingController();
  var _cfproxy = true;
  var _cfCustom = false;
  var _worker = false;
  var _noSecure = false;
  var _verbose = false;
  Map<String, String> _errors = const {};
  bool _saving = false;

  /// Сохранённое — с ним сравниваем, есть ли изменения.
  late TelegramConfigForm _saved;

  List<TextEditingController> get _fields => [
    _host,
    _port,
    _secret,
    _dcIp,
    _cfDomains,
    _workerDomains,
    _bufKb,
    _poolSize,
    _logMaxMb,
  ];

  @override
  void initState() {
    super.initState();
    _fill(TelegramConfigForm.of(AppScope.read(context).telegramConfig));
    for (final f in _fields) {
      f.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  void _changed() => setState(() {});

  void _fill(TelegramConfigForm form, {bool saved = true}) {
    if (saved) _saved = form;
    _host.text = form.host;
    _port.text = form.port;
    _secret.text = form.secret;
    _dcIp.text = form.dcIp;
    _cfDomains.text = form.cfproxyUserDomains;
    _workerDomains.text = form.cfproxyWorkerDomains;
    _bufKb.text = form.bufKb;
    _poolSize.text = form.poolSize;
    _logMaxMb.text = form.logMaxMb;
    _cfproxy = form.cfproxy;
    _cfCustom = form.cfproxyUserDomainEnabled;
    _worker = form.cfproxyWorkerEnabled;
    _noSecure = form.noSecure;
    _verbose = form.verbose;
    _errors = const {};
  }

  TelegramConfigForm get _form => TelegramConfigForm(
    host: _host.text,
    port: _port.text,
    secret: _secret.text,
    dcIp: _dcIp.text,
    cfproxy: _cfproxy,
    cfproxyUserDomainEnabled: _cfCustom,
    cfproxyUserDomains: _cfDomains.text,
    cfproxyWorkerEnabled: _worker,
    cfproxyWorkerDomains: _workerDomains.text,
    noSecure: _noSecure,
    verbose: _verbose,
    bufKb: _bufKb.text,
    poolSize: _poolSize.text,
    logMaxMb: _logMaxMb.text,
  );

  bool get _dirty => !_form.sameAs(_saved);

  Future<void> _save(AppController c) async {
    final form = _form;
    final errors = form.validate();
    setState(() => _errors = errors);
    if (errors.isNotEmpty) {
      c.toasts.show(
        const ToastData('Проверьте настройки', icon: LucideIcons.circleAlert),
      );
      return;
    }
    final before = c.telegramConfig;
    final config = form.toConfig();
    setState(() => _saving = true);
    await c.setTelegramConfig(config);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _fill(TelegramConfigForm.of(config));
    });
    // Ссылка в Telegram — с адресом, портом и ключом: поменялись — нужна новая.
    final relink =
        before.linkHost != config.linkHost ||
        before.port != config.port ||
        before.secret != config.secret;
    c.toasts.show(
      relink && c.settings.telegramProxy
          ? ToastData(
              'Настройки сохранены. Адрес, порт или ключ поменялись — '
              'подключите прокси в Telegram заново',
              icon: LucideIcons.send,
              actionLabel: 'Подключить',
              onAction: () => _connect(context, c),
            )
          : const ToastData('Настройки сохранены'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final state = c.telegramState;
    final config = c.settings.telegram;
    final dirty = _dirty;
    var i = 0;

    return NcPage(
      header: appHeader(
        context,
        c,
        title: 'Прокси для Telegram',
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      fab: dirty
          ? NcFab(
              icon: LucideIcons.check,
              label: _saving ? 'Сохраняю…' : 'Сохранить',
              onPressed: _saving ? null : () => _save(c),
            )
          : null,
      children: [
        ...importantRows(context, c),
        Appear(
          index: i++,
          child: const PageTitle(
            'Прокси для Telegram',
            description:
                'TG WS Proxy внутри лаунчера: Telegram Desktop подключается к нему, '
                'а он — к Telegram через веб-версию. Zapret для этого не нужен.',
          ),
        ),
        const SizedBox(height: 24),
        Appear(index: i++, child: _statusCard(c, state, config)),
        if (state == TelegramProxyState.on) ...[
          const SizedBox(height: NcSpace.gapCards),
          Appear(index: i++, child: _connectCard(c, config)),
        ],
        const SizedBox(height: 32),
        Appear(
          index: i++,
          child: Row(
            children: [
              const Expanded(child: SectionTitle('Настройки')),
              if (dirty)
                NcQuietButton(
                  label: 'Отменить изменения',
                  onPressed: () => setState(() => _fill(_saved)),
                )
              else
                NcQuietButton(
                  label: 'По умолчанию',
                  onPressed: () => setState(
                    () => _fill(
                      TelegramConfigForm.of(
                        TelegramProxyConfig(secret: _secret.text),
                      ),
                      saved: false,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Appear(
          index: i++,
          child: Text(
            'Как в настройках TG WS Proxy. Сохранённые применяются сразу — '
            'работающий прокси перезапустится.',
            style: NcType.body.copyWith(color: context.palette.muted),
          ),
        ),
        const SizedBox(height: 16),
        Appear(index: i++, child: _connectionSection()),
        const SizedBox(height: NcSpace.gapCards),
        Appear(index: i++, child: _dcSection()),
        const SizedBox(height: NcSpace.gapCards),
        Appear(index: i++, child: _cloudflareSection()),
        const SizedBox(height: NcSpace.gapCards),
        Appear(index: i++, child: _workerSection()),
        const SizedBox(height: NcSpace.gapCards),
        Appear(index: i++, child: _logsSection(c)),
        const SizedBox(height: 32),
        Appear(index: i++, child: _notesCard()),
      ],
    );
  }

  // ── Состояние и подключение ──

  Widget _statusCard(
    AppController c,
    TelegramProxyState state,
    TelegramProxyConfig config,
  ) => NcSettingsCard(
    children: [
      NcSettingRow(
        title: 'Прокси для Telegram',
        description:
            'Работает, пока открыт лаунчер — в окне или в трее. '
            'Включится сам при следующем запуске.',
        below: switch (state) {
          TelegramProxyState.off => null,
          TelegramProxyState.starting => const StatusLine(
            tone: Tone.warning,
            text: 'Запускается…',
          ),
          TelegramProxyState.on => StatusLine(
            tone: Tone.success,
            text: _statsLine(c, config),
          ),
          TelegramProxyState.failed => StatusLine(
            tone: Tone.danger,
            text: [
              c.telegramError?.title,
              c.telegramError?.detail,
            ].nonNulls.join('. '),
          ),
        },
        trailing: NcSwitch(
          value: c.settings.telegramProxy,
          label: 'Прокси для Telegram',
          onChanged: state == TelegramProxyState.starting
              ? null
              : c.setTelegramProxy,
        ),
      ),
      if (state == TelegramProxyState.failed)
        NcSettingRow(
          title: 'Порт ${config.port} занят?',
          description:
              'Его может занимать TG WS Proxy или другой прокси. Закройте его '
              'или поменяйте порт ниже — в «Подключение MTProto».',
          trailing: NcButton.gray(
            label: 'Ещё раз',
            onPressed: c.retryTelegramProxy,
          ),
        ),
    ],
  );

  Widget _connectCard(
    AppController c,
    TelegramProxyConfig config,
  ) => NcSettingsCard(
    children: [
      NcSettingRow(
        title: 'Подключить в Telegram',
        description:
            'Telegram Desktop спросит, включить ли прокси, — нажмите «Включить». '
            'Это нужно один раз и после смены адреса, порта или ключа.',
        trailing: NcButton(
          label: 'Подключить',
          icon: LucideIcons.send,
          onPressed: () => _connect(context, c),
        ),
      ),
      NcSettingRow(
        title: 'Telegram не открылся?',
        description:
            'Скопируйте ссылку, отправьте её себе в «Избранное» и нажмите на неё. '
            'Или вручную: «Настройки» → «Продвинутые настройки» → «Тип подключения» → '
            '«Прокси», тип MTProto, сервер ${config.linkHost}, порт ${config.port}, '
            'ключ dd${config.secret}.',
        trailing: NcButton.gray(
          label: 'Скопировать',
          icon: LucideIcons.copy,
          onPressed: () => _copyLink(c),
        ),
      ),
    ],
  );

  // ── Настройки: разделы как у TG WS Proxy ──

  Widget _connectionSection() => NcSettingsCard(
    children: [
      NcSettingRow(
        title: 'Подключение MTProto',
        description:
            'Адрес и порт, на которых прокси принимает подключения. В Telegram Desktop '
            'в настройках прокси должен быть тот же порт.',
        below: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: NcTextField(
                      controller: _host,
                      label: 'IP-адрес',
                      hint: '127.0.0.1',
                      error: _errors['host'],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 120,
                    child: NcTextField(
                      controller: _port,
                      label: 'Порт',
                      hint: '$defaultTelegramProxyPort',
                      maxLength: 5,
                      error: _errors['port'],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: NcTextField(
                      controller: _secret,
                      label: 'Ключ',
                      maxLength: 32,
                      error: _errors['secret'],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: _errors['secret'] == null ? 0 : 24,
                    ),
                    child: NcButton.gray(
                      label: 'Новый',
                      icon: LucideIcons.refreshCw,
                      onPressed: () => _secret.text = generateTelegramSecret(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _dcSection() => NcSettingsCard(
    children: [
      NcSettingRow(
        title: 'Датацентры Telegram (DC → IP)',
        description:
            'Соответствие номера датацентра Telegram (DC) и IP-адреса сервера. '
            'По одному правилу на строку, формат: номер:IP.',
        below: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: NcTextField(
            controller: _dcIp,
            hint: defaultTelegramDcIp.join('\n'),
            minLines: 2,
            maxLines: 6,
            error: _errors['dcIp'],
          ),
        ),
      ),
    ],
  );

  Widget _cloudflareSection() => NcSettingsCard(
    children: [
      NcSettingRow(
        title: 'Включить CF-прокси',
        description:
            'Cloudflare Proxy: использовать Cloudflare для недоступных датацентров. '
            'Домены — из списка TG WS Proxy, если не указаны свои.',
        trailing: NcSwitch(
          value: _cfproxy,
          label: 'Включить CF-прокси',
          onChanged: (v) => setState(() => _cfproxy = v),
        ),
      ),
      NcSettingRow(
        title: 'Свой домен',
        description:
            'Указать свои домены вместо автоматического выбора — через запятую. '
            'Нужны записи kws1…kws5 и kws203 на адреса датацентров.',
        trailing: NcSwitch(
          value: _cfCustom,
          label: 'Свой домен',
          onChanged: _cfproxy ? (v) => setState(() => _cfCustom = v) : null,
        ),
        below: _cfproxy && _cfCustom
            ? Padding(
                padding: const EdgeInsets.only(top: 12),
                child: NcTextField(
                  controller: _cfDomains,
                  hint: 'example.com, example.org',
                  error: _errors['cfproxyUserDomains'],
                ),
              )
            : null,
      ),
    ],
  );

  Widget _workerSection() => NcSettingsCard(
    children: [
      NcSettingRow(
        title: 'Cloudflare Worker',
        description:
            'Домены Cloudflare Worker (например, name.account.workers.dev) через '
            'запятую. Прокси передаёт через них подключение к датацентру по IP — '
            'раньше CF-прокси.',
        trailing: NcSwitch(
          value: _worker,
          label: 'Cloudflare Worker',
          onChanged: (v) => setState(() => _worker = v),
        ),
        below: _worker
            ? Padding(
                padding: const EdgeInsets.only(top: 12),
                child: NcTextField(
                  controller: _workerDomains,
                  hint: 'name.account.workers.dev',
                  error: _errors['cfproxyWorkerDomains'],
                ),
              )
            : null,
      ),
    ],
  );

  Widget _logsSection(AppController c) => NcSettingsCard(
    children: [
      NcSettingRow(
        title: 'Подробное логирование (verbose)',
        description: 'В файл лога пишется больше подробностей — нужно при поиске неполадок.',
        trailing: NcSwitch(
          value: _verbose,
          label: 'Подробное логирование',
          onChanged: (v) => setState(() => _verbose = v),
        ),
      ),
      NcSettingRow(
        title: 'Выключить TLS для CF-прокси и CF-worker',
        description: 'Подключаться к ним по порту 80, без шифрования TLS.',
        trailing: NcSwitch(
          value: _noSecure,
          label: 'Выключить TLS для CF-прокси и CF-worker',
          onChanged: (v) => setState(() => _noSecure = v),
        ),
      ),
      NcSettingRow(
        title: 'Производительность',
        description:
            'Буфер приёма и передачи; сколько готовых WebSocket держать для каждого '
            'датацентра (0 отключает прямой WebSocket); размер файла лога, после '
            'которого он начинается заново.',
        below: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: NcTextField(
                  controller: _bufKb,
                  label: 'Буфер, КБ',
                  hint: '256',
                  error: _errors['bufKb'],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NcTextField(
                  controller: _poolSize,
                  label: 'Пул WebSocket',
                  hint: '4',
                  error: _errors['poolSize'],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NcTextField(
                  controller: _logMaxMb,
                  label: 'Лог, МБ',
                  hint: '5',
                  error: _errors['logMaxMb'],
                ),
              ),
            ],
          ),
        ),
      ),
      NcSettingRow(
        title: 'Файл лога',
        description:
            'Подключения, ошибки и итог каждой сессии. Пригодится, если Telegram '
            'не подключается.',
        trailing: NcButton.gray(
          label: 'Открыть логи',
          icon: LucideIcons.fileText,
          onPressed: () {
            if (!c.openTelegramLog()) {
              c.toasts.show(
                const ToastData(
                  'Файл логов ещё не создан',
                  icon: LucideIcons.fileText,
                ),
              );
            }
          },
        ),
      ),
    ],
  );

  Widget _notesCard() => const NcSettingsCard(
    children: [
      NcSettingRow(
        title: 'Если выйти из лаунчера',
        description:
            'Telegram перестанет подключаться: прокси остановится вместе с '
            'лаунчером. Если прокси больше не нужен, выключите его и в Telegram — '
            'в «Тип подключения», где подключали.',
      ),
      NcSettingRow(
        title: 'Фото и видео',
        description:
            'Сообщения идут через веб-версию Telegram, остальные '
            'дата-центры — через Cloudflare. Если Cloudflare у провайдера '
            'недоступен, часть фото и видео может грузиться медленно или '
            'не грузиться.',
      ),
    ],
  );

  static String _statsLine(AppController c, TelegramProxyConfig config) {
    final s = c.telegramStats;
    final parts = ['Работает на ${config.linkHost}:${config.port}'];
    if (s.active > 0) parts.add('подключений: ${s.active}');
    if (s.badHandshakes > 0 && s.webSocket + s.cloudflare + s.tcp == 0) {
      parts.add('Telegram подключается со старой ссылкой — подключите заново');
    }
    return parts.join(' · ');
  }

  /// Открывает ссылку в Telegram; закрытый — только с согласия, а без Telegram
  /// Desktop ссылку открыть нечем — копируем её.
  static Future<void> _connect(BuildContext context, AppController c) async {
    if (!c.telegramDesktopInstalled) {
      return _copyLink(
        c,
        'Telegram Desktop не найден. Ссылка скопирована — откройте её в Telegram',
      );
    }
    final go = await confirmTelegramLaunch(
      context,
      c,
      consequence: 'Если запустить, он спросит, подключить ли прокси.',
    );
    if (go && !c.openTelegramLink()) {
      return _copyLink(
        c,
        'Не удалось открыть Telegram. Ссылка скопирована — откройте её в Telegram',
      );
    }
  }

  static Future<void> _copyLink(
    AppController c, [
    String message = 'Ссылка скопирована',
  ]) async {
    await Clipboard.setData(ClipboardData(text: c.telegramLink));
    c.toasts.show(ToastData(message, icon: LucideIcons.copy));
  }
}
