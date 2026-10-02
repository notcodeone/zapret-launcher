#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

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

  // Проводник перезапустился — значок надо добавить заново.
  void Readd();

  // Меню у курсора. Возвращает id выбранного пункта или 0.
  int ShowMenu();

  bool visible() const { return added_; }

 private:
  void Sync();

  HWND window_ = nullptr;
  HICON icon_ = nullptr;
  std::wstring tooltip_;
  std::vector<TrayMenuItem> menu_;
  bool added_ = false;
};

#endif  // RUNNER_TRAY_ICON_H_
