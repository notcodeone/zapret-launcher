#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                                    nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
  return out;
}

const EncodableValue* Field(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::wstring StringField(const EncodableMap& map, const char* key) {
  const auto* v = Field(map, key);
  if (v && std::holds_alternative<std::string>(*v)) {
    return Utf8ToWide(std::get<std::string>(*v));
  }
  return std::wstring();
}

bool BoolField(const EncodableMap& map, const char* key, bool fallback) {
  const auto* v = Field(map, key);
  return v && std::holds_alternative<bool>(*v) ? std::get<bool>(*v) : fallback;
}

int IntField(const EncodableMap& map, const char* key) {
  const auto* v = Field(map, key);
  if (!v) return 0;
  if (std::holds_alternative<int32_t>(*v)) return std::get<int32_t>(*v);
  if (std::holds_alternative<int64_t>(*v)) return static_cast<int>(std::get<int64_t>(*v));
  return 0;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      flutter_controller_->engine()->messenger(), "zapret_launcher/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  HWND hwnd = GetHandle();
  tray_.Attach(hwnd);
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  show_window_message_ = RegisterWindowMessageW(kShowWindowMessage);
  // Окно с правами администратора не получает сообщения от обычных процессов,
  // пока их явно не разрешить: Проводник после перезапуска и второй запуск лаунчера.
  ChangeWindowMessageFilterEx(hwnd, taskbar_created_message_, MSGFLT_ALLOW, nullptr);
  ChangeWindowMessageFilterEx(hwnd, show_window_message_, MSGFLT_ALLOW, nullptr);

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Запуск свёрнутым: окно остаётся скрытым, лаунчер — в трее.
    if (!start_hidden_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  tray_.Remove();
  channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ShowAndFocus() {
  HWND hwnd = GetHandle();
  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  HWND hwnd = GetHandle();

  if (method == "show") {
    ShowAndFocus();
  } else if (method == "hide") {
    ShowWindow(hwnd, SW_HIDE);
  } else if (method == "quit") {
    // Закрываем через очередь сообщений: уничтожать движок изнутри его же вызова нельзя.
    force_close_ = true;
    PostMessage(hwnd, WM_CLOSE, 0, 0);
  } else if (method == "isVisible") {
    result->Success(EncodableValue(IsWindowVisible(hwnd) != FALSE));
    return;
  } else if (method == "setInterceptClose") {
    const auto* v = std::get_if<bool>(call.arguments());
    intercept_close_ = v && *v;
  } else if (method == "trayIconSize") {
    const int size = GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForWindow(hwnd));
    result->Success(EncodableValue(size));
    return;
  } else if (method == "setTray" && args) {
    const auto* icon = Field(*args, "icon");
    if (icon && std::holds_alternative<std::vector<uint8_t>>(*icon)) {
      tray_.SetIcon(std::get<std::vector<uint8_t>>(*icon), IntField(*args, "size"));
    }
    tray_.SetTooltip(StringField(*args, "tooltip"));
  } else if (method == "setTrayMenu") {
    std::vector<TrayMenuItem> items;
    if (const auto* list = std::get_if<EncodableList>(call.arguments())) {
      for (const auto& value : *list) {
        const auto* map = std::get_if<EncodableMap>(&value);
        if (!map) continue;
        TrayMenuItem item;
        item.id = IntField(*map, "id");
        item.label = StringField(*map, "label");
        item.enabled = BoolField(*map, "enabled", true);
        item.separator = BoolField(*map, "separator", false);
        item.is_default = BoolField(*map, "default", false);
        items.push_back(std::move(item));
      }
    }
    tray_.SetMenu(std::move(items));
  } else if (method == "removeTray") {
    tray_.Remove();
  } else if (method == "balloon" && args) {
    tray_.ShowBalloon(StringField(*args, "title"), StringField(*args, "text"));
  } else {
    result->NotImplemented();
    return;
  }
  result->Success();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (message == TrayIcon::kCallbackMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
        ShowAndFocus();
        break;
      case WM_RBUTTONUP: {
        const int id = tray_.ShowMenu();
        if (id != 0 && channel_) {
          channel_->InvokeMethod("trayMenu", std::make_unique<EncodableValue>(id));
        }
        break;
      }
    }
    return 0;
  }
  if (show_window_message_ != 0 && message == show_window_message_) {
    ShowAndFocus();
    return 0;
  }
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_.Readd();
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_GETMINMAXINFO: {
      // Окно — одна колонка: уже 480 и ниже 560 pt интерфейс не помещается.
      const double scale = GetDpiForWindow(hwnd) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(480 * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(560 * scale);
      return 0;
    }
    case WM_CLOSE:
      // Крестик: решает Dart — спрятать в трей или выйти, завершив начатое.
      if (intercept_close_ && !force_close_ && channel_) {
        channel_->InvokeMethod("closeRequested", nullptr);
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
