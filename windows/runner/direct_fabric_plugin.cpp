#include "direct_fabric_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "daphq_direct_win.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

std::string EscapeJson(const std::string& input) {
  std::string out;
  out.reserve(input.size() + 8);
  for (unsigned char uc : input) {
    switch (uc) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (uc < 0x20) {
          char hex[8]{};
          std::snprintf(hex, sizeof(hex), "\\u%04x", static_cast<unsigned>(uc));
          out += hex;
        } else {
          out.push_back(static_cast<char>(uc));
        }
        break;
    }
  }
  return out;
}

std::string EncodableMapToJson(const EncodableMap& map) {
  std::ostringstream os;
  os << "{";
  bool first = true;
  for (const auto& kv : map) {
    const auto* key = std::get_if<std::string>(&kv.first);
    if (!key) continue;
    if (!first) os << ",";
    first = false;
    os << "\"" << EscapeJson(*key) << "\":";

    if (const auto* s = std::get_if<std::string>(&kv.second)) {
      os << "\"" << EscapeJson(*s) << "\"";
    } else if (const auto* b = std::get_if<bool>(&kv.second)) {
      os << (*b ? "true" : "false");
    } else if (const auto* i32 = std::get_if<int32_t>(&kv.second)) {
      os << *i32;
    } else if (const auto* i64 = std::get_if<int64_t>(&kv.second)) {
      os << *i64;
    } else if (const auto* d = std::get_if<double>(&kv.second)) {
      os << *d;
    } else {
      os << "null";
    }
  }
  os << "}";
  return os.str();
}

enum class JsonKind {
  kNull,
  kBool,
  kNumber,
  kString,
  kOther,
};

struct JsonFieldValue {
  JsonKind kind = JsonKind::kNull;
  bool bool_val = false;
  double num_val = 0.0;
  int64_t int_val = 0;
  std::string str_val;
};

class JsonParser {
 public:
  explicit JsonParser(const std::string& src) : s_(src), pos_(0) {}

  bool ParseRootObject(std::map<std::string, JsonFieldValue>* out) {
    SkipWs();
    if (pos_ >= s_.size() || s_[pos_] != '{') return false;
    ++pos_;
    SkipWs();
    if (pos_ < s_.size() && s_[pos_] == '}') {
      ++pos_;
      return true;
    }

    while (pos_ < s_.size()) {
      std::string key;
      if (!ParseString(&key)) return false;
      SkipWs();
      if (pos_ >= s_.size() || s_[pos_] != ':') return false;
      ++pos_;

      JsonFieldValue val;
      if (!ParseValue(&val)) return false;
      (*out)[key] = std::move(val);

      SkipWs();
      if (pos_ >= s_.size()) return false;
      if (s_[pos_] == '}') {
        ++pos_;
        return true;
      }
      if (s_[pos_] != ',') return false;
      ++pos_;
    }
    return false;
  }

 private:
  const std::string& s_;
  size_t pos_;

  void SkipWs() {
    while (pos_ < s_.size() &&
           (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\r' ||
            s_[pos_] == '\n')) {
      ++pos_;
    }
  }

  static void AppendCodePointUtf8(uint32_t cp, std::string* out) {
    if (cp <= 0x7F) {
      out->push_back(static_cast<char>(cp));
    } else if (cp <= 0x7FF) {
      out->push_back(static_cast<char>(0xC0 | ((cp >> 6) & 0x1F)));
      out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp <= 0xFFFF) {
      out->push_back(static_cast<char>(0xE0 | ((cp >> 12) & 0x0F)));
      out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
      out->push_back(static_cast<char>(0xF0 | ((cp >> 18) & 0x07)));
      out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
  }

  bool ParseHex4(uint32_t* out_val) {
    if (pos_ + 4 > s_.size()) return false;
    uint32_t v = 0;
    for (int i = 0; i < 4; ++i) {
      char c = s_[pos_++];
      v <<= 4;
      if (c >= '0' && c <= '9') {
        v |= static_cast<uint32_t>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        v |= static_cast<uint32_t>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        v |= static_cast<uint32_t>(c - 'A' + 10);
      } else {
        return false;
      }
    }
    *out_val = v;
    return true;
  }

  bool ParseString(std::string* out) {
    SkipWs();
    if (pos_ >= s_.size() || s_[pos_] != '"') return false;
    ++pos_;
    out->clear();
    while (pos_ < s_.size()) {
      char c = s_[pos_++];
      if (c == '"') return true;
      if (c == '\\') {
        if (pos_ >= s_.size()) return false;
        char esc = s_[pos_++];
        switch (esc) {
          case '"':
          case '\\':
          case '/':
            out->push_back(esc);
            break;
          case 'b':
            out->push_back('\b');
            break;
          case 'f':
            out->push_back('\f');
            break;
          case 'n':
            out->push_back('\n');
            break;
          case 'r':
            out->push_back('\r');
            break;
          case 't':
            out->push_back('\t');
            break;
          case 'u': {
            uint32_t cp = 0;
            if (!ParseHex4(&cp)) return false;
            if (cp >= 0xD800 && cp <= 0xDBFF && pos_ + 2 <= s_.size() &&
                s_[pos_] == '\\' && s_[pos_ + 1] == 'u') {
              pos_ += 2;
              uint32_t low = 0;
              if (!ParseHex4(&low)) return false;
              if (low >= 0xDC00 && low <= 0xDFFF) {
                cp = 0x10000 + (((cp - 0xD800) << 10) | (low - 0xDC00));
              }
            }
            AppendCodePointUtf8(cp, out);
            break;
          }
          default:
            out->push_back(esc);
            break;
        }
      } else {
        out->push_back(c);
      }
    }
    return false;
  }

  bool ParseNumber(JsonFieldValue* out) {
    SkipWs();
    const size_t start = pos_;
    if (pos_ < s_.size() && s_[pos_] == '-') ++pos_;
    if (pos_ >= s_.size() || !std::isdigit(static_cast<unsigned char>(s_[pos_]))) {
      return false;
    }
    while (pos_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[pos_]))) {
      ++pos_;
    }
    bool is_float = false;
    if (pos_ < s_.size() && s_[pos_] == '.') {
      is_float = true;
      ++pos_;
      if (pos_ >= s_.size() || !std::isdigit(static_cast<unsigned char>(s_[pos_]))) {
        return false;
      }
      while (pos_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[pos_]))) {
        ++pos_;
      }
    }
    if (pos_ < s_.size() && (s_[pos_] == 'e' || s_[pos_] == 'E')) {
      is_float = true;
      ++pos_;
      if (pos_ < s_.size() && (s_[pos_] == '+' || s_[pos_] == '-')) ++pos_;
      if (pos_ >= s_.size() || !std::isdigit(static_cast<unsigned char>(s_[pos_]))) {
        return false;
      }
      while (pos_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[pos_]))) {
        ++pos_;
      }
    }

    const std::string token = s_.substr(start, pos_ - start);
    out->kind = JsonKind::kNumber;
    out->num_val = std::strtod(token.c_str(), nullptr);
    out->int_val = is_float ? static_cast<int64_t>(out->num_val)
                            : std::strtoll(token.c_str(), nullptr, 10);
    return true;
  }

  bool SkipCompound(char open_ch, char close_ch) {
    if (pos_ >= s_.size() || s_[pos_] != open_ch) return false;
    ++pos_;
    int depth = 1;
    while (pos_ < s_.size() && depth > 0) {
      char c = s_[pos_++];
      if (c == '"') {
        --pos_;
        std::string scratch;
        if (!ParseString(&scratch)) return false;
      } else if (c == open_ch) {
        ++depth;
      } else if (c == close_ch) {
        --depth;
      }
    }
    return depth == 0;
  }

  bool ParseValue(JsonFieldValue* out) {
    SkipWs();
    if (pos_ >= s_.size()) return false;
    char c = s_[pos_];
    if (c == '"') {
      out->kind = JsonKind::kString;
      return ParseString(&out->str_val);
    }
    if (c == '{') {
      out->kind = JsonKind::kOther;
      return SkipCompound('{', '}');
    }
    if (c == '[') {
      out->kind = JsonKind::kOther;
      return SkipCompound('[', ']');
    }
    if (s_.compare(pos_, 4, "true") == 0) {
      pos_ += 4;
      out->kind = JsonKind::kBool;
      out->bool_val = true;
      return true;
    }
    if (s_.compare(pos_, 5, "false") == 0) {
      pos_ += 5;
      out->kind = JsonKind::kBool;
      out->bool_val = false;
      return true;
    }
    if (s_.compare(pos_, 4, "null") == 0) {
      pos_ += 4;
      out->kind = JsonKind::kNull;
      return true;
    }
    return ParseNumber(out);
  }
};

std::string GetJsonString(
    const std::map<std::string, JsonFieldValue>& obj,
    const char* key) {
  auto it = obj.find(key);
  if (it != obj.end() && it->second.kind == JsonKind::kString) {
    return it->second.str_val;
  }
  return "";
}

int GetJsonInt(
    const std::map<std::string, JsonFieldValue>& obj,
    const char* key,
    int fallback) {
  auto it = obj.find(key);
  if (it != obj.end() && it->second.kind == JsonKind::kNumber) {
    return static_cast<int>(it->second.int_val);
  }
  return fallback;
}

bool GetJsonBool(
    const std::map<std::string, JsonFieldValue>& obj,
    const char* key,
    bool fallback) {
  auto it = obj.find(key);
  if (it != obj.end() && it->second.kind == JsonKind::kBool) {
    return it->second.bool_val;
  }
  return fallback;
}

}  // namespace

struct DirectFabricPlugin::Impl : public std::enable_shared_from_this<Impl> {
  struct CallbackRelay {
    std::mutex mu;
    std::weak_ptr<Impl> impl;
  };

  struct NativeHolder {
    void* handle = nullptr;
    std::unique_ptr<CallbackRelay> relay;

    ~NativeHolder() {
      if (handle) {
        daphq_direct_destroy(handle);
        handle = nullptr;
      }
      relay.reset();
    }
  };

  HWND hwnd = nullptr;
  std::shared_ptr<NativeHolder> native_holder;

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_channel;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> event_channel;
  std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink;

  struct PendingReply {
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
    bool done = false;
  };

  std::mutex state_mutex;
  std::queue<std::function<void()>> ui_tasks;
  std::vector<std::shared_ptr<PendingReply>> pending_replies;
  std::atomic<bool> destroyed{false};

  std::mutex worker_mu;
  std::condition_variable worker_cv;
  int active_workers = 0;

  template <typename Fn>
  void SpawnWorker(Fn&& fn) {
    {
      std::lock_guard<std::mutex> lock(worker_mu);
      if (destroyed.load()) return;
      ++active_workers;
    }
    auto self = shared_from_this();
    std::thread([self, f = std::forward<Fn>(fn)]() mutable {
      struct WorkerGuard {
        std::shared_ptr<Impl> impl;
        ~WorkerGuard() {
          std::lock_guard<std::mutex> lock(impl->worker_mu);
          if (impl->active_workers > 0) {
            --impl->active_workers;
          }
          if (impl->active_workers == 0) {
            impl->worker_cv.notify_all();
          }
        }
      } guard{self};
      f();
    }).detach();
  }

  std::shared_ptr<PendingReply> TrackReply(
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    auto reply = std::make_shared<PendingReply>();
    {
      std::lock_guard<std::mutex> lock(state_mutex);
      if (!destroyed.load()) {
        reply->result = std::move(result);
        pending_replies.push_back(reply);
        return reply;
      }
    }
    if (result) {
      result->Success(EncodableValue());
    }
    return nullptr;
  }

  void CompleteReplySuccess(
      const std::shared_ptr<PendingReply>& reply,
      EncodableValue value) {
    if (!reply) return;
    auto self = shared_from_this();
    PostUiTask([self, reply, value = std::move(value)]() mutable {
      std::unique_ptr<flutter::MethodResult<EncodableValue>> res;
      {
        std::lock_guard<std::mutex> lock(self->state_mutex);
        if (self->destroyed.load() || reply->done || !reply->result) return;
        reply->done = true;
        res = std::move(reply->result);
        auto& vec = self->pending_replies;
        vec.erase(std::remove(vec.begin(), vec.end(), reply), vec.end());
      }
      if (res) {
        res->Success(value);
      }
    });
  }

  std::shared_ptr<NativeHolder> GetNativeHolder() {
    std::lock_guard<std::mutex> lock(state_mutex);
    if (destroyed.load()) return nullptr;
    return native_holder;
  }

  void PostUiTask(std::function<void()> task) {
    HWND target_hwnd = nullptr;
    {
      std::lock_guard<std::mutex> lock(state_mutex);
      if (destroyed.load()) return;
      ui_tasks.push(std::move(task));
      target_hwnd = hwnd;
    }
    if (target_hwnd != nullptr && ::IsWindow(target_hwnd)) {
      ::PostMessage(target_hwnd, WM_DAPHQ_DIRECT_TASK, 0, 0);
    }
  }

  void EmitEvent(const EncodableMap& map) {
    if (destroyed.load()) return;
    auto self = shared_from_this();
    PostUiTask([self, map]() {
      if (self->destroyed.load() || !self->event_sink) return;
      self->event_sink->Success(EncodableValue(map));
    });
  }

  static EncodableMap CapabilitiesToMap(const DaphqRadioCapabilities& caps) {
    EncodableMap map;
    map[EncodableValue("hasWifi")] = EncodableValue(caps.has_wifi != 0);
    map[EncodableValue("hasBle")] = EncodableValue(caps.has_ble != 0);
    map[EncodableValue("canHostDirect5g")] =
        EncodableValue(caps.can_host_direct_5g != 0);
    map[EncodableValue("wifiHardwarePresent")] =
        EncodableValue(caps.wifi_hardware_present != 0);
    map[EncodableValue("bluetoothHardwarePresent")] =
        EncodableValue(caps.bluetooth_hardware_present != 0);
    map[EncodableValue("wifiEnabled")] = EncodableValue(caps.wifi_enabled != 0);
    map[EncodableValue("bluetoothEnabled")] =
        EncodableValue(caps.bluetooth_enabled != 0);
    map[EncodableValue("missingWifiPermission")] = EncodableValue(false);
    map[EncodableValue("missingBlePermission")] = EncodableValue(false);
    map[EncodableValue("locationServiceEnabled")] =
        EncodableValue(caps.location_service_enabled != 0);
    return map;
  }

  static void OnNativeRadioState(DaphqRadioCapabilities caps, void* user_data) {
    auto* relay = static_cast<CallbackRelay*>(user_data);
    if (!relay) return;

    std::shared_ptr<Impl> s;
    {
      std::lock_guard<std::mutex> lock(relay->mu);
      s = relay->impl.lock();
    }
    if (!s || s->destroyed.load()) return;

    EncodableMap map = CapabilitiesToMap(caps);
    map[EncodableValue("type")] = EncodableValue("radioState");
    s->EmitEvent(map);
  }

  static void OnNativeBleBeacon(
      const char* ble_address,
      const char* device_name,
      int rssi,
      const uint8_t* payload,
      int payload_len,
      void* user_data) {
    auto* relay = static_cast<CallbackRelay*>(user_data);
    if (!relay || !ble_address || !payload || payload_len <= 0) return;

    std::shared_ptr<Impl> s;
    {
      std::lock_guard<std::mutex> lock(relay->mu);
      s = relay->impl.lock();
    }
    if (!s || s->destroyed.load()) return;

    EncodableMap map;
    map[EncodableValue("type")] = EncodableValue("bleBeacon");
    map[EncodableValue("address")] = EncodableValue(std::string(ble_address));
    if (device_name && device_name[0] != '\0') {
      map[EncodableValue("name")] = EncodableValue(std::string(device_name));
    }
    map[EncodableValue("rssi")] = EncodableValue(rssi);
    map[EncodableValue("payload")] = EncodableValue(
        std::vector<uint8_t>(payload, payload + payload_len));
    s->EmitEvent(map);
  }

  static void OnNativeGattRequest(const char* json_payload, void* user_data) {
    auto* relay = static_cast<CallbackRelay*>(user_data);
    if (!relay || !json_payload) return;

    std::shared_ptr<Impl> s;
    {
      std::lock_guard<std::mutex> lock(relay->mu);
      s = relay->impl.lock();
    }
    if (!s || s->destroyed.load()) return;

    std::map<std::string, JsonFieldValue> obj;
    JsonParser parser(json_payload);
    if (!parser.ParseRootObject(&obj)) return;

    EncodableMap map;
    map[EncodableValue("type")] = EncodableValue("gattLinkRequest");
    map[EncodableValue("requestId")] =
        EncodableValue(GetJsonString(obj, "requestId"));
    map[EncodableValue("peerId")] =
        EncodableValue(GetJsonString(obj, "peerId"));
    const std::string peer_name = GetJsonString(obj, "peerName");
    map[EncodableValue("peerName")] =
        EncodableValue(peer_name.empty() ? std::string("Unknown Device") : peer_name);

    const std::string fp = GetJsonString(obj, "peerFingerprint");
    if (!fp.empty()) {
      map[EncodableValue("peerFingerprint")] = EncodableValue(fp);
    }
    map[EncodableValue("action")] =
        EncodableValue(GetJsonString(obj, "action"));

    const std::string ssid = GetJsonString(obj, "ssid");
    if (!ssid.empty()) {
      map[EncodableValue("ssid")] = EncodableValue(ssid);
    }
    const std::string psk = GetJsonString(obj, "psk");
    if (!psk.empty()) {
      map[EncodableValue("psk")] = EncodableValue(psk);
    }
    const std::string host_ip = GetJsonString(obj, "hostIp");
    if (!host_ip.empty()) {
      map[EncodableValue("hostIp")] = EncodableValue(host_ip);
    }
    map[EncodableValue("port")] =
        EncodableValue(GetJsonInt(obj, "port", 62004));
    map[EncodableValue("reverseConnect")] =
        EncodableValue(GetJsonBool(obj, "reverseConnect", false));
    const int freq = GetJsonInt(obj, "frequencyMhz", 0);
    if (freq > 0) {
      map[EncodableValue("frequencyMhz")] = EncodableValue(freq);
    }
    const std::string rev_token = GetJsonString(obj, "reverseToken");
    if (!rev_token.empty()) {
      map[EncodableValue("reverseToken")] = EncodableValue(rev_token);
    }
    s->EmitEvent(map);
  }
};

DirectFabricPlugin::DirectFabricPlugin(
    flutter::BinaryMessenger* messenger,
    HWND hwnd)
    : impl_(std::make_shared<Impl>()) {
  impl_->hwnd = hwnd;

  auto holder = std::make_shared<Impl::NativeHolder>();
  holder->relay = std::make_unique<Impl::CallbackRelay>();
  holder->relay->impl = impl_;
  holder->handle = daphq_direct_create(
      &Impl::OnNativeBleBeacon,
      &Impl::OnNativeGattRequest,
      holder->relay.get());
  impl_->native_holder = holder;
  impl_->SpawnWorker([s = impl_, holder]() {
    if (!s->destroyed.load() && holder->handle) {
      daphq_direct_set_radio_callback(holder->handle, &Impl::OnNativeRadioState);
    }
  });

  impl_->method_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger,
      "com.omarafifi.daphq/direct_fabric",
      &flutter::StandardMethodCodec::GetInstance());

  impl_->event_channel = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger,
      "com.omarafifi.daphq/direct_fabric/events",
      &flutter::StandardMethodCodec::GetInstance());

  auto weak_impl = std::weak_ptr<Impl>(impl_);

  auto stream_handler = std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [weak_impl](
          const EncodableValue* /*arguments*/,
          std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        if (auto s = weak_impl.lock()) {
          if (!s->destroyed.load()) {
            s->event_sink = std::move(events);
          }
        }
        return nullptr;
      },
      [weak_impl](const EncodableValue* /*arguments*/)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        if (auto s = weak_impl.lock()) {
          s->event_sink.reset();
        }
        return nullptr;
      });

  impl_->event_channel->SetStreamHandler(std::move(stream_handler));

  impl_->method_channel->SetMethodCallHandler(
      [weak_impl](
          const flutter::MethodCall<EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        auto s = weak_impl.lock();
        if (!s || s->destroyed.load()) {
          result->Success(EncodableValue());
          return;
        }
        auto holder = s->GetNativeHolder();
        if (!holder || !holder->handle) {
          result->Success(EncodableValue());
          return;
        }

        const std::string& method = call.method_name();

        if (method == "getCapabilities") {
          auto reply = s->TrackReply(std::move(result));
          if (!reply) return;
          s->SpawnWorker([s, holder, reply]() {
            if (s->destroyed.load()) return;
            const DaphqRadioCapabilities caps =
                daphq_direct_get_capabilities(holder->handle);
            EncodableMap out = Impl::CapabilitiesToMap(caps);
            s->CompleteReplySuccess(reply, EncodableValue(std::move(out)));
          });
          return;
        }

        if (method == "startBleDiscovery") {
          const auto* args = std::get_if<EncodableMap>(call.arguments());
          if (!args) {
            result->Success(EncodableValue(false));
            return;
          }

          int mfg_id = 0x4451;
          std::vector<uint8_t> payload;
          std::string peer_id;
          std::string peer_name = "Windows PC";
          std::string fp;

          auto mfg_it = args->find(EncodableValue("manufacturerId"));
          if (mfg_it != args->end()) {
            if (const auto* v = std::get_if<int32_t>(&mfg_it->second)) mfg_id = *v;
          }
          auto pay_it = args->find(EncodableValue("beaconPayload"));
          if (pay_it != args->end()) {
            if (const auto* bytes = std::get_if<std::vector<uint8_t>>(&pay_it->second)) {
              payload = *bytes;
            }
          }
          auto pid_it = args->find(EncodableValue("peerId"));
          if (pid_it != args->end()) {
            if (const auto* str = std::get_if<std::string>(&pid_it->second)) peer_id = *str;
          }
          auto pname_it = args->find(EncodableValue("peerName"));
          if (pname_it != args->end()) {
            if (const auto* str = std::get_if<std::string>(&pname_it->second)) peer_name = *str;
          }
          auto fp_it = args->find(EncodableValue("fingerprint"));
          if (fp_it != args->end()) {
            if (const auto* str = std::get_if<std::string>(&fp_it->second)) fp = *str;
          }

          int effective_port = 62004;
          if (payload.size() == 22) {
            const int decoded_port = (static_cast<int>(payload[18]) << 8) |
                                     static_cast<int>(payload[19]);
            if (decoded_port > 0 && decoded_port <= 65535) {
              effective_port = decoded_port;
            }
          }

          EncodableMap info_map;
          info_map[EncodableValue("peerId")] = EncodableValue(peer_id);
          info_map[EncodableValue("name")] = EncodableValue(peer_name);
          info_map[EncodableValue("fp")] = EncodableValue(fp);
          info_map[EncodableValue("port")] = EncodableValue(effective_port);
          info_map[EncodableValue("platform")] = EncodableValue("windows");
          const std::string info_json = EncodableMapToJson(info_map);

          auto reply = s->TrackReply(std::move(result));
          if (!reply) return;
          s->SpawnWorker([s, holder, reply, mfg_id, payload, info_json]() {
            if (s->destroyed.load()) return;
            int ok = 0;
            if (payload.size() == 22) {
              ok = daphq_direct_start_ble_discovery(
                  holder->handle,
                  static_cast<uint16_t>(mfg_id),
                  payload.data(),
                  static_cast<int>(payload.size()),
                  info_json.c_str());
            }
            s->CompleteReplySuccess(reply, EncodableValue(ok != 0));
          });
          return;
        }

        if (method == "stopBleDiscovery") {
          auto reply = s->TrackReply(std::move(result));
          if (!reply) return;
          s->SpawnWorker([s, holder, reply]() {
            if (!s->destroyed.load()) {
              daphq_direct_stop_ble_discovery(holder->handle);
            }
            s->CompleteReplySuccess(reply, EncodableValue());
          });
          return;
        }

        if (method == "startDirectHost") {
          bool prefer_5g = true;
          std::string stable_tag;
          if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
            auto it = args->find(EncodableValue("prefer5Ghz"));
            if (it != args->end()) {
              if (const auto* b = std::get_if<bool>(&it->second)) prefer_5g = *b;
            }
            auto tag_it = args->find(EncodableValue("stableTag"));
            if (tag_it != args->end()) {
              if (const auto* t = std::get_if<std::string>(&tag_it->second)) {
                stable_tag = *t;
              }
            }
          }
          auto reply = s->TrackReply(std::move(result));
          if (!reply) return;
          s->SpawnWorker([s, holder, reply, prefer_5g, stable_tag]() {
            if (s->destroyed.load()) return;
            const DaphqDirectHostInfo info = daphq_direct_start_host(
                holder->handle,
                prefer_5g ? 1 : 0,
                stable_tag.empty() ? nullptr : stable_tag.c_str());
            if (!info.success) {
              s->CompleteReplySuccess(reply, EncodableValue());
              return;
            }
            EncodableMap out;
            out[EncodableValue("ssid")] = EncodableValue(std::string(info.ssid));
            out[EncodableValue("psk")] = EncodableValue(std::string(info.psk));
            out[EncodableValue("hostIp")] = EncodableValue(std::string(info.host_ip));
            out[EncodableValue("frequencyMhz")] = EncodableValue(info.frequency_mhz);
            s->CompleteReplySuccess(reply, EncodableValue(std::move(out)));
          });
          return;
        }

        if (method == "connectDirectClient") {
          const auto* args = std::get_if<EncodableMap>(call.arguments());
          if (!args) {
            result->Success(EncodableValue());
            return;
          }
          std::string ssid;
          std::string psk;
          std::string expected_gw;
          auto sit = args->find(EncodableValue("ssid"));
          if (sit != args->end()) {
            if (const auto* v = std::get_if<std::string>(&sit->second)) ssid = *v;
          }
          auto pit = args->find(EncodableValue("psk"));
          if (pit != args->end()) {
            if (const auto* v = std::get_if<std::string>(&pit->second)) psk = *v;
          }
          auto git = args->find(EncodableValue("expectedGatewayIp"));
          if (git != args->end()) {
            if (const auto* v = std::get_if<std::string>(&git->second)) expected_gw = *v;
          }

          auto reply = s->TrackReply(std::move(result));
          if (!reply) return;
          s->SpawnWorker([s, holder, reply, ssid, psk, expected_gw]() {
            if (s->destroyed.load()) return;
            const DaphqDirectClientConn conn = daphq_direct_connect_client(
                holder->handle,
                ssid.c_str(),
                psk.c_str(),
                expected_gw.c_str());
            if (!conn.success) {
              s->CompleteReplySuccess(reply, EncodableValue());
              return;
            }
            EncodableMap out;
            out[EncodableValue("localIp")] = EncodableValue(std::string(conn.local_ip));
            out[EncodableValue("gatewayIp")] = EncodableValue(std::string(conn.gateway_ip));
            if (conn.frequency_mhz > 0) {
              out[EncodableValue("frequencyMhz")] = EncodableValue(conn.frequency_mhz);
            }
            s->CompleteReplySuccess(reply, EncodableValue(std::move(out)));
          });
          return;
        }

        if (method == "exchangeGattLink") {
          const auto* args = std::get_if<EncodableMap>(call.arguments());
          if (!args) {
            result->Success(EncodableValue());
            return;
          }
          std::string ble_addr;
          std::string req_json = "{}";
          auto ait = args->find(EncodableValue("bleAddress"));
          if (ait != args->end()) {
            if (const auto* v = std::get_if<std::string>(&ait->second)) ble_addr = *v;
          }
          auto pit = args->find(EncodableValue("payload"));
          if (pit != args->end()) {
            if (const auto* pm = std::get_if<EncodableMap>(&pit->second)) {
              req_json = EncodableMapToJson(*pm);
            }
          }

          auto reply = s->TrackReply(std::move(result));
          if (!reply) return;
          s->SpawnWorker([s, holder, reply, ble_addr, req_json]() {
            if (s->destroyed.load()) return;
            std::vector<char> resp_buf(4096, '\0');
            const int ok = daphq_direct_exchange_gatt_link(
                holder->handle,
                ble_addr.c_str(),
                req_json.c_str(),
                resp_buf.data(),
                static_cast<int>(resp_buf.size()));
            if (!ok) {
              s->CompleteReplySuccess(reply, EncodableValue());
              return;
            }
            const std::string resp(resp_buf.data());
            std::map<std::string, JsonFieldValue> obj;
            JsonParser parser(resp);
            const bool parsed = parser.ParseRootObject(&obj);

            EncodableMap out;
            out[EncodableValue("ok")] = EncodableValue(true);
            if (parsed) {
              const std::string peer_id = GetJsonString(obj, "peerId");
              const std::string name = GetJsonString(obj, "name");
              const std::string fp = GetJsonString(obj, "fp");
              const std::string plat = GetJsonString(obj, "platform");
              if (!peer_id.empty()) out[EncodableValue("peerId")] = EncodableValue(peer_id);
              if (!name.empty()) out[EncodableValue("name")] = EncodableValue(name);
              if (!fp.empty()) out[EncodableValue("fp")] = EncodableValue(fp);
              if (!plat.empty()) out[EncodableValue("platform")] = EncodableValue(plat);
              out[EncodableValue("port")] =
                  EncodableValue(GetJsonInt(obj, "port", 62004));
            }
            s->CompleteReplySuccess(reply, EncodableValue(std::move(out)));
          });
          return;
        }

        if (method == "stopDirectSession") {
          auto reply = s->TrackReply(std::move(result));
          if (!reply) return;
          s->SpawnWorker([s, holder, reply]() {
            if (!s->destroyed.load()) {
              daphq_direct_stop_session(holder->handle);
            }
            s->CompleteReplySuccess(reply, EncodableValue());
          });
          return;
        }

        if (method == "getDirectHostClients") {
          auto reply = s->TrackReply(std::move(result));
          if (!reply) return;
          s->SpawnWorker([s, holder, reply]() {
            EncodableList list;
            if (!s->destroyed.load()) {
              char csv_buf[1024]{};
              const int count = daphq_direct_get_host_client_ips(
                  holder->handle, csv_buf, sizeof(csv_buf));
              if (count > 0 && csv_buf[0] != '\0') {
                std::string csv(csv_buf);
                size_t start = 0;
                while (start < csv.size()) {
                  const size_t comma = csv.find(',', start);
                  const std::string item = comma == std::string::npos
                      ? csv.substr(start)
                      : csv.substr(start, comma - start);
                  if (!item.empty()) {
                    list.push_back(EncodableValue(item));
                  }
                  if (comma == std::string::npos) break;
                  start = comma + 1;
                }
              }
            }
            s->CompleteReplySuccess(reply, EncodableValue(std::move(list)));
          });
          return;
        }

        if (method == "setTransferPowerLock") {
          bool enabled = false;
          if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
            auto it = args->find(EncodableValue("enabled"));
            if (it != args->end()) {
              if (const auto* b = std::get_if<bool>(&it->second)) enabled = *b;
            }
          }
          auto reply = s->TrackReply(std::move(result));
          if (!reply) return;
          s->SpawnWorker([s, holder, reply, enabled]() {
            if (!s->destroyed.load()) {
              daphq_direct_set_transfer_power_lock(
                  holder->handle, enabled ? 1 : 0);
            }
            s->CompleteReplySuccess(reply, EncodableValue());
          });
          return;
        }

        result->NotImplemented();
      });
}

DirectFabricPlugin::~DirectFabricPlugin() {
  Shutdown();
}

void DirectFabricPlugin::DrainPendingTasks() {
  std::queue<std::function<void()>> local;
  {
    std::lock_guard<std::mutex> lock(impl_->state_mutex);
    if (impl_->destroyed.load()) return;
    std::swap(local, impl_->ui_tasks);
  }
  while (!local.empty()) {
    auto fn = std::move(local.front());
    local.pop();
    if (fn) fn();
  }
}

void DirectFabricPlugin::Shutdown() {
  std::shared_ptr<Impl::NativeHolder> holder;
  std::vector<std::shared_ptr<Impl::PendingReply>> replies;
  {
    std::lock_guard<std::mutex> lock(impl_->state_mutex);
    if (impl_->destroyed.load()) return;
    impl_->destroyed.store(true);
    impl_->hwnd = nullptr;
    while (!impl_->ui_tasks.empty()) impl_->ui_tasks.pop();
    holder = std::move(impl_->native_holder);
    replies.swap(impl_->pending_replies);
  }
  for (auto& reply : replies) {
    if (reply && !reply->done && reply->result) {
      reply->done = true;
      auto res = std::move(reply->result);
      res->Success(EncodableValue());
    }
  }
  if (holder && holder->relay) {
    std::lock_guard<std::mutex> rlock(holder->relay->mu);
    holder->relay->impl.reset();
  }
  if (holder && holder->handle) {
    daphq_direct_request_abort(holder->handle);
  }
  if (impl_->method_channel) {
    impl_->method_channel->SetMethodCallHandler(nullptr);
    impl_->method_channel.reset();
  }
  if (impl_->event_channel) {
    impl_->event_channel->SetStreamHandler(nullptr);
    impl_->event_channel.reset();
  }
  impl_->event_sink.reset();

  // Wait briefly for in-flight native workers (already aborted) before tearing down WinRT handles.
  {
    std::unique_lock<std::mutex> wlock(impl_->worker_mu);
    impl_->worker_cv.wait_for(
        wlock,
        std::chrono::seconds(4),
        [&]() { return impl_->active_workers == 0; });
  }

  // Release holder on an MTA worker thread so WinRT COM teardown never runs on STA UI thread.
  if (holder) {
    std::thread([h = std::move(holder)]() mutable {
      h.reset();
    }).join();
  }
}
