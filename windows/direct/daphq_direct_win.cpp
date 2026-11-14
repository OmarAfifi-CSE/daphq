#include "daphq_direct_win.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <objbase.h>
#include <iphlpapi.h>
#include <wlanapi.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Devices.WiFiDirect.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.NetworkOperators.h>
#include <winrt/Windows.Security.Credentials.h>
#include <winrt/Windows.Storage.Streams.h>

namespace {

using namespace winrt;
using namespace winrt::Windows::Devices::Bluetooth;
using namespace winrt::Windows::Devices::Bluetooth::Advertisement;
using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace winrt::Windows::Devices::Radios;
using namespace winrt::Windows::Devices::WiFiDirect;
using namespace winrt::Windows::Networking::Connectivity;
using namespace winrt::Windows::Networking::NetworkOperators;
using namespace winrt::Windows::Security::Credentials;
using namespace winrt::Windows::Storage::Streams;

// Shared UUIDs matching Android DirectFabricHandler.kt:
// d4f90001-5b2e-4f13-9c12-446170687100
constexpr winrt::guid kServiceUuid{
    0xd4f90001, 0x5b2e, 0x4f13, {0x9c, 0x12, 0x44, 0x61, 0x70, 0x68, 0x71, 0x00}};
constexpr winrt::guid kCharInfoUuid{
    0xd4f90002, 0x5b2e, 0x4f13, {0x9c, 0x12, 0x44, 0x61, 0x70, 0x68, 0x71, 0x00}};
constexpr winrt::guid kCharLinkUuid{
    0xd4f90003, 0x5b2e, 0x4f13, {0x9c, 0x12, 0x44, 0x61, 0x70, 0x68, 0x71, 0x00}};

struct ComMtaScope {
  HRESULT hr;
  ComMtaScope() { hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED); }
  ~ComMtaScope() {
    if (SUCCEEDED(hr)) {
      ::CoUninitialize();
    }
  }
};

struct DeferralGuard {
  winrt::Windows::Foundation::Deferral deferral{nullptr};
  explicit DeferralGuard(winrt::Windows::Foundation::Deferral d)
      : deferral(std::move(d)) {}
  ~DeferralGuard() {
    try {
      if (deferral) deferral.Complete();
    } catch (...) {}
  }
};

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return L"";
  int len = ::MultiByteToWideChar(
      CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
  if (len <= 0) return L"";
  std::wstring out(static_cast<size_t>(len), L'\0');
  ::MultiByteToWideChar(
      CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), out.data(), len);
  return out;
}

std::string FormatBleAddress(uint64_t addr) {
  char buf[24]{};
  std::snprintf(
      buf,
      sizeof(buf),
      "%02X:%02X:%02X:%02X:%02X:%02X",
      static_cast<unsigned>((addr >> 40) & 0xFF),
      static_cast<unsigned>((addr >> 32) & 0xFF),
      static_cast<unsigned>((addr >> 24) & 0xFF),
      static_cast<unsigned>((addr >> 16) & 0xFF),
      static_cast<unsigned>((addr >> 8) & 0xFF),
      static_cast<unsigned>(addr & 0xFF));
  return std::string(buf);
}

bool ParseBleAddress(const char* text, uint64_t* out_addr) {
  if (!text || !out_addr) return false;
  unsigned b[6]{};
  if (sscanf_s(
          text,
          "%2x:%2x:%2x:%2x:%2x:%2x",
          &b[0],
          &b[1],
          &b[2],
          &b[3],
          &b[4],
          &b[5]) == 6) {
    uint64_t v = 0;
    for (int i = 0; i < 6; ++i) {
      v = (v << 8) | (static_cast<uint64_t>(b[i]) & 0xFF);
    }
    *out_addr = v;
    return true;
  }
  return false;
}

std::string XmlEscape(const std::string& input) {
  std::string out;
  out.reserve(input.size() + 8);
  for (char c : input) {
    switch (c) {
      case '&':
        out += "&amp;";
        break;
      case '<':
        out += "&lt;";
        break;
      case '>':
        out += "&gt;";
        break;
      case '"':
        out += "&quot;";
        break;
      case '\'':
        out += "&apos;";
        break;
      default:
        out += c;
        break;
    }
  }
  return out;
}

std::wstring BuildWpa2ProfileXml(const std::string& ssid, const std::string& psk) {
  const std::string escaped_ssid = XmlEscape(ssid);
  const std::string escaped_psk = XmlEscape(psk);
  std::ostringstream hex_ssid;
  for (unsigned char c : ssid) {
    char h[3]{};
    std::snprintf(h, sizeof(h), "%02X", c);
    hex_ssid << h;
  }

  std::ostringstream xml;
  xml << "<?xml version=\"1.0\"?>\n"
      << "<WLANProfile xmlns=\"http://www.microsoft.com/networking/WLAN/profile/v1\">\n"
      << "  <name>" << escaped_ssid << "</name>\n"
      << "  <SSIDConfig>\n"
      << "    <SSID>\n"
      << "      <hex>" << hex_ssid.str() << "</hex>\n"
      << "      <name>" << escaped_ssid << "</name>\n"
      << "    </SSID>\n"
      << "  </SSIDConfig>\n"
      << "  <connectionType>ESS</connectionType>\n"
      << "  <connectionMode>manual</connectionMode>\n"
      << "  <MSM>\n"
      << "    <security>\n"
      << "      <authEncryption>\n"
      << "        <authentication>WPA2PSK</authentication>\n"
      << "        <encryption>AES</encryption>\n"
      << "        <useOneX>false</useOneX>\n"
      << "      </authEncryption>\n"
      << "      <sharedKey>\n"
      << "        <keyType>passPhrase</keyType>\n"
      << "        <protected>false</protected>\n"
      << "        <keyMaterial>" << escaped_psk << "</keyMaterial>\n"
      << "      </sharedKey>\n"
      << "    </security>\n"
      << "  </MSM>\n"
      << "</WLANProfile>";
  return Utf8ToWide(xml.str());
}

std::string RandomString(const char* alphabet, size_t len) {
  const size_t alpha_len = std::strlen(alphabet);
  if (alpha_len == 0 || len == 0) return "";
  std::vector<uint8_t> rnd(len * 2);
  ::BCryptGenRandom(
      nullptr,
      rnd.data(),
      static_cast<ULONG>(rnd.size()),
      BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  std::string out;
  out.reserve(len);
  const size_t limit = (256 / alpha_len) * alpha_len;
  size_t idx = 0;
  while (out.size() < len) {
    if (idx >= rnd.size()) {
      ::BCryptGenRandom(
          nullptr,
          rnd.data(),
          static_cast<ULONG>(rnd.size()),
          BCRYPT_USE_SYSTEM_PREFERRED_RNG);
      idx = 0;
    }
    const uint8_t b = rnd[idx++];
    if (b < limit) {
      out.push_back(alphabet[b % alpha_len]);
    }
  }
  return out;
}

bool QueryWifiInterfaceAddresses(
    const GUID* target_guid,
    std::string* out_local_ip,
    std::string* out_gateway_ip) {
  ULONG buf_len = 16 * 1024;
  std::vector<uint8_t> buffer(buf_len);
  auto* addrs = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  ULONG ret = ::GetAdaptersAddresses(
      AF_INET,
      GAA_FLAG_INCLUDE_GATEWAYS,
      nullptr,
      addrs,
      &buf_len);
  if (ret == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(buf_len);
    addrs = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    ret = ::GetAdaptersAddresses(
        AF_INET,
        GAA_FLAG_INCLUDE_GATEWAYS,
        nullptr,
        addrs,
        &buf_len);
  }
  if (ret != NO_ERROR) return false;

  for (auto* a = addrs; a != nullptr; a = a->Next) {
    if (a->OperStatus != IfOperStatusUp) continue;
    if (a->IfType != IF_TYPE_IEEE80211) continue;

    if (target_guid != nullptr) {
      if (a->AdapterName == nullptr) continue;
      std::wstring wname = Utf8ToWide(std::string(a->AdapterName));
      GUID parsed{};
      if (FAILED(::CLSIDFromString(wname.c_str(), &parsed)) ||
          std::memcmp(&parsed, target_guid, sizeof(GUID)) != 0) {
        continue;
      }
    }

    for (auto* uc = a->FirstUnicastAddress; uc != nullptr; uc = uc->Next) {
      if (uc->Address.lpSockaddr && uc->Address.lpSockaddr->sa_family == AF_INET) {
        auto* sin = reinterpret_cast<sockaddr_in*>(uc->Address.lpSockaddr);
        char ip_buf[INET_ADDRSTRLEN]{};
        ::inet_ntop(AF_INET, &sin->sin_addr, ip_buf, sizeof(ip_buf));
        std::string ip(ip_buf);
        if (ip.rfind("169.254.", 0) == 0 || ip == "0.0.0.0") continue;
        *out_local_ip = ip;

        if (a->FirstGatewayAddress && a->FirstGatewayAddress->Address.lpSockaddr &&
            a->FirstGatewayAddress->Address.lpSockaddr->sa_family == AF_INET) {
          auto* gw =
              reinterpret_cast<sockaddr_in*>(a->FirstGatewayAddress->Address.lpSockaddr);
          char gw_buf[INET_ADDRSTRLEN]{};
          ::inet_ntop(AF_INET, &gw->sin_addr, gw_buf, sizeof(gw_buf));
          std::string gw_ip(gw_buf);
          if (!gw_ip.empty() && gw_ip != "0.0.0.0") {
            *out_gateway_ip = gw_ip;
          }
        }
        return true;
      }
    }
  }
  return false;
}

std::string FindSoftApHostIp() {
  ULONG buf_len = 16 * 1024;
  std::vector<uint8_t> buffer(buf_len);
  auto* addrs = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  ULONG ret = ::GetAdaptersAddresses(AF_INET, 0, nullptr, addrs, &buf_len);
  if (ret == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(buf_len);
    addrs = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    ret = ::GetAdaptersAddresses(AF_INET, 0, nullptr, addrs, &buf_len);
  }
  if (ret != NO_ERROR) return "";

  std::string tethering_137_candidate;
  for (auto* a = addrs; a != nullptr; a = a->Next) {
    if (a->OperStatus != IfOperStatusUp || a->IfType != IF_TYPE_IEEE80211) continue;
    std::wstring desc = a->Description ? a->Description : L"";
    std::wstring friendly = a->FriendlyName ? a->FriendlyName : L"";
    const bool is_virtual =
        desc.find(L"Wi-Fi Direct") != std::wstring::npos ||
        desc.find(L"Direct Virtual") != std::wstring::npos ||
        friendly.find(L"Local Area Connection*") != std::wstring::npos;

    for (auto* uc = a->FirstUnicastAddress; uc != nullptr; uc = uc->Next) {
      if (uc->Address.lpSockaddr && uc->Address.lpSockaddr->sa_family == AF_INET) {
        auto* sin = reinterpret_cast<sockaddr_in*>(uc->Address.lpSockaddr);
        char ip_buf[INET_ADDRSTRLEN]{};
        ::inet_ntop(AF_INET, &sin->sin_addr, ip_buf, sizeof(ip_buf));
        std::string ip(ip_buf);
        if (ip.rfind("169.254.", 0) == 0 || ip == "0.0.0.0") continue;
        if (is_virtual) {
          return ip;
        }
        if (ip.rfind("192.168.137.", 0) == 0 && tethering_137_candidate.empty()) {
          tethering_137_candidate = ip;
        }
      }
    }
  }
  return tethering_137_candidate;
}

bool SelectBestWlanInterface(
    HANDLE wlan,
    GUID* out_guid,
    bool* out_supports_5g) {
  PWLAN_INTERFACE_INFO_LIST iface_list = nullptr;
  if (::WlanEnumInterfaces(wlan, nullptr, &iface_list) != ERROR_SUCCESS ||
      !iface_list) {
    return false;
  }

  bool found = false;
  int best_score = -1;
  GUID best_guid{};

  for (DWORD i = 0; i < iface_list->dwNumberOfItems; ++i) {
    const auto& info = iface_list->InterfaceInfo[i];
    if (info.isState == wlan_interface_state_not_ready) continue;
    int score = (info.isState == wlan_interface_state_connected) ? 3 : 2;
    if (score > best_score) {
      best_score = score;
      best_guid = info.InterfaceGuid;
      found = true;
    }
  }
  ::WlanFreeMemory(iface_list);

  if (!found) return false;
  *out_guid = best_guid;

  if (out_supports_5g) {
    *out_supports_5g = false;
    PWLAN_INTERFACE_CAPABILITY cap = nullptr;
    if (::WlanGetInterfaceCapability(wlan, &best_guid, nullptr, &cap) == ERROR_SUCCESS &&
        cap) {
      for (DWORD j = 0; j < cap->dwNumberOfSupportedPhys; ++j) {
        const auto phy = cap->dot11PhyTypes[j];
        if (phy == dot11_phy_type_ofdm ||
            phy == dot11_phy_type_vht ||
            phy == dot11_phy_type_he) {
          *out_supports_5g = true;
          break;
        }
      }
      ::WlanFreeMemory(cap);
    }
  }

  return true;
}

bool IsWlanConnectedToSsid(
    HANDLE wlan,
    const GUID* iface_guid,
    const std::string& expected_ssid) {
  DWORD data_size = 0;
  PVOID data_ptr = nullptr;
  WLAN_OPCODE_VALUE_TYPE opcode_type = wlan_opcode_value_type_invalid;
  DWORD qres = ::WlanQueryInterface(
      wlan,
      iface_guid,
      wlan_intf_opcode_current_connection,
      nullptr,
      &data_size,
      &data_ptr,
      &opcode_type);
  if (qres != ERROR_SUCCESS || !data_ptr ||
      data_size < sizeof(WLAN_CONNECTION_ATTRIBUTES)) {
    if (data_ptr) ::WlanFreeMemory(data_ptr);
    return false;
  }

  auto* conn_attr = static_cast<PWLAN_CONNECTION_ATTRIBUTES>(data_ptr);
  bool matches = false;
  if (conn_attr->isState == wlan_interface_state_connected) {
    const auto& ssid = conn_attr->wlanAssociationAttributes.dot11Ssid;
    if (ssid.uSSIDLength == expected_ssid.size() &&
        std::memcmp(ssid.ucSSID, expected_ssid.data(), ssid.uSSIDLength) == 0) {
      matches = true;
    }
  }
  ::WlanFreeMemory(data_ptr);
  return matches;
}

struct SharedCallbackState {
  std::mutex mu;
  std::condition_variable cv;
  int in_flight_callbacks = 0;
  bool alive = true;
  DaphqBleBeaconCallback beacon_cb = nullptr;
  DaphqGattRequestCallback gatt_cb = nullptr;
  void* user_data = nullptr;
  std::string local_info_json = "{}";
  std::unordered_map<uint64_t, BluetoothAddressType> ble_addr_types;
  std::vector<WiFiDirectDevice> active_wfd_devices;
};

struct InFlightDecGuard {
  std::shared_ptr<SharedCallbackState> state;
  ~InFlightDecGuard() {
    if (!state) return;
    std::lock_guard<std::mutex> lock(state->mu);
    if (state->in_flight_callbacks > 0) {
      --state->in_flight_callbacks;
    }
    if (state->in_flight_callbacks == 0) {
      state->cv.notify_all();
    }
  }
};

struct DirectContext {
  std::shared_ptr<SharedCallbackState> state;
  std::atomic<bool> aborted{false};
  std::atomic<uint64_t> ble_generation{0};
  std::atomic<uint64_t> session_generation{0};

  std::mutex handle_mu;
  BluetoothLEAdvertisementPublisher ble_publisher{nullptr};
  BluetoothLEAdvertisementWatcher ble_watcher{nullptr};
  winrt::event_token watcher_token{};
  bool has_watcher_token = false;

  GattServiceProvider gatt_provider{nullptr};
  GattLocalCharacteristic info_char{nullptr};
  GattLocalCharacteristic link_char{nullptr};
  winrt::event_token info_read_token{};
  bool has_info_read_token = false;
  winrt::event_token link_write_token{};
  bool has_link_write_token = false;
  uint16_t active_manufacturer_id = 0x4451;

  WiFiDirectAdvertisementPublisher wfd_publisher{nullptr};
  WiFiDirectConnectionListener wfd_listener{nullptr};
  winrt::event_token wfd_conn_token{};
  bool has_wfd_conn_token = false;

  NetworkOperatorTetheringManager tethering_mgr{nullptr};
  bool restore_tethering_config = false;
  winrt::hstring orig_ap_ssid;
  winrt::hstring orig_ap_psk;
  TetheringWiFiBand orig_ap_band = TetheringWiFiBand::Auto;

  std::wstring saved_temp_profile_name;
  GUID active_wlan_guid{};
  bool has_active_wlan_guid = false;
};

template <typename AsyncOp>
bool AwaitWithAbort(
    const AsyncOp& op,
    DirectContext* ctx,
    std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (true) {
    if (ctx && ctx->aborted.load()) {
      try {
        op.Cancel();
      } catch (...) {
      }
      return false;
    }
    const auto status = op.wait_for(std::chrono::milliseconds(80));
    if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
      return true;
    }
    if (status != winrt::Windows::Foundation::AsyncStatus::Started) {
      return false;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      try {
        op.Cancel();
      } catch (...) {
      }
      return false;
    }
  }
}

}  // namespace

extern "C" {

void* daphq_direct_create(
    DaphqBleBeaconCallback beacon_cb,
    DaphqGattRequestCallback gatt_cb,
    void* user_data) {
  auto* ctx = new DirectContext();
  ctx->state = std::make_shared<SharedCallbackState>();
  ctx->state->beacon_cb = beacon_cb;
  ctx->state->gatt_cb = gatt_cb;
  ctx->state->user_data = user_data;
  return ctx;
}

void daphq_direct_request_abort(void* handle) {
  if (!handle) return;
  auto* ctx = static_cast<DirectContext*>(handle);
  ctx->aborted.store(true);
  {
    std::lock_guard<std::mutex> lock(ctx->state->mu);
    ctx->state->alive = false;
    ctx->state->beacon_cb = nullptr;
    ctx->state->gatt_cb = nullptr;
    ctx->state->user_data = nullptr;
  }
  ctx->state->cv.notify_all();
}

void daphq_direct_destroy(void* handle) {
  if (!handle) return;
  daphq_direct_request_abort(handle);
  daphq_direct_stop_ble_discovery(handle);
  daphq_direct_stop_session(handle);
  auto* ctx = static_cast<DirectContext*>(handle);
  {
    std::unique_lock<std::mutex> lock(ctx->state->mu);
    ctx->state->cv.wait(
        lock, [ctx]() { return ctx->state->in_flight_callbacks == 0; });
  }
  delete ctx;
}

DaphqRadioCapabilities daphq_direct_get_capabilities(void* /*handle*/) {
  ComMtaScope com;
  DaphqRadioCapabilities caps{0, 0, 0};

  try {
    HANDLE wlan = nullptr;
    DWORD negotiated = 0;
    if (::WlanOpenHandle(2, nullptr, &negotiated, &wlan) == ERROR_SUCCESS && wlan) {
      GUID iface_guid{};
      bool supports_5g = false;
      if (SelectBestWlanInterface(wlan, &iface_guid, &supports_5g)) {
        caps.has_wifi = 1;
        bool tethering_capable = false;
        try {
          auto profile = NetworkInformation::GetInternetConnectionProfile();
          if (profile) {
            auto cap = NetworkOperatorTetheringManager::GetTetheringCapabilityFromConnectionProfile(profile);
            tethering_capable = (cap == TetheringCapability::Enabled);
          }
        } catch (...) {}
        // Wi-Fi Direct / Hosted SoftAP 5GHz hosting is available on 5GHz-capable WLAN adapters
        // (Mobile Hotspot adds ICS DHCP when an internet profile is enabled; WFD works offline too).
        (void)tethering_capable;
        caps.can_host_direct_5g = supports_5g ? 1 : 0;
      }
      ::WlanCloseHandle(wlan, nullptr);
    }

    auto adapter = BluetoothAdapter::GetDefaultAsync().get();
    if (adapter && adapter.IsLowEnergySupported()) {
      bool bt_radio_on = false;
      try {
        auto radios = Radio::GetRadiosAsync().get();
        for (uint32_t i = 0; i < radios.Size(); ++i) {
          auto r = radios.GetAt(i);
          if (r.Kind() == RadioKind::Bluetooth) {
            bt_radio_on = (r.State() == RadioState::On);
            break;
          }
        }
      } catch (...) {
        bt_radio_on = true;
      }
      if (bt_radio_on) {
        caps.has_ble = 1;
      }
    }
  } catch (...) {}

  return caps;
}

int daphq_direct_start_ble_discovery(
    void* handle,
    uint16_t manufacturer_id,
    const uint8_t* beacon_payload,
    int beacon_len,
    const char* info_json) {
  if (!handle || !beacon_payload || beacon_len != 22) return 0;
  ComMtaScope com;
  auto* ctx = static_cast<DirectContext*>(handle);
  if (ctx->aborted.load()) return 0;

  daphq_direct_stop_ble_discovery(handle);
  const uint64_t my_gen = ++ctx->ble_generation;

  {
    std::lock_guard<std::mutex> slock(ctx->state->mu);
    if (!ctx->state->alive) return 0;
    ctx->state->local_info_json = info_json ? info_json : "{}";
  }

  std::shared_ptr<SharedCallbackState> cb_state = ctx->state;
  GattServiceProvider provider{nullptr};
  GattLocalCharacteristic info_char{nullptr};
  GattLocalCharacteristic link_char{nullptr};
  winrt::event_token info_token{};
  bool has_info_token = false;
  winrt::event_token link_token{};
  bool has_link_token = false;

  // Build GATT server outside handle_mu so WinRT .get() never blocks other calls.
  try {
    auto svc_res = GattServiceProvider::CreateAsync(kServiceUuid).get();
    if (ctx->aborted.load() || ctx->ble_generation.load() != my_gen) return 0;

    if (svc_res.Error() == BluetoothError::Success) {
      provider = svc_res.ServiceProvider();

      GattLocalCharacteristicParameters info_params;
      info_params.CharacteristicProperties(GattCharacteristicProperties::Read);
      info_params.ReadProtectionLevel(GattProtectionLevel::Plain);
      auto info_char_res =
          provider.Service().CreateCharacteristicAsync(kCharInfoUuid, info_params).get();
      if (info_char_res.Error() == BluetoothError::Success) {
        info_char = info_char_res.Characteristic();
        info_token = info_char.ReadRequested(
            [cb_state](GattLocalCharacteristic const&, GattReadRequestedEventArgs const& args) {
              try {
                DeferralGuard guard(args.GetDeferral());
                auto req = args.GetRequestAsync().get();
                std::string json_copy;
                {
                  std::lock_guard<std::mutex> g(cb_state->mu);
                  if (!cb_state->alive) {
                    req.RespondWithProtocolError(GattProtocolError::RequestNotSupported());
                    return;
                  }
                  json_copy = cb_state->local_info_json;
                }
                const uint32_t offset = req.Offset();
                DataWriter writer;
                if (offset < json_copy.size()) {
                  std::vector<uint8_t> slice(
                      json_copy.begin() + static_cast<std::ptrdiff_t>(offset),
                      json_copy.end());
                  writer.WriteBytes(slice);
                }
                req.RespondWithValue(writer.DetachBuffer());
              } catch (...) {}
            });
        has_info_token = true;
      }

      GattLocalCharacteristicParameters link_params;
      link_params.CharacteristicProperties(
          GattCharacteristicProperties::Write |
          GattCharacteristicProperties::WriteWithoutResponse |
          GattCharacteristicProperties::Notify);
      link_params.WriteProtectionLevel(GattProtectionLevel::Plain);
      auto link_char_res =
          provider.Service().CreateCharacteristicAsync(kCharLinkUuid, link_params).get();
      if (link_char_res.Error() == BluetoothError::Success) {
        link_char = link_char_res.Characteristic();
        link_token = link_char.WriteRequested(
            [cb_state](GattLocalCharacteristic const&, GattWriteRequestedEventArgs const& args) {
              try {
                DeferralGuard guard(args.GetDeferral());
                auto req = args.GetRequestAsync().get();
                auto reader = DataReader::FromBuffer(req.Value());
                std::vector<uint8_t> buf(reader.UnconsumedBufferLength());
                if (!buf.empty()) {
                  reader.ReadBytes(buf);
                }
                std::string payload(buf.begin(), buf.end());

                DaphqGattRequestCallback cb = nullptr;
                void* ud = nullptr;
                InFlightDecGuard flight_guard;
                {
                  std::lock_guard<std::mutex> g(cb_state->mu);
                  if (cb_state->alive && cb_state->gatt_cb && !payload.empty()) {
                    cb = cb_state->gatt_cb;
                    ud = cb_state->user_data;
                    ++cb_state->in_flight_callbacks;
                    flight_guard.state = cb_state;
                  }
                }
                if (cb) {
                  cb(payload.c_str(), ud);
                }
                if (req.Option() == GattWriteOption::WriteWithResponse) {
                  req.Respond();
                }
              } catch (...) {}
            });
        has_link_token = true;
      }

      GattServiceProviderAdvertisingParameters adv_params;
      adv_params.IsDiscoverable(true);
      adv_params.IsConnectable(true);
      provider.StartAdvertising(adv_params);
    }
  } catch (...) {}

  if (ctx->aborted.load() || ctx->ble_generation.load() != my_gen) {
    try {
      if (info_char && has_info_token) info_char.ReadRequested(info_token);
      if (link_char && has_link_token) link_char.WriteRequested(link_token);
      if (provider) provider.StopAdvertising();
    } catch (...) {}
    return 0;
  }

  // Build BLE Publisher
  BluetoothLEAdvertisementPublisher publisher{nullptr};
  bool publisher_ok = false;
  try {
    DataWriter writer;
    std::vector<uint8_t> bytes(beacon_payload, beacon_payload + beacon_len);
    writer.WriteBytes(bytes);

    BluetoothLEManufacturerData mfg_data;
    mfg_data.CompanyId(manufacturer_id);
    mfg_data.Data(writer.DetachBuffer());

    BluetoothLEAdvertisementPublisher p;
    p.Advertisement().ManufacturerData().Append(mfg_data);
    p.Start();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    const auto st = p.Status();
    if (st != BluetoothLEAdvertisementPublisherStatus::Aborted) {
      publisher = std::move(p);
      publisher_ok = true;
    } else {
      p.Stop();
    }
  } catch (...) {}

  // Build BLE Watcher
  BluetoothLEAdvertisementWatcher watcher{nullptr};
  winrt::event_token watcher_token{};
  bool has_watcher_token = false;
  bool watcher_ok = false;
  try {
    BluetoothLEAdvertisementWatcher w;
    w.ScanningMode(BluetoothLEScanningMode::Active);
    BluetoothLEManufacturerData filter_data;
    filter_data.CompanyId(manufacturer_id);
    w.AdvertisementFilter().Advertisement().ManufacturerData().Append(filter_data);

    watcher_token = w.Received(
        [cb_state, manufacturer_id](
            BluetoothLEAdvertisementWatcher const&,
            BluetoothLEAdvertisementReceivedEventArgs const& args) {
          try {
            auto mfg_list = args.Advertisement().ManufacturerData();
            for (uint32_t i = 0; i < mfg_list.Size(); ++i) {
              auto entry = mfg_list.GetAt(i);
              if (entry.CompanyId() != manufacturer_id) continue;
              auto reader = DataReader::FromBuffer(entry.Data());
              const uint32_t len = reader.UnconsumedBufferLength();
              if (len != 22) continue;
              std::vector<uint8_t> payload(len);
              reader.ReadBytes(payload);

              const uint64_t raw_addr = args.BluetoothAddress();
              const auto addr_type = args.BluetoothAddressType();
              std::string addr = FormatBleAddress(raw_addr);
              std::string name = winrt::to_string(args.Advertisement().LocalName());

              DaphqBleBeaconCallback cb = nullptr;
              void* ud = nullptr;
              InFlightDecGuard flight_guard;
              {
                std::lock_guard<std::mutex> g(cb_state->mu);
                if (!cb_state->alive) return;
                cb_state->ble_addr_types[raw_addr] = addr_type;
                cb = cb_state->beacon_cb;
                ud = cb_state->user_data;
                if (cb) {
                  ++cb_state->in_flight_callbacks;
                  flight_guard.state = cb_state;
                }
              }
              if (cb) {
                cb(
                    addr.c_str(),
                    name.c_str(),
                    args.RawSignalStrengthInDBm(),
                    payload.data(),
                    static_cast<int>(payload.size()),
                    ud);
              }
            }
          } catch (...) {}
        });
    has_watcher_token = true;
    w.Start();
    const auto wst = w.Status();
    if (wst != BluetoothLEAdvertisementWatcherStatus::Aborted) {
      watcher = std::move(w);
      watcher_ok = true;
    } else {
      if (has_watcher_token) w.Received(watcher_token);
      has_watcher_token = false;
      w.Stop();
    }
  } catch (...) {}

  std::lock_guard<std::mutex> lock(ctx->handle_mu);
  if (ctx->aborted.load() || ctx->ble_generation.load() != my_gen) {
    try {
      if (watcher && has_watcher_token) watcher.Received(watcher_token);
      if (watcher) watcher.Stop();
      if (publisher) publisher.Stop();
      if (info_char && has_info_token) info_char.ReadRequested(info_token);
      if (link_char && has_link_token) link_char.WriteRequested(link_token);
      if (provider) provider.StopAdvertising();
    } catch (...) {}
    return 0;
  }

  ctx->active_manufacturer_id = manufacturer_id;
  ctx->gatt_provider = std::move(provider);
  ctx->info_char = std::move(info_char);
  ctx->info_read_token = info_token;
  ctx->has_info_read_token = has_info_token;
  ctx->link_char = std::move(link_char);
  ctx->link_write_token = link_token;
  ctx->has_link_write_token = has_link_token;
  ctx->ble_publisher = std::move(publisher);
  ctx->ble_watcher = std::move(watcher);
  ctx->watcher_token = watcher_token;
  ctx->has_watcher_token = has_watcher_token;

  return (publisher_ok || watcher_ok) ? 1 : 0;
}

void daphq_direct_stop_ble_discovery(void* handle) {
  if (!handle) return;
  ComMtaScope com;
  auto* ctx = static_cast<DirectContext*>(handle);
  ++ctx->ble_generation;

  BluetoothLEAdvertisementWatcher watcher{nullptr};
  winrt::event_token w_token{};
  bool has_w_token = false;
  BluetoothLEAdvertisementPublisher publisher{nullptr};
  GattServiceProvider provider{nullptr};
  GattLocalCharacteristic info_c{nullptr};
  winrt::event_token i_token{};
  bool has_i_token = false;
  GattLocalCharacteristic link_c{nullptr};
  winrt::event_token l_token{};
  bool has_l_token = false;

  {
    std::lock_guard<std::mutex> lock(ctx->handle_mu);
    watcher = std::move(ctx->ble_watcher);
    w_token = ctx->watcher_token;
    has_w_token = ctx->has_watcher_token;
    ctx->has_watcher_token = false;

    publisher = std::move(ctx->ble_publisher);
    provider = std::move(ctx->gatt_provider);

    info_c = std::move(ctx->info_char);
    i_token = ctx->info_read_token;
    has_i_token = ctx->has_info_read_token;
    ctx->has_info_read_token = false;

    link_c = std::move(ctx->link_char);
    l_token = ctx->link_write_token;
    has_l_token = ctx->has_link_write_token;
    ctx->has_link_write_token = false;
  }

  try {
    if (watcher) {
      if (has_w_token) watcher.Received(w_token);
      watcher.Stop();
    }
  } catch (...) {}

  try {
    if (publisher) publisher.Stop();
  } catch (...) {}

  try {
    if (info_c && has_i_token) info_c.ReadRequested(i_token);
    if (link_c && has_l_token) link_c.WriteRequested(l_token);
    if (provider) provider.StopAdvertising();
  } catch (...) {}
}

DaphqDirectHostInfo daphq_direct_start_host(void* handle, int prefer_5ghz) {
  DaphqDirectHostInfo info{};
  if (!handle) return info;
  ComMtaScope com;
  auto* ctx = static_cast<DirectContext*>(handle);
  if (ctx->aborted.load()) return info;

  daphq_direct_stop_session(handle);
  const uint64_t my_gen = ++ctx->session_generation;

  const std::string suffix = RandomString("ABCDEFGHJKLMNPQRSTUVWXYZ23456789", 4);
  const std::string psk =
      RandomString("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789", 12);
  const std::string ssid = "DIRECT-DQ-" + suffix;

  // 1. Primary strategy when PC has an active ConnectionProfile: Mobile Hotspot (ICS + DHCP)
  NetworkOperatorTetheringManager tethering_for_restore{nullptr};
  bool ap_modified = false;
  winrt::hstring restore_orig_ssid;
  winrt::hstring restore_orig_psk;
  TetheringWiFiBand restore_orig_band = TetheringWiFiBand::Auto;
  try {
    auto profile = NetworkInformation::GetInternetConnectionProfile();
    if (profile &&
        NetworkOperatorTetheringManager::GetTetheringCapabilityFromConnectionProfile(profile) ==
            TetheringCapability::Enabled) {
      auto tethering = NetworkOperatorTetheringManager::CreateFromConnectionProfile(profile);
      auto prev_cfg = tethering.GetCurrentAccessPointConfiguration();
      const auto orig_ssid = prev_cfg.Ssid();
      const auto orig_psk = prev_cfg.Passphrase();
      const auto orig_band = prev_cfg.Band();

      NetworkOperatorTetheringAccessPointConfiguration cfg;
      cfg.Ssid(winrt::to_hstring(ssid));
      cfg.Passphrase(winrt::to_hstring(psk));
      bool using_5g = false;
      if (prefer_5ghz && cfg.IsBandSupported(TetheringWiFiBand::FiveGigahertz)) {
        cfg.Band(TetheringWiFiBand::FiveGigahertz);
        using_5g = true;
      }

      tethering_for_restore = tethering;
      restore_orig_ssid = orig_ssid;
      restore_orig_psk = orig_psk;
      restore_orig_band = orig_band;
      ap_modified = true;

      tethering.ConfigureAccessPointAsync(cfg).get();
      auto start_res = tethering.StartTetheringAsync().get();
      if (start_res.Status() == TetheringOperationStatus::Success) {
        {
          std::lock_guard<std::mutex> lock(ctx->handle_mu);
          if (ctx->aborted.load() || ctx->session_generation.load() != my_gen) {
            try {
              tethering.StopTetheringAsync().get();
              NetworkOperatorTetheringAccessPointConfiguration restore;
              restore.Ssid(orig_ssid);
              restore.Passphrase(orig_psk);
              restore.Band(orig_band);
              tethering.ConfigureAccessPointAsync(restore).get();
              ap_modified = false;
            } catch (...) {}
            return info;
          }
          ctx->tethering_mgr = tethering;
          ctx->restore_tethering_config = true;
          ctx->orig_ap_ssid = orig_ssid;
          ctx->orig_ap_psk = orig_psk;
          ctx->orig_ap_band = orig_band;
          ap_modified = false;
        }

        std::string host_ip;
        for (int i = 0; i < 12; ++i) {
          if (ctx->aborted.load()) {
            daphq_direct_stop_session(handle);
            return info;
          }
          if (ctx->session_generation.load() != my_gen) {
            return info;
          }
          host_ip = FindSoftApHostIp();
          if (!host_ip.empty()) break;
          std::this_thread::sleep_for(std::chrono::milliseconds(250));
        }

        info.success = 1;
        std::snprintf(info.ssid, sizeof(info.ssid), "%s", ssid.c_str());
        std::snprintf(info.psk, sizeof(info.psk), "%s", psk.c_str());
        std::snprintf(
            info.host_ip,
            sizeof(info.host_ip),
            "%s",
            host_ip.empty() ? "192.168.137.1" : host_ip.c_str());
        info.frequency_mhz = using_5g ? 5180 : 2437;
        return info;
      }
      // Restore original AP config if start failed
      try {
        NetworkOperatorTetheringAccessPointConfiguration restore;
        restore.Ssid(orig_ssid);
        restore.Passphrase(orig_psk);
        restore.Band(orig_band);
        tethering.ConfigureAccessPointAsync(restore).get();
        ap_modified = false;
      } catch (...) {}
    }
  } catch (...) {
    if (ap_modified && tethering_for_restore) {
      try {
        NetworkOperatorTetheringAccessPointConfiguration restore;
        restore.Ssid(restore_orig_ssid);
        restore.Passphrase(restore_orig_psk);
        restore.Band(restore_orig_band);
        tethering_for_restore.ConfigureAccessPointAsync(restore).get();
      } catch (...) {}
    }
  }

  // 2. Fallback strategy: Wi-Fi Direct AdvertisementPublisher LegacySettings
  try {
    WiFiDirectAdvertisementPublisher publisher;
    publisher.Advertisement().IsAutonomousGroupOwnerEnabled(true);
    publisher.Advertisement().ListenStateDiscoverability(
        WiFiDirectAdvertisementListenStateDiscoverability::Normal);

    auto legacy = publisher.Advertisement().LegacySettings();
    legacy.IsEnabled(true);
    legacy.Ssid(winrt::to_hstring(ssid));
    PasswordCredential cred;
    cred.Password(winrt::to_hstring(psk));
    legacy.Passphrase(cred);

    WiFiDirectConnectionListener listener;
    std::shared_ptr<SharedCallbackState> cb_state = ctx->state;
    auto token = listener.ConnectionRequested(
        [cb_state](WiFiDirectConnectionListener const&, WiFiDirectConnectionRequestedEventArgs const& args) {
          try {
            auto req = args.GetConnectionRequest();
            auto dev = WiFiDirectDevice::FromIdAsync(req.DeviceInformation().Id()).get();
            if (dev) {
              std::lock_guard<std::mutex> lock(cb_state->mu);
              if (cb_state->alive) {
                cb_state->active_wfd_devices.push_back(dev);
              } else {
                dev.Close();
              }
            }
          } catch (...) {}
        });

    publisher.Start();
    for (int i = 0; i < 6; ++i) {
      if (publisher.Status() == WiFiDirectAdvertisementPublisherStatus::Started ||
          publisher.Status() == WiFiDirectAdvertisementPublisherStatus::Aborted) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(150));
    }

    if (publisher.Status() == WiFiDirectAdvertisementPublisherStatus::Aborted) {
      listener.ConnectionRequested(token);
      publisher.Stop();
      return info;
    }

    {
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      if (ctx->aborted.load() || ctx->session_generation.load() != my_gen) {
        listener.ConnectionRequested(token);
        publisher.Stop();
        return info;
      }
      ctx->wfd_publisher = publisher;
      ctx->wfd_listener = listener;
      ctx->wfd_conn_token = token;
      ctx->has_wfd_conn_token = true;
    }

    std::string host_ip;
    for (int i = 0; i < 6; ++i) {
      if (ctx->aborted.load()) {
        daphq_direct_stop_session(handle);
        return info;
      }
      if (ctx->session_generation.load() != my_gen) {
        return info;
      }
      host_ip = FindSoftApHostIp();
      if (!host_ip.empty()) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    info.success = 1;
    std::snprintf(info.ssid, sizeof(info.ssid), "%s", ssid.c_str());
    std::snprintf(info.psk, sizeof(info.psk), "%s", psk.c_str());
    std::snprintf(
        info.host_ip,
        sizeof(info.host_ip),
        "%s",
        host_ip.empty() ? "192.168.137.1" : host_ip.c_str());
    info.frequency_mhz = prefer_5ghz ? 5180 : 2437;
  } catch (...) {
    info.success = 0;
  }

  return info;
}

DaphqDirectClientConn daphq_direct_connect_client(
    void* handle,
    const char* ssid_c,
    const char* psk_c,
    const char* expected_gateway_ip_c) {
  DaphqDirectClientConn conn{};
  if (!handle || !ssid_c || !psk_c) return conn;

  auto* ctx = static_cast<DirectContext*>(handle);
  if (ctx->aborted.load()) return conn;
  const uint64_t my_gen = ctx->session_generation.load();
  const std::string ssid(ssid_c);
  const std::string psk(psk_c);
  const std::string fallback_gw =
      (expected_gateway_ip_c && expected_gateway_ip_c[0])
          ? expected_gateway_ip_c
          : "192.168.49.1";

  HANDLE wlan = nullptr;
  DWORD negotiated = 0;
  if (::WlanOpenHandle(2, nullptr, &negotiated, &wlan) != ERROR_SUCCESS || !wlan) {
    return conn;
  }

  GUID iface_guid{};
  if (!SelectBestWlanInterface(wlan, &iface_guid, nullptr)) {
    ::WlanCloseHandle(wlan, nullptr);
    return conn;
  }

  const std::wstring wprofile_xml = BuildWpa2ProfileXml(ssid, psk);
  const std::wstring wprofile_name = Utf8ToWide(ssid);
  std::wstring saved_profile;

  WLAN_CONNECTION_PARAMETERS params{};
  params.wlanConnectionMode = wlan_connection_mode_temporary_profile;
  params.strProfile = wprofile_xml.c_str();
  params.pDot11Ssid = nullptr;
  params.pDesiredBssidList = nullptr;
  params.dot11BssType = dot11_BSS_type_infrastructure;
  params.dwFlags = 0;

  DWORD conn_res = ::WlanConnect(wlan, &iface_guid, &params, nullptr);
  if (conn_res != ERROR_SUCCESS) {
    DWORD reason_code = 0;
    DWORD save_res = ::WlanSetProfile(
        wlan,
        &iface_guid,
        WLAN_PROFILE_USER,
        wprofile_xml.c_str(),
        nullptr,
        TRUE,
        nullptr,
        &reason_code);
    if (save_res != ERROR_SUCCESS) {
      ::WlanCloseHandle(wlan, nullptr);
      return conn;
    }
    saved_profile = wprofile_name;
    {
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      ctx->saved_temp_profile_name = wprofile_name;
    }
    params.wlanConnectionMode = wlan_connection_mode_profile;
    params.strProfile = wprofile_name.c_str();
    conn_res = ::WlanConnect(wlan, &iface_guid, &params, nullptr);
  }

  if (conn_res != ERROR_SUCCESS) {
    if (!saved_profile.empty()) {
      ::WlanDeleteProfile(wlan, &iface_guid, saved_profile.c_str(), nullptr);
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      ctx->saved_temp_profile_name.clear();
    }
    ::WlanCloseHandle(wlan, nullptr);
    return conn;
  }

  {
    std::lock_guard<std::mutex> lock(ctx->handle_mu);
    ctx->active_wlan_guid = iface_guid;
    ctx->has_active_wlan_guid = true;
  }

  // Wait up to 10 seconds for actual SSID association + non-APIPA DHCP IPv4
  for (int i = 0; i < 40; ++i) {
    if (ctx->aborted.load() || ctx->session_generation.load() != my_gen) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    if (!IsWlanConnectedToSsid(wlan, &iface_guid, ssid)) {
      continue;
    }
    std::string local_ip;
    std::string gw_ip = fallback_gw;
    if (QueryWifiInterfaceAddresses(&iface_guid, &local_ip, &gw_ip)) {
      conn.success = 1;
      std::snprintf(conn.local_ip, sizeof(conn.local_ip), "%s", local_ip.c_str());
      std::snprintf(conn.gateway_ip, sizeof(conn.gateway_ip), "%s", gw_ip.c_str());
      break;
    }
  }

  if (!conn.success) {
    const bool stopped_or_superseded =
        ctx->aborted.load() || ctx->session_generation.load() != my_gen;
    if (stopped_or_superseded || IsWlanConnectedToSsid(wlan, &iface_guid, ssid)) {
      ::WlanDisconnect(wlan, &iface_guid, nullptr);
    }
    if (ctx->session_generation.load() == my_gen) {
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      if (ctx->session_generation.load() == my_gen) {
        ctx->has_active_wlan_guid = false;
      }
    }
    if (!saved_profile.empty()) {
      ::WlanDeleteProfile(wlan, &iface_guid, saved_profile.c_str(), nullptr);
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      if (ctx->saved_temp_profile_name == saved_profile) {
        ctx->saved_temp_profile_name.clear();
      }
    }
  }

  ::WlanCloseHandle(wlan, nullptr);
  return conn;
}

int daphq_direct_exchange_gatt_link(
    void* handle,
    const char* ble_address,
    const char* request_json,
    char* out_response_json,
    int out_capacity) {
  if (!ble_address || !request_json || !out_response_json || out_capacity <= 0) {
    return 0;
  }
  uint64_t addr = 0;
  if (!ParseBleAddress(ble_address, &addr)) {
    return 0;
  }

  ComMtaScope com;
  BluetoothLEDevice dev{nullptr};
  GattDeviceService svc{nullptr};
  const auto overall_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(14);
  auto remaining_ms = [&](std::chrono::milliseconds step_cap) {
    const auto now = std::chrono::steady_clock::now();
    if (now >= overall_deadline) {
      return std::chrono::milliseconds(0);
    }
    const auto rem =
        std::chrono::duration_cast<std::chrono::milliseconds>(overall_deadline - now);
    return (rem < step_cap) ? rem : step_cap;
  };
  try {
    DirectContext* ctx = handle ? static_cast<DirectContext*>(handle) : nullptr;
    bool has_addr_type = false;
    BluetoothAddressType cached_type = BluetoothAddressType::Unspecified;

    if (ctx) {
      if (ctx->aborted.load()) return 0;
      std::lock_guard<std::mutex> g(ctx->state->mu);
      auto it = ctx->state->ble_addr_types.find(addr);
      if (it != ctx->state->ble_addr_types.end()) {
        cached_type = it->second;
        has_addr_type = true;
      }
    }

    if (has_addr_type) {
      const auto budget = remaining_ms(std::chrono::seconds(5));
      if (budget.count() <= 0) return 0;
      auto dev_op = BluetoothLEDevice::FromBluetoothAddressAsync(addr, cached_type);
      if (AwaitWithAbort(dev_op, ctx, budget)) {
        dev = dev_op.GetResults();
      }
    }
    if (!dev && (!ctx || !ctx->aborted.load())) {
      const auto budget = remaining_ms(std::chrono::seconds(5));
      if (budget.count() <= 0) return 0;
      auto dev_op = BluetoothLEDevice::FromBluetoothAddressAsync(addr);
      if (AwaitWithAbort(dev_op, ctx, budget)) {
        dev = dev_op.GetResults();
      }
    }
    if (!dev) return 0;

    const auto svc_budget = remaining_ms(std::chrono::seconds(5));
    if (svc_budget.count() <= 0) {
      dev.Close();
      return 0;
    }
    auto svc_op =
        dev.GetGattServicesForUuidAsync(kServiceUuid, BluetoothCacheMode::Uncached);
    if (!AwaitWithAbort(svc_op, ctx, svc_budget)) {
      dev.Close();
      return 0;
    }
    auto svc_result = svc_op.GetResults();
    if (svc_result.Status() != GattCommunicationStatus::Success ||
        svc_result.Services().Size() == 0) {
      dev.Close();
      return 0;
    }

    svc = svc_result.Services().GetAt(0);
    std::string info_response = "{\"ok\":true}";

    const auto info_budget = remaining_ms(std::chrono::seconds(3));
    if (info_budget.count() > 0) {
      auto info_op =
          svc.GetCharacteristicsForUuidAsync(kCharInfoUuid, BluetoothCacheMode::Uncached);
      if (AwaitWithAbort(info_op, ctx, info_budget)) {
        auto info_res = info_op.GetResults();
        if (info_res.Status() == GattCommunicationStatus::Success &&
            info_res.Characteristics().Size() > 0) {
          const auto read_budget = remaining_ms(std::chrono::seconds(3));
          if (read_budget.count() > 0) {
            auto read_op = info_res.Characteristics()
                               .GetAt(0)
                               .ReadValueAsync(BluetoothCacheMode::Uncached);
            if (AwaitWithAbort(read_op, ctx, read_budget)) {
              auto read_res = read_op.GetResults();
              if (read_res.Status() == GattCommunicationStatus::Success && read_res.Value()) {
                auto reader = DataReader::FromBuffer(read_res.Value());
                std::vector<uint8_t> buf(reader.UnconsumedBufferLength());
                if (!buf.empty()) {
                  reader.ReadBytes(buf);
                  info_response.assign(buf.begin(), buf.end());
                }
              }
            }
          }
        }
      }
    }

    if (ctx && ctx->aborted.load()) {
      svc.Close();
      dev.Close();
      return 0;
    }

    const auto link_budget = remaining_ms(std::chrono::seconds(4));
    if (link_budget.count() <= 0) {
      svc.Close();
      dev.Close();
      return 0;
    }
    auto link_op =
        svc.GetCharacteristicsForUuidAsync(kCharLinkUuid, BluetoothCacheMode::Uncached);
    if (!AwaitWithAbort(link_op, ctx, link_budget)) {
      svc.Close();
      dev.Close();
      return 0;
    }
    auto link_res = link_op.GetResults();
    if (link_res.Status() != GattCommunicationStatus::Success ||
        link_res.Characteristics().Size() == 0) {
      svc.Close();
      dev.Close();
      return 0;
    }

    DataWriter writer;
    const std::string req_str(request_json);
    std::vector<uint8_t> req_bytes(req_str.begin(), req_str.end());
    writer.WriteBytes(req_bytes);

    const auto write_budget = remaining_ms(std::chrono::seconds(5));
    if (write_budget.count() <= 0) {
      svc.Close();
      dev.Close();
      return 0;
    }
    auto write_op = link_res.Characteristics().GetAt(0).WriteValueAsync(
        writer.DetachBuffer(), GattWriteOption::WriteWithResponse);
    GattCommunicationStatus write_status = GattCommunicationStatus::Unreachable;
    if (AwaitWithAbort(write_op, ctx, write_budget)) {
      write_status = write_op.GetResults();
    }
    svc.Close();
    svc = nullptr;
    dev.Close();
    dev = nullptr;

    if (write_status != GattCommunicationStatus::Success) {
      return 0;
    }

    if (static_cast<int>(info_response.size()) >= out_capacity) {
      info_response.resize(static_cast<size_t>(out_capacity - 1));
    }
    std::snprintf(out_response_json, static_cast<size_t>(out_capacity), "%s",
                  info_response.c_str());
    return 1;
  } catch (...) {
    try {
      if (svc) svc.Close();
    } catch (...) {
    }
    try {
      if (dev) dev.Close();
    } catch (...) {
    }
    return 0;
  }
}

void daphq_direct_stop_session(void* handle) {
  if (!handle) return;
  ComMtaScope com;
  auto* ctx = static_cast<DirectContext*>(handle);
  ++ctx->session_generation;

  std::wstring temp_profile;
  GUID wlan_guid{};
  bool disconnect_wlan = false;

  WiFiDirectConnectionListener wfd_listener{nullptr};
  winrt::event_token wfd_token{};
  bool has_wfd_token = false;
  WiFiDirectAdvertisementPublisher wfd_publisher{nullptr};

  NetworkOperatorTetheringManager tethering{nullptr};
  bool restore_cfg = false;
  winrt::hstring orig_ssid;
  winrt::hstring orig_psk;
  TetheringWiFiBand orig_band = TetheringWiFiBand::Auto;

  std::vector<WiFiDirectDevice> devices_to_close;
  {
    std::lock_guard<std::mutex> slock(ctx->state->mu);
    devices_to_close = std::move(ctx->state->active_wfd_devices);
  }
  for (auto& d : devices_to_close) {
    try {
      if (d) d.Close();
    } catch (...) {}
  }

  {
    std::lock_guard<std::mutex> lock(ctx->handle_mu);
    temp_profile = std::move(ctx->saved_temp_profile_name);
    ctx->saved_temp_profile_name.clear();
    if (ctx->has_active_wlan_guid) {
      wlan_guid = ctx->active_wlan_guid;
      ctx->has_active_wlan_guid = false;
      disconnect_wlan = true;
    }

    wfd_listener = std::move(ctx->wfd_listener);
    wfd_token = ctx->wfd_conn_token;
    has_wfd_token = ctx->has_wfd_conn_token;
    ctx->has_wfd_conn_token = false;
    wfd_publisher = std::move(ctx->wfd_publisher);

    tethering = std::move(ctx->tethering_mgr);
    restore_cfg = ctx->restore_tethering_config;
    ctx->restore_tethering_config = false;
    orig_ssid = std::move(ctx->orig_ap_ssid);
    orig_psk = std::move(ctx->orig_ap_psk);
    orig_band = ctx->orig_ap_band;
  }

  try {
    if (wfd_listener) {
      if (has_wfd_token) wfd_listener.ConnectionRequested(wfd_token);
    }
    if (wfd_publisher) {
      wfd_publisher.Stop();
    }
  } catch (...) {}

  try {
    if (tethering) {
      tethering.StopTetheringAsync().get();
      if (restore_cfg) {
        NetworkOperatorTetheringAccessPointConfiguration cfg;
        cfg.Ssid(orig_ssid);
        cfg.Passphrase(orig_psk);
        cfg.Band(orig_band);
        tethering.ConfigureAccessPointAsync(cfg).get();
      }
    }
  } catch (...) {}

  if (disconnect_wlan || !temp_profile.empty()) {
    HANDLE wlan = nullptr;
    DWORD negotiated = 0;
    if (::WlanOpenHandle(2, nullptr, &negotiated, &wlan) == ERROR_SUCCESS && wlan) {
      if (disconnect_wlan) {
        ::WlanDisconnect(wlan, &wlan_guid, nullptr);
      }
      if (!temp_profile.empty()) {
        ::WlanDeleteProfile(wlan, &wlan_guid, temp_profile.c_str(), nullptr);
      }
      ::WlanCloseHandle(wlan, nullptr);
    }
  }
}

}  // extern "C"
