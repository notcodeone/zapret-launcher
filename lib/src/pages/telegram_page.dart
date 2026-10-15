import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../ui/ui.dart';
import 'common.dart';

/// Кратко — для строки на главной.
String telegramLine(AppController c) => switch (c.telegramState) {
  TelegramProxyState.off =>
    'Прокси для Telegram Desktop, когда он не грузится.',
  TelegramProxyState.starting => 'Прокси запускается…',
  TelegramProxyState.on => 'Прокси на 127.0.0.1:${c.settings.telegramPort}.',
  TelegramProxyState.failed =>
    '${c.telegramError?.title ?? 'Прокси не запустился'}.',
};

/// Прокси для Telegram Desktop: включить, подключить в Telegram, что важно знать.
class TelegramPage extends StatelessWidget {
  const TelegramPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final state = c.telegramState;
    final on = c.settings.telegramProxy;
    final port = c.settings.telegramPort;
    var i = 0;

    return NcPage(
      header: appHeader(
        context,
        c,
        title: 'Telegram',
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        Appear(
          index: i++,
          child: const PageTitle(
            'Telegram',
            description:
                'Прокси внутри лаунчера: Telegram Desktop подключается к нему, а он — '
                'к Telegram через веб-версию. Zapret для этого не нужен.',
          ),
        ),
        const SizedBox(height: 24),
        Appear(
          index: i++,
          child: NcSettingsCard(
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
                    text: _statsLine(c, port),
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
                  value: on,
                  label: 'Прокси для Telegram',
                  onChanged: state == TelegramProxyState.starting
                      ? null
                      : c.setTelegramProxy,
                ),
              ),
              if (state == TelegramProxyState.failed)
                NcSettingRow(
                  title: 'Порт $port занят?',
                  description:
                      'Его может занимать TG WS Proxy или другой прокси для Telegram. '
                      'Закройте его — прокси лаунчера его заменит.',
                  trailing: NcButton.gray(
                    label: 'Ещё раз',
                    onPressed: c.retryTelegramProxy,
                  ),
                ),
            ],
          ),
        ),
        if (state == TelegramProxyState.on) ...[
          const SizedBox(height: NcSpace.gapCards),
          Appear(
            index: i++,
            child: NcSettingsCard(
              children: [
                NcSettingRow(
                  title: 'Подключить в Telegram',
                  description:
                      'Telegram Desktop спросит, включить ли прокси, — нажмите «Включить». '
                      'Это нужно один раз.',
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
                      '«Прокси», тип MTProto, сервер 127.0.0.1, порт $port, секрет — '
                      'из ссылки после «secret=».',
                  trailing: NcButton.gray(
                    label: 'Скопировать',
                    icon: LucideIcons.copy,
                    onPressed: () => _copyLink(c),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: NcSpace.gapCards),
        Appear(
          index: i++,
          child: const NcSettingsCard(
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
          ),
        ),
      ],
    );
  }

  static String _statsLine(AppController c, int port) {
    final s = c.telegramStats;
    final parts = ['Работает на 127.0.0.1:$port'];
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
    if (go) c.openTelegramLink();
  }

  static Future<void> _copyLink(
    AppController c, [
    String message = 'Ссылка скопирована',
  ]) async {
    await Clipboard.setData(ClipboardData(text: c.telegramLink));
    c.toasts.show(ToastData(message, icon: LucideIcons.copy));
  }
}
