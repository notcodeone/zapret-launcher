import 'package:flutter/material.dart';

/// Цветовые токены дизайн-системы NotCode.
///
/// В коде цвет всегда берётся отсюда, а не задаётся числом —
/// так светлая и тёмная темы остаются согласованными.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.brightness,
    required this.background,
    required this.card,
    required this.field,
    required this.text,
    required this.muted,
    required this.primary,
    required this.onPrimary,
    required this.success,
    required this.warning,
    required this.info,
    required this.danger,
    required this.dangerSurface,
    required this.divider,
    required this.shadowAlpha,
    required this.cardBorder,
    required this.scrim,
    required this.switchOff,
  });

  final Brightness brightness;

  /// Фон окна.
  final Color background;

  /// Карточки, шапка, меню, диалоги.
  final Color card;

  /// Поля ввода, серые кнопки, метки, подложка сегментов, наведение.
  final Color field;

  /// Основной текст и иконки.
  final Color text;

  /// Пояснения, подписи, неактивное.
  final Color muted;

  /// Главная кнопка, оповещения, включённый переключатель, фокус поля.
  final Color primary;

  /// Текст и иконки на [primary].
  final Color onPrimary;

  /// Работает, доступно, защищено.
  final Color success;

  /// Ждёт решения пользователя, проверяется.
  final Color warning;

  /// Ждёт ответа, идёт процесс.
  final Color info;

  /// Ошибка, тревога, опасное действие.
  final Color danger;

  /// Фон красной строки и опасной кнопки.
  final Color dangerSurface;

  /// Разделители строк, обводка светлых меток.
  final Color divider;

  /// Непрозрачность мягкой тени (вторая её часть — 60 % от этого).
  final double shadowAlpha;

  /// Рамка карточек — только в тёмной теме.
  final Color cardBorder;

  /// Затемнение под меню и диалогами.
  final Color scrim;

  /// Дорожка выключенного переключателя.
  final Color switchOff;

  bool get isDark => brightness == Brightness.dark;

  static const light = Palette(
    brightness: Brightness.light,
    background: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    field: Color(0xFFF3F3F4),
    text: Color(0xFF0A0A0A),
    muted: Color(0xFF6E7179),
    primary: Color(0xFF0A0A0A),
    onPrimary: Color(0xFFFFFFFF),
    success: Color(0xFF12A150),
    warning: Color(0xFFD97706),
    info: Color(0xFF2563EB),
    danger: Color(0xFFD93025),
    dangerSurface: Color(0xFFFDECEA),
    divider: Color(0xFFEAEAEC),
    shadowAlpha: .09,
    cardBorder: Color(0x00000000),
    scrim: Color(0x40000000),
    switchOff: Color(0xFFD9D9DC),
  );

  static const dark = Palette(
    brightness: Brightness.dark,
    background: Color(0xFF0C0C0E),
    card: Color(0xFF17171A),
    field: Color(0xFF232327),
    text: Color(0xFFF4F4F5),
    muted: Color(0xFF9A9CA3),
    primary: Color(0xFFF4F4F5),
    onPrimary: Color(0xFF0A0A0A),
    success: Color(0xFF34C77B),
    warning: Color(0xFFF59E0B),
    info: Color(0xFF60A5FA),
    danger: Color(0xFFFF6B5E),
    dangerSurface: Color(0xFF3A1714),
    divider: Color(0xFF2A2A2F),
    shadowAlpha: .40,
    cardBorder: Color(0xFF27272C),
    scrim: Color(0x99000000),
    switchOff: Color(0xFF3A3A40),
  );

  /// Одна тень на всё — мягкая двойная: широкая размытая и короткая близкая.
  List<BoxShadow> get softShadow => [
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, shadowAlpha),
          blurRadius: 28,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, shadowAlpha * .6),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ];

  /// Тень меню и диалогов.
  List<BoxShadow> get menuShadow => const [
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, .16),
          blurRadius: 32,
          offset: Offset(0, 12),
        ),
      ];

  /// Рамка карточки: в тёмной теме тень не видна, её заменяет тонкая рамка.
  BoxBorder? get cardOutline =>
      isDark ? Border.all(color: cardBorder, width: 1) : null;

  /// Заливка при наведении и нажатии — цветом текста 1,8 % и 3 %.
  Color hoverTint({bool pressed = false}) =>
      text.withValues(alpha: pressed ? .03 : .018);

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return Palette(
      brightness: t < .5 ? brightness : other.brightness,
      background: l(background, other.background),
      card: l(card, other.card),
      field: l(field, other.field),
      text: l(text, other.text),
      muted: l(muted, other.muted),
      primary: l(primary, other.primary),
      onPrimary: l(onPrimary, other.onPrimary),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      info: l(info, other.info),
      danger: l(danger, other.danger),
      dangerSurface: l(dangerSurface, other.dangerSurface),
      divider: l(divider, other.divider),
      shadowAlpha: shadowAlpha + (other.shadowAlpha - shadowAlpha) * t,
      cardBorder: l(cardBorder, other.cardBorder),
      scrim: l(scrim, other.scrim),
      switchOff: l(switchOff, other.switchOff),
    );
  }
}

/// Девять стилей текста на всё приложение. Цвет приходит из темы.
abstract final class NcType {
  static const family = 'Segoe UI Variable Text';
  static const fallback = ['Segoe UI', 'system-ui', 'sans-serif'];

  /// Заголовок страницы — 30 / 1.1 · 700 · −0.8.
  static const pageTitle = TextStyle(
      fontSize: 30, height: 1.1, fontWeight: FontWeight.w700, letterSpacing: -.8);

  /// Раздел — 22 / 1.2 · 700 · −0.3.
  static const section = TextStyle(
      fontSize: 22, height: 1.2, fontWeight: FontWeight.w700, letterSpacing: -.3);

  /// Заголовок диалога, меню — 20 / 1.2 · 700 · −0.3.
  static const dialogTitle = TextStyle(
      fontSize: 20, height: 1.2, fontWeight: FontWeight.w700, letterSpacing: -.3);

  /// Шапка — 16 · 700 · −0.3.
  static const header =
      TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -.3);

  /// Заголовок строки — 15 · 600.
  static const rowTitle = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);

  /// Основной — 14 / 1.35 · 400.
  static const body =
      TextStyle(fontSize: 14, height: 1.35, fontWeight: FontWeight.w400);

  /// Кнопка — 13.5 · 500.
  static const button = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500);

  /// Крупная кнопка — 14.5 · 500.
  static const buttonLarge =
      TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500);

  /// Пояснение, статус — 12.5 / 1.35 · 400 (цвет muted).
  static const caption =
      TextStyle(fontSize: 12.5, height: 1.35, fontWeight: FontWeight.w400);

  /// Подпись поля — 11 · 500 · +0.6, заглавными (цвет muted).
  static const fieldLabel =
      TextStyle(fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: .6);

  /// Метка — 11.5.
  static const tag = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500);

  /// Цифры, которые меняются на месте, не должны прыгать.
  static const tabular = [FontFeature.tabularFigures()];
}

/// Отступы кратны 2; основные шаги — 4, 8, 12, 16, 24.
abstract final class NcSpace {
  static const gutter = 24.0;
  static const cardPad = 16.0;
  static const gapCards = 12.0;
  static const headerHeight = 52.0;
  static const headerTop = 12.0;
  static const footerHeight = 40.0;
  static const fabHeight = 52.0;
  static const fabGap = 8.0;
}

abstract final class NcRadius {
  static const tag = 6.0;
  static const tooltip = 8.0;
  static const segment = 9.0;
  static const control = 12.0;
  static const notice = 14.0;
  static const float = 16.0;
  static const card = 18.0;
  static const dialog = 22.0;
}

/// Анимация показывает, откуда пришло и куда ушло.
abstract final class NcMotion {
  static const pageIn = Duration(milliseconds: 380);
  static const pageOut = Duration(milliseconds: 320);
  static const cardAppear = Duration(milliseconds: 360);
  static const headerStatus = Duration(milliseconds: 280);
  static const toastIn = Duration(milliseconds: 280);
  static const toastOut = Duration(milliseconds: 200);
  static const fabHide = Duration(milliseconds: 260);
  static const hover = Duration(milliseconds: 120);
  static const icon = Duration(milliseconds: 180);
  static const segment = Duration(milliseconds: 200);

  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;

  /// Пользователь с «уменьшить движение» видит смену без перемещения.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

extension PaletteContext on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>()!;
}

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: NcType.family,
    fontFamilyFallback: NcType.fallback,
  );
  return base.copyWith(
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: p.primary,
      onPrimary: p.onPrimary,
      secondary: p.primary,
      onSecondary: p.onPrimary,
      error: p.danger,
      onError: p.onPrimary,
      surface: p.card,
      onSurface: p.text,
    ),
    textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text),
    iconTheme: IconThemeData(color: p.text, size: 20),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    hoverColor: p.field,
    dividerColor: p.divider,
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: p.primary,
        borderRadius: BorderRadius.circular(NcRadius.tooltip),
      ),
      textStyle: TextStyle(
        color: p.onPrimary,
        fontSize: 12,
        fontFamily: NcType.family,
        fontFamilyFallback: NcType.fallback,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.text),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.text,
      selectionColor: p.text.withValues(alpha: .16),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(2),
      thumbColor: WidgetStatePropertyAll(p.muted.withValues(alpha: .4)),
    ),
    extensions: [p],
  );
}
