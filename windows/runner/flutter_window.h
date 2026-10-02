#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "tray_icon.h"
#include "win32_window.h"

// Сообщение «покажись»: его шлёт второй запуск лаунчера первому.
constexpr const wchar_t kShowWindowMessage[] = L"ZapretLauncher.ShowWindow";

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |start_hidden| — не показывать окно при запуске: лаунчер сразу в трее
  // (автозапуск при входе в Windows, параметр --minimized).
  explicit FlutterWindow(const flutter::DartProject& project, bool start_hidden = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Вызовы из Dart по каналу zapret_launcher/window.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void ShowAndFocus();

  // The project to run.
  flutter::DartProject project_;

  bool start_hidden_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  TrayIcon tray_;

  // Закрытие окна решает Dart: спрятать в трей или выйти.
  bool intercept_close_ = false;
  bool force_close_ = false;

  UINT taskbar_created_message_ = 0;
  UINT show_window_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
