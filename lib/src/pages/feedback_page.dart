import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../feedback/feedback.dart';
import '../ui/ui.dart';
import 'common.dart';
import 'settings_page.dart';

/// «Настройки» → «Обратная связь»: ошибка или предложение — на сервер поддержки.
/// Обращение анонимное. Сведения о системе и журнал уходят, только если человек
/// сам отметил это и может посмотреть, что именно отправится. До нажатия
/// «Отправить» лаунчер к серверу не обращается.
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _text = TextEditingController();
  var _kind = FeedbackKind.bug;
  var _attach = false;
  var _preview = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _textOk => _text.text.trim().length >= feedbackTextMin;

  Future<void> _send(AppController c) async {
    setState(() => _error = null);
    try {
      final id = await c.sendFeedback(
        kind: _kind,
        text: _text.text,
        attach: _attach,
      );
      if (!mounted) return;
      _text.clear();
      setState(() => _preview = false);
      c.toasts.show(
        ToastData('Обращение №$id отправлено', icon: LucideIcons.send),
      );
    } on FeedbackException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;
    final sending = c.sendingFeedback;
    final available = c.feedbackAvailable;

    return NcPage(
      header: appHeader(
        context,
        c,
        title: SettingsSection.feedback.title,
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      fab: NcFab(
        icon: LucideIcons.send,
        label: sending ? 'Отправляю…' : 'Отправить',
        onPressed: available && _textOk && !sending ? () => _send(c) : null,
      ),
      children: [
        ...importantRows(context, c),
        const SettingsSectionHeading(section: SettingsSection.feedback),
        const SizedBox(height: 8),
        Appear(
          index: 1,
          child: Text(
            'Обращение анонимное и попадёт прямо к разработчику. Ответить на него '
            'нельзя — если что-то поправим, это будет в описании новой версии.',
            style: NcType.body.copyWith(color: p.muted),
          ),
        ),
        if (!available) ...[
          const SizedBox(height: 16),
          const NoticeRow(
            kind: NoticeKind.info,
            icon: LucideIcons.info,
            title: 'Отправка обращений в этой сборке не настроена',
            detail: 'В выпусках с GitHub она работает.',
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          NoticeRow(
            kind: NoticeKind.danger,
            icon: LucideIcons.circleAlert,
            title: _error!,
            onClose: () => setState(() => _error = null),
          ),
        ],
        const SizedBox(height: 24),
        Appear(
          index: 2,
          child: NcSettingsCard(
            children: [
              NcSettingRow(
                title: 'Что это',
                below: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: NcSegmented<FeedbackKind>(
                    value: _kind,
                    onChanged: sending
                        ? null
                        : (k) => setState(() => _kind = k),
                    segments: const [
                      NcSegment(
                        FeedbackKind.bug,
                        'Ошибка',
                        icon: LucideIcons.bug,
                      ),
                      NcSegment(
                        FeedbackKind.idea,
                        'Предложение',
                        icon: LucideIcons.lightbulb,
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(NcSpace.cardPad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    NcTextField(
                      controller: _text,
                      label: _kind == FeedbackKind.bug
                          ? 'Что случилось'
                          : 'Что предлагаете',
                      hint: _kind == FeedbackKind.bug
                          ? 'Например: после обновления zapret Discord не открывается '
                                'ни с одной стратегией'
                          : 'Например: показывать в трее, какая стратегия включена',
                      minLines: 5,
                      maxLines: 10,
                      maxLength: feedbackTextMax,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Не указывайте имя, почту, телефон и другие личные данные.',
                      style: NcType.caption.copyWith(color: p.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: NcSpace.gapCards),
        Appear(
          index: 3,
          child: NcSettingsCard(
            children: [
              NcSettingRow(
                title: 'Приложить сведения о системе и журнал',
                description:
                    'Версии, стратегия, настройки и последние события лаунчера — '
                    'без адресов, путей, названий сетей и стран. Так проще понять, '
                    'что пошло не так.',
                below: _attach
                    ? Transform.translate(
                        offset: const Offset(-6, 0),
                        child: NcQuietButton(
                          label: _preview
                              ? 'Скрыть, что будет отправлено'
                              : 'Что будет отправлено',
                          onPressed: () => setState(() => _preview = !_preview),
                        ),
                      )
                    : null,
                trailing: NcSwitch(
                  value: _attach,
                  label: 'Приложить сведения о системе и журнал',
                  onChanged: sending
                      ? null
                      : (v) => setState(() {
                          _attach = v;
                          if (!v) _preview = false;
                        }),
                ),
              ),
              if (_attach && _preview)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NcSpace.cardPad,
                    0,
                    NcSpace.cardPad,
                    NcSpace.cardPad,
                  ),
                  child: _Preview(controller: c),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Ровно то, что уйдёт вместе с текстом: сведения о системе и журнал.
class _Preview extends StatelessWidget {
  const _Preview({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final details = controller.feedbackDetails();
    final log = controller.feedbackLog();
    final text = [
      'Сведения о системе:',
      for (final e in details.entries) '${e.key}: ${e.value}',
      if (log.trim().isNotEmpty) ...['', log],
    ].join('\n');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(NcRadius.control),
      ),
      child: SelectableText(
        text,
        style: NcType.caption.copyWith(
          color: p.text,
          fontFamily: 'Consolas',
          height: 1.4,
        ),
      ),
    );
  }
}
