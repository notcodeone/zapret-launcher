#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>
#include <shellapi.h>

#include <cstdint>
#include <string>
#include <vector>

// Пункт меню значка в трее.
struct TrayMenuItem {
  int id = 0;
  std::wstring label;
  bool enabled = true;
  bool separator = false;
  // Пункт по умолчанию — выделяется жирным.
  bool is_default = false;
};

// Значок в области уведомлений Windows — без плагинов, на Shell_NotifyIcon.
class TrayIcon {
 public:
  // Сообщение, которое Windows шлёт окну при действиях со значком.
  static constexpr UINT kCallbackMessage = WM_APP + 1;

  // Таймер окна: повторить добавление значка, которое не удалось.
  static constexpr UINT_PTR kRetryTimer = 0x5A4C;

  TrayIcon() = default;
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  void Attach(HWND window) { window_ = window; }

  // Значок из пикселей RGBA (прямая альфа), size × size.
  void SetIcon(const std::vector<uint8_t>& rgba, int size);
  void SetTooltip(const std::wstring& tooltip);
  void SetMenu(std::vector<TrayMenuItem> items) { menu_ = std::move(items); }
  void ShowBalloon(const std::wstring& title, const std::wstring& text);
  void Remove();

  // Проводник перезапустился или впервые запустился — значок надо добавить заново.
  void Readd();

  // Сработал kRetryTimer.
  void Retry();

  // Меню у курсора. Возвращает id выбранного пункта или 0.
  int ShowMenu();

  bool visible() const { return added_; }

 private:
  void Sync();
  void Add(NOTIFYICONDATAW* data);
  void StopRetry();

  HWND window_ = nullptr;
  HICON icon_ = nullptr;
  std::wstring tooltip_;
  std::vector<TrayMenuItem> menu_;
  // Значок есть в трее.
  bool added_ = false;
  // Значок должен быть в трее: Dart его задал и не убирал.
  bool wanted_ = false;
  // Сколько ещё раз повторить добавление; 0 — таймер не запущен.
  int retries_left_ = 0;
};

#endif  // RUNNER_TRAY_ICON_H_
