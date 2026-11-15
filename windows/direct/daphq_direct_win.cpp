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
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <cwchar>
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
#include <winrt/Windows.Networking.h>
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

int QueryConnectedChannelFrequencyMhz(HANDLE wlan, const GUID& iface_guid) {
  if (!wlan) return 0;
  ULONG data_size = 0;
  PVOID raw_data = nullptr;
  WLAN_OPCODE_VALUE_TYPE value_type = wlan_opcode_value_type_invalid;
  const DWORD res = ::WlanQueryInterface(
      wlan,
      &iface_guid,
      wlan_intf_opcode_channel_number,
      nullptr,
      &data_size,
      &raw_data,
      &value_type);
  int freq_mhz = 0;
  if (res == ERROR_SUCCESS && raw_data != nullptr && data_size >= sizeof(ULONG)) {
    const ULONG ch = *reinterpret_cast<const ULONG*>(raw_data);
    if (ch >= 1 && ch <= 13) {
      freq_mhz = static_cast<int>(2407 + 5 * ch);
    } else if (ch == 14) {
      freq_mhz = 2484;
    } else if (ch >= 32 && ch <= 177) {
      freq_mhz = static_cast<int>(5000 + 5 * ch);
    } else if (ch >= 2400 && ch <= 7125) {
      freq_mhz = static_cast<int>(ch);
    } else if (ch >= 2400000 && ch <= 7125000) {
      freq_mhz = static_cast<int>(ch / 1000);
    }
  }
  if (raw_data != nullptr) {
    ::WlanFreeMemory(raw_data);
  }
  if (freq_mhz > 0) {
    return freq_mhz;
  }

  // Fallback via active BSS entry (ulChCenterFrequency in kHz) when a driver
  // omits wlan_intf_opcode_channel_number right after association.
  ULONG conn_size = 0;
  PVOID conn_raw = nullptr;
  WLAN_OPCODE_VALUE_TYPE conn_type = wlan_opcode_value_type_invalid;
  if (::WlanQueryInterface(
          wlan,
          &iface_guid,
          wlan_intf_opcode_current_connection,
          nullptr,
          &conn_size,
          &conn_raw,
          &conn_type) == ERROR_SUCCESS &&
      conn_raw != nullptr &&
      conn_size >= sizeof(WLAN_CONNECTION_ATTRIBUTES)) {
    const auto* attrs =
        reinterpret_cast<const WLAN_CONNECTION_ATTRIBUTES*>(conn_raw);
    DOT11_SSID ssid = attrs->wlanAssociationAttributes.dot11Ssid;
    PWLAN_BSS_LIST bss_list = nullptr;
    if (::WlanGetNetworkBssList(
            wlan,
            &iface_guid,
            ssid.uSSIDLength > 0 ? &ssid : nullptr,
            attrs->wlanAssociationAttributes.dot11BssType,
            FALSE,
            nullptr,
            &bss_list) == ERROR_SUCCESS &&
        bss_list != nullptr) {
      int ssid_match_freq = 0;
      for (DWORD i = 0; i < bss_list->dwNumberOfItems; ++i) {
        const WLAN_BSS_ENTRY& bss = bss_list->wlanBssEntries[i];
        if (bss.ulChCenterFrequency == 0) continue;
        const int cand = static_cast<int>(bss.ulChCenterFrequency / 1000);
        if (std::memcmp(
                bss.dot11Bssid,
                attrs->wlanAssociationAttributes.dot11Bssid,
                sizeof(DOT11_MAC_ADDRESS)) == 0) {
          freq_mhz = cand;
          break;
        }
        if (ssid_match_freq == 0) {
          ssid_match_freq = cand;
        }
      }
      if (freq_mhz == 0) {
        freq_mhz = ssid_match_freq;
      }
      ::WlanFreeMemory(bss_list);
    }
  }
  if (conn_raw != nullptr) {
    ::WlanFreeMemory(conn_raw);
  }
  return freq_mhz;
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

struct WlanProbeResult {
  bool hardware_present = false;
  bool radio_on = false;
  bool ready_found = false;
  GUID best_guid{};
  bool supports_5g = false;
};

WlanProbeResult ProbeWlanState(HANDLE wlan) {
  WlanProbeResult res;
  PWLAN_INTERFACE_INFO_LIST iface_list = nullptr;
  if (::WlanEnumInterfaces(wlan, nullptr, &iface_list) != ERROR_SUCCESS ||
      !iface_list) {
    return res;
  }

  res.hardware_present = (iface_list->dwNumberOfItems > 0);
  int best_score = -1;

  for (DWORD i = 0; i < iface_list->dwNumberOfItems; ++i) {
    const auto& info = iface_list->InterfaceInfo[i];
    bool iface_radio_on = (info.isState != wlan_interface_state_not_ready);

    DWORD rsz = 0;
    PVOID rptr = nullptr;
    WLAN_OPCODE_VALUE_TYPE rop = wlan_opcode_value_type_invalid;
    if (::WlanQueryInterface(
            wlan,
            &info.InterfaceGuid,
            wlan_intf_opcode_radio_state,
            nullptr,
            &rsz,
            &rptr,
            &rop) == ERROR_SUCCESS &&
        rptr &&
        rsz >= sizeof(WLAN_RADIO_STATE)) {
      const auto* rs = static_cast<PWLAN_RADIO_STATE>(rptr);
      if (rs->dwNumberOfPhys > 0) {
        constexpr DWORD max_phys = static_cast<DWORD>(
            sizeof(rs->PhyRadioState) / sizeof(rs->PhyRadioState[0]));
        bool any_phy_on = false;
        for (DWORD p = 0; p < rs->dwNumberOfPhys && p < max_phys; ++p) {
          if (rs->PhyRadioState[p].dot11SoftwareRadioState ==
                  dot11_radio_state_on &&
              rs->PhyRadioState[p].dot11HardwareRadioState ==
                  dot11_radio_state_on) {
            any_phy_on = true;
            break;
          }
        }
        iface_radio_on = any_phy_on;
      }
    }
    if (rptr) {
      ::WlanFreeMemory(rptr);
    }

    if (iface_radio_on) {
      res.radio_on = true;
    }
    if (info.isState == wlan_interface_state_not_ready) continue;
    int score = (info.isState == wlan_interface_state_connected) ? 3 : 2;
    if (score > best_score) {
      best_score = score;
      res.best_guid = info.InterfaceGuid;
      res.ready_found = true;
    }
  }
  ::WlanFreeMemory(iface_list);

  if (res.ready_found) {
    PWLAN_INTERFACE_CAPABILITY cap = nullptr;
    if (::WlanGetInterfaceCapability(wlan, &res.best_guid, nullptr, &cap) == ERROR_SUCCESS &&
        cap) {
      for (DWORD j = 0; j < cap->dwNumberOfSupportedPhys; ++j) {
        const auto phy = cap->dot11PhyTypes[j];
        if (phy == dot11_phy_type_ofdm ||
            phy == dot11_phy_type_vht ||
            phy == dot11_phy_type_he) {
          res.supports_5g = true;
          break;
        }
      }
      ::WlanFreeMemory(cap);
    }
  }

  return res;
}

bool SelectBestWlanInterface(
    HANDLE wlan,
    GUID* out_guid,
    bool* out_supports_5g) {
  const WlanProbeResult probe = ProbeWlanState(wlan);
  if (!probe.ready_found) return false;
  *out_guid = probe.best_guid;
  if (out_supports_5g) {
    *out_supports_5g = probe.supports_5g;
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

bool IsLocationConsentDeniedKey(HKEY root, const wchar_t* subkey) {
  wchar_t value_buf[64]{};
  DWORD cb = static_cast<DWORD>(sizeof(value_buf));
  const LSTATUS st = ::RegGetValueW(
      root,
      subkey,
      L"Value",
      RRF_RT_REG_SZ,
      nullptr,
      value_buf,
      &cb);
  if (st != ERROR_SUCCESS) return false;
  value_buf[63] = L'\0';
  return ::_wcsicmp(value_buf, L"Deny") == 0;
}

bool QueryWindowsLocationConsent() {
  static constexpr wchar_t kLocSubkey[] =
      L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location";
  static constexpr wchar_t kLocNonPackagedSubkey[] =
      L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location\\NonPackaged";
  if (IsLocationConsentDeniedKey(HKEY_LOCAL_MACHINE, kLocSubkey)) return false;
  if (IsLocationConsentDeniedKey(HKEY_CURRENT_USER, kLocSubkey)) return false;
  if (IsLocationConsentDeniedKey(HKEY_CURRENT_USER, kLocNonPackagedSubkey)) {
    return false;
  }
  return true;
}

std::string SanitizeStableDirectTag(const char* raw) {
  if (!raw) return {};
  std::string out;
  out.reserve(10);
  for (const char* p = raw; *p != '\0' && out.size() < 10; ++p) {
    const unsigned char uc = static_cast<unsigned char>(*p);
    if (std::isalnum(uc) != 0) {
      out.push_back(static_cast<char>(std::toupper(uc)));
    }
  }
  return out;
}

bool CapsEqual(const DaphqRadioCapabilities& a, const DaphqRadioCapabilities& b) {
  return a.has_wifi == b.has_wifi &&
         a.has_ble == b.has_ble &&
         a.wifi_hardware_present == b.wifi_hardware_present &&
         a.wifi_enabled == b.wifi_enabled &&
         a.bluetooth_hardware_present == b.bluetooth_hardware_present &&
         a.bluetooth_enabled == b.bluetooth_enabled &&
         a.can_host_direct_5g == b.can_host_direct_5g &&
         a.location_service_enabled == b.location_service_enabled;
}

bool QueryConnectedProfileInfo(
    HANDLE wlan, const GUID& iface_guid, std::wstring* out_profile_name) {
  if (out_profile_name) out_profile_name->clear();
  if (!wlan || !out_profile_name) return false;
  DWORD data_size = 0;
  PWLAN_CONNECTION_ATTRIBUTES conn_attrs = nullptr;
  const DWORD qres = ::WlanQueryInterface(
      wlan,
      &iface_guid,
      wlan_intf_opcode_current_connection,
      nullptr,
      &data_size,
      reinterpret_cast<PVOID*>(&conn_attrs),
      nullptr);
  if (qres != ERROR_SUCCESS || !conn_attrs) {
    if (conn_attrs) ::WlanFreeMemory(conn_attrs);
    return false;
  }
  const bool connected = (conn_attrs->isState == wlan_interface_state_connected);
  std::wstring profile_name(conn_attrs->strProfileName);
  ::WlanFreeMemory(conn_attrs);
  if (!connected || profile_name.empty()) return false;
  if (profile_name.rfind(L"DIRECT-DQ-", 0) == 0) return false;
  *out_profile_name = std::move(profile_name);
  return true;
}

void SetWlanInterfacePerfMode(HANDLE wlan, const GUID& iface_guid, bool enable) {
  if (!wlan) return;
  BOOL bg_scan = enable ? FALSE : TRUE;
  ::WlanSetInterface(
      wlan,
      &iface_guid,
      wlan_intf_opcode_background_scan_enabled,
      static_cast<DWORD>(sizeof(bg_scan)),
      &bg_scan,
      nullptr);
  BOOL media_mode = enable ? TRUE : FALSE;
  ::WlanSetInterface(
      wlan,
      &iface_guid,
      wlan_intf_opcode_media_streaming_mode,
      static_cast<DWORD>(sizeof(media_mode)),
      &media_mode,
      nullptr);
}

struct SharedCallbackState {
  std::mutex mu;
  std::condition_variable cv;
  int in_flight_callbacks = 0;
  bool alive = true;
  DaphqBleBeaconCallback beacon_cb = nullptr;
  DaphqGattRequestCallback gatt_cb = nullptr;
  DaphqRadioStateCallback radio_cb = nullptr;
  void* user_data = nullptr;
  std::string local_info_json = "{}";
  std::unordered_map<uint64_t, BluetoothAddressType> ble_addr_types;
  std::vector<WiFiDirectDevice> active_wfd_devices;
  bool radio_debounce_active = false;
  std::chrono::steady_clock::time_point radio_debounce_deadline{};
  bool has_last_radio_caps = false;
  DaphqRadioCapabilities last_radio_caps{};
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
  std::wstring prev_wifi_profile;
  GUID active_wlan_guid{};
  bool has_active_wlan_guid = false;
  GUID perf_tuned_guid{};
  bool wlan_perf_tuned = false;
  HANDLE power_request = INVALID_HANDLE_VALUE;
  bool power_lock_active = false;

  std::vector<std::pair<Radio, winrt::event_token>> radio_tokens;
  winrt::event_token net_status_token{};
  bool has_net_status_token = false;
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

void SetWindowsTransferPowerRequest(DirectContext* ctx, bool enable) {
  if (!ctx) return;
  HANDLE to_close = INVALID_HANDLE_VALUE;
  if (enable) {
    {
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      if (ctx->power_request != INVALID_HANDLE_VALUE || ctx->aborted.load()) {
        ctx->power_lock_active = (ctx->power_request != INVALID_HANDLE_VALUE);
        return;
      }
    }
    REASON_CONTEXT reason{};
    reason.Version = POWER_REQUEST_CONTEXT_VERSION;
    reason.Flags = POWER_REQUEST_CONTEXT_SIMPLE_STRING;
    reason.Reason.SimpleReasonString =
        const_cast<LPWSTR>(L"Daphq active high-speed transfer");
    HANDLE req = ::PowerCreateRequest(&reason);
    if (req != INVALID_HANDLE_VALUE) {
      if (!::PowerSetRequest(req, PowerRequestSystemRequired)) {
        ::CloseHandle(req);
        req = INVALID_HANDLE_VALUE;
      }
    }
    std::lock_guard<std::mutex> lock(ctx->handle_mu);
    if (req != INVALID_HANDLE_VALUE) {
      if (ctx->power_request == INVALID_HANDLE_VALUE && !ctx->aborted.load()) {
        ctx->power_request = req;
        ctx->power_lock_active = true;
      } else {
        to_close = req;
      }
    }
    if (to_close != INVALID_HANDLE_VALUE) {
      ::PowerClearRequest(to_close, PowerRequestSystemRequired);
      ::CloseHandle(to_close);
    }
  } else {
    {
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      to_close = ctx->power_request;
      ctx->power_request = INVALID_HANDLE_VALUE;
      ctx->power_lock_active = false;
    }
    if (to_close != INVALID_HANDLE_VALUE) {
      ::PowerClearRequest(to_close, PowerRequestSystemRequired);
      ::CloseHandle(to_close);
    }
  }
}

DaphqRadioCapabilities ProbeWinRadioCapabilities(bool force_wlan_refresh = true) {
  ComMtaScope com;
  DaphqRadioCapabilities caps{};
  caps.location_service_enabled = QueryWindowsLocationConsent() ? 1 : 0;

  try {
    static std::mutex s_wlan_cache_mu;
    static bool s_has_wlan_cache = false;
    static WlanProbeResult s_cached_wlan{};

    bool wifi_hw_from_radio = false;
    bool wifi_on_from_radio = false;
    bool bt_hw_from_radio = false;
    bool bt_on_from_radio = false;
    bool radio_query_ok = false;

    try {
      auto radios = Radio::GetRadiosAsync().get();
      radio_query_ok = true;
      for (uint32_t i = 0; i < radios.Size(); ++i) {
        auto r = radios.GetAt(i);
        if (r.Kind() == RadioKind::WiFi) {
          wifi_hw_from_radio = true;
          if (r.State() == RadioState::On) {
            wifi_on_from_radio = true;
          }
        } else if (r.Kind() == RadioKind::Bluetooth) {
          bt_hw_from_radio = true;
          if (r.State() == RadioState::On) {
            bt_on_from_radio = true;
          }
        }
      }
    } catch (...) {
      radio_query_ok = false;
    }

    bool need_wlan_probe = force_wlan_refresh || !radio_query_ok;
    WlanProbeResult wres{};
    {
      std::lock_guard<std::mutex> clock(s_wlan_cache_mu);
      if (!s_has_wlan_cache ||
          (!s_cached_wlan.supports_5g && wifi_on_from_radio)) {
        need_wlan_probe = true;
      }
      if (!need_wlan_probe) {
        wres = s_cached_wlan;
      }
    }

    if (need_wlan_probe) {
      HANDLE wlan = nullptr;
      DWORD negotiated = 0;
      if (::WlanOpenHandle(2, nullptr, &negotiated, &wlan) == ERROR_SUCCESS && wlan) {
        wres = ProbeWlanState(wlan);
        ::WlanCloseHandle(wlan, nullptr);
        std::lock_guard<std::mutex> clock(s_wlan_cache_mu);
        s_cached_wlan = wres;
        s_has_wlan_cache = true;
      }
    }

    const bool wifi_hw_from_wlan = wres.hardware_present;
    const bool wifi_on_from_wlan = wres.ready_found || wres.radio_on;
    const bool supports_5g = wres.supports_5g;

    const bool wifi_hw = wifi_hw_from_wlan || wifi_hw_from_radio;
    const bool wifi_on = radio_query_ok
                             ? wifi_on_from_radio
                             : (wifi_hw_from_wlan && wifi_on_from_wlan);
    caps.wifi_hardware_present = wifi_hw ? 1 : 0;
    caps.wifi_enabled = (wifi_hw && wifi_on) ? 1 : 0;
    caps.has_wifi = caps.wifi_enabled;
    bool tethering_5g_capable = false;
    if (caps.has_wifi && supports_5g) {
      try {
        auto profile = NetworkInformation::GetInternetConnectionProfile();
        if (profile &&
            NetworkOperatorTetheringManager::GetTetheringCapabilityFromConnectionProfile(
                profile) == TetheringCapability::Enabled) {
          auto tethering =
              NetworkOperatorTetheringManager::CreateFromConnectionProfile(profile);
          auto cfg = tethering.GetCurrentAccessPointConfiguration();
          tethering_5g_capable =
              cfg.IsBandSupported(TetheringWiFiBand::FiveGigahertz);
        }
      } catch (...) {
        tethering_5g_capable = false;
      }
    }
    caps.can_host_direct_5g = tethering_5g_capable ? 1 : 0;

    BluetoothAdapter adapter{nullptr};
    try {
      adapter = BluetoothAdapter::GetDefaultAsync().get();
    } catch (...) {
      adapter = nullptr;
    }
    const bool adapter_ble_supported = adapter && adapter.IsLowEnergySupported();
    const bool bt_hw = adapter_ble_supported || bt_hw_from_radio;
    const bool bt_on = bt_hw_from_radio ? bt_on_from_radio : (!radio_query_ok && adapter_ble_supported);
    caps.bluetooth_hardware_present = bt_hw ? 1 : 0;
    caps.bluetooth_enabled = (bt_hw && bt_on) ? 1 : 0;
    caps.has_ble = (adapter_ble_supported && bt_on) ? 1 : 0;
  } catch (...) {}

  return caps;
}

void NotifyRadioStateChange(const std::shared_ptr<SharedCallbackState>& cb_state) {
  if (!cb_state) return;
  bool launch_debouncer = false;
  {
    std::lock_guard<std::mutex> slock(cb_state->mu);
    if (!cb_state->alive || !cb_state->radio_cb) return;
    cb_state->radio_debounce_deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(380);
    if (!cb_state->radio_debounce_active) {
      cb_state->radio_debounce_active = true;
      ++cb_state->in_flight_callbacks;
      launch_debouncer = true;
    }
  }
  cb_state->cv.notify_all();
  if (!launch_debouncer) return;

  std::thread([cb_state]() {
    InFlightDecGuard dec{cb_state};
    for (;;) {
      std::unique_lock<std::mutex> lock(cb_state->mu);
      if (!cb_state->alive || !cb_state->radio_cb) {
        cb_state->radio_debounce_active = false;
        return;
      }
      const auto deadline = cb_state->radio_debounce_deadline;
      if (cb_state->cv.wait_until(
              lock, deadline, [cb_state, deadline]() {
                return !cb_state->alive || !cb_state->radio_cb ||
                       cb_state->radio_debounce_deadline != deadline;
              })) {
        continue;
      }
      if (!cb_state->alive || !cb_state->radio_cb) {
        cb_state->radio_debounce_active = false;
        return;
      }
      DaphqRadioStateCallback cb = cb_state->radio_cb;
      void* ud = cb_state->user_data;
      cb_state->radio_debounce_active = false;
      lock.unlock();

      const DaphqRadioCapabilities caps = ProbeWinRadioCapabilities(false);
      bool should_emit = true;
      {
        std::lock_guard<std::mutex> check_lock(cb_state->mu);
        if (!cb_state->alive || cb_state->radio_cb != cb) {
          return;
        }
        if (cb_state->has_last_radio_caps &&
            CapsEqual(cb_state->last_radio_caps, caps)) {
          should_emit = false;
        } else {
          cb_state->last_radio_caps = caps;
          cb_state->has_last_radio_caps = true;
        }
      }
      if (should_emit) {
        cb(caps, ud);
      }
      return;
    }
  }).detach();
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

void daphq_direct_set_radio_callback(
    void* handle,
    DaphqRadioStateCallback radio_cb) {
  if (!handle) return;
  auto* ctx = static_cast<DirectContext*>(handle);
  if (ctx->aborted.load()) return;

  {
    std::lock_guard<std::mutex> slock(ctx->state->mu);
    if (!ctx->state->alive) return;
    ctx->state->radio_cb = radio_cb;
  }

  std::shared_ptr<SharedCallbackState> cb_state = ctx->state;
  std::vector<std::pair<Radio, winrt::event_token>> new_tokens;
  winrt::event_token new_net_token{};
  bool got_net_token = false;

  ComMtaScope com;
  try {
    auto radios = Radio::GetRadiosAsync().get();
    for (uint32_t i = 0; i < radios.Size(); ++i) {
      auto r = radios.GetAt(i);
      if (r.Kind() == RadioKind::WiFi || r.Kind() == RadioKind::Bluetooth) {
        auto tok = r.StateChanged(
            [cb_state](Radio const&,
                       winrt::Windows::Foundation::IInspectable const&) {
              NotifyRadioStateChange(cb_state);
            });
        new_tokens.emplace_back(r, tok);
      }
    }
  } catch (...) {}

  try {
    new_net_token = NetworkInformation::NetworkStatusChanged(
        [cb_state](winrt::Windows::Foundation::IInspectable const&) {
          NotifyRadioStateChange(cb_state);
        });
    got_net_token = true;
  } catch (...) {}

  std::lock_guard<std::mutex> lock(ctx->handle_mu);
  for (auto& kv : ctx->radio_tokens) {
    try {
      kv.first.StateChanged(kv.second);
    } catch (...) {}
  }
  ctx->radio_tokens = std::move(new_tokens);
  if (ctx->has_net_status_token) {
    try {
      NetworkInformation::NetworkStatusChanged(ctx->net_status_token);
    } catch (...) {}
    ctx->has_net_status_token = false;
  }
  if (got_net_token) {
    ctx->net_status_token = new_net_token;
    ctx->has_net_status_token = true;
  }
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
    ctx->state->radio_cb = nullptr;
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
    ComMtaScope com;
    std::lock_guard<std::mutex> lock(ctx->handle_mu);
    for (auto& kv : ctx->radio_tokens) {
      try {
        kv.first.StateChanged(kv.second);
      } catch (...) {}
    }
    ctx->radio_tokens.clear();
    if (ctx->has_net_status_token) {
      try {
        NetworkInformation::NetworkStatusChanged(ctx->net_status_token);
      } catch (...) {}
      ctx->has_net_status_token = false;
    }
  }
  SetWindowsTransferPowerRequest(ctx, false);
  {
    std::unique_lock<std::mutex> lock(ctx->state->mu);
    ctx->state->cv.wait(
        lock, [ctx]() { return ctx->state->in_flight_callbacks == 0; });
  }
  delete ctx;
}

DaphqRadioCapabilities daphq_direct_get_capabilities(void* /*handle*/) {
  return ProbeWinRadioCapabilities(true);
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

DaphqDirectHostInfo daphq_direct_start_host(
    void* handle, int prefer_5ghz, const char* stable_tag) {
  DaphqDirectHostInfo info{};
  if (!handle) return info;
  ComMtaScope com;
  auto* ctx = static_cast<DirectContext*>(handle);
  if (ctx->aborted.load()) return info;

  daphq_direct_stop_session(handle);
  const uint64_t my_gen = ++ctx->session_generation;

  const std::string clean_tag = SanitizeStableDirectTag(stable_tag);
  const std::string suffix = clean_tag.size() >= 2
      ? clean_tag
      : RandomString("ABCDEFGHJKLMNPQRSTUVWXYZ23456789", 4);
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

        bool actual_5g = using_5g;
        try {
          const auto active_cfg = tethering.GetCurrentAccessPointConfiguration();
          const auto active_band = active_cfg.Band();
          if (active_band == TetheringWiFiBand::TwoPointFourGigahertz) {
            actual_5g = false;
          } else if (active_band == TetheringWiFiBand::FiveGigahertz) {
            actual_5g = true;
          }
        } catch (...) {}

        info.success = 1;
        std::snprintf(info.ssid, sizeof(info.ssid), "%s", ssid.c_str());
        std::snprintf(info.psk, sizeof(info.psk), "%s", psk.c_str());
        std::snprintf(
            info.host_ip,
            sizeof(info.host_ip),
            "%s",
            host_ip.empty() ? "192.168.137.1" : host_ip.c_str());
        int verified_freq = 0;
        if (!actual_5g) {
          verified_freq = 2437;
        }
        info.frequency_mhz = verified_freq;
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

    if (publisher.Status() != WiFiDirectAdvertisementPublisherStatus::Started) {
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
    info.frequency_mhz = 0;
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

  std::wstring prev_profile;
  if (QueryConnectedProfileInfo(wlan, iface_guid, &prev_profile)) {
    std::lock_guard<std::mutex> lock(ctx->handle_mu);
    if (ctx->session_generation.load() == my_gen) {
      ctx->prev_wifi_profile = prev_profile;
    }
  }

  const std::wstring wprofile_xml = BuildWpa2ProfileXml(ssid, psk);
  const std::wstring wprofile_name = Utf8ToWide(ssid);
  const bool is_persistent_dq =
      (ssid.rfind("DIRECT-DQ-", 0) == 0 && ssid.size() >= 15);
  std::wstring saved_profile;
  bool wrote_saved_temp_name = false;

  WLAN_CONNECTION_PARAMETERS params{};
  params.pDot11Ssid = nullptr;
  params.pDesiredBssidList = nullptr;
  params.dot11BssType = dot11_BSS_type_infrastructure;
  params.dwFlags = 0;

  DWORD conn_res = ERROR_INVALID_PARAMETER;
  if (is_persistent_dq) {
    DWORD reason_code = 0;
    const DWORD save_res = ::WlanSetProfile(
        wlan,
        &iface_guid,
        WLAN_PROFILE_USER,
        wprofile_xml.c_str(),
        nullptr,
        TRUE,
        nullptr,
        &reason_code);
    if (save_res == ERROR_SUCCESS) {
      params.wlanConnectionMode = wlan_connection_mode_profile;
      params.strProfile = wprofile_name.c_str();
      conn_res = ::WlanConnect(wlan, &iface_guid, &params, nullptr);
    }
  }

  if (conn_res != ERROR_SUCCESS) {
    params.wlanConnectionMode = wlan_connection_mode_temporary_profile;
    params.strProfile = wprofile_xml.c_str();
    conn_res = ::WlanConnect(wlan, &iface_guid, &params, nullptr);
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
        if (!prev_profile.empty()) {
          std::lock_guard<std::mutex> lock(ctx->handle_mu);
          if (ctx->session_generation.load() == my_gen) {
            ctx->prev_wifi_profile.clear();
          }
        }
        ::WlanCloseHandle(wlan, nullptr);
        return conn;
      }
      if (!is_persistent_dq) {
        saved_profile = wprofile_name;
        std::lock_guard<std::mutex> lock(ctx->handle_mu);
        if (ctx->session_generation.load() == my_gen) {
          ctx->saved_temp_profile_name = wprofile_name;
          wrote_saved_temp_name = true;
        }
      }
      params.wlanConnectionMode = wlan_connection_mode_profile;
      params.strProfile = wprofile_name.c_str();
      conn_res = ::WlanConnect(wlan, &iface_guid, &params, nullptr);
    }
  }

  if (conn_res != ERROR_SUCCESS) {
    const bool stopped_or_superseded =
        ctx->aborted.load() || ctx->session_generation.load() != my_gen;
    if (!saved_profile.empty() && (!stopped_or_superseded || !wrote_saved_temp_name)) {
      ::WlanDeleteProfile(wlan, &iface_guid, saved_profile.c_str(), nullptr);
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      if (ctx->saved_temp_profile_name == saved_profile) {
        ctx->saved_temp_profile_name.clear();
      }
    }
    if (!prev_profile.empty()) {
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      if (ctx->session_generation.load() == my_gen) {
        ctx->prev_wifi_profile.clear();
      }
    }
    ::WlanCloseHandle(wlan, nullptr);
    return conn;
  }

  bool aborted_before_wait = false;
  {
    std::lock_guard<std::mutex> lock(ctx->handle_mu);
    if (ctx->aborted.load() || ctx->session_generation.load() != my_gen) {
      aborted_before_wait = true;
    } else {
      ctx->active_wlan_guid = iface_guid;
      ctx->has_active_wlan_guid = true;
    }
  }
  if (aborted_before_wait) {
    if (!saved_profile.empty() && !wrote_saved_temp_name) {
      ::WlanDeleteProfile(wlan, &iface_guid, saved_profile.c_str(), nullptr);
    }
    ::WlanCloseHandle(wlan, nullptr);
    return conn;
  }

  DOT11_SSID target_ssid{};
  const size_t target_ssid_len =
      ssid.size() <= DOT11_SSID_MAX_LENGTH ? ssid.size() : DOT11_SSID_MAX_LENGTH;
  target_ssid.uSSIDLength = static_cast<ULONG>(target_ssid_len);
  if (target_ssid_len > 0) {
    std::memcpy(target_ssid.ucSSID, ssid.data(), target_ssid_len);
  }

  // Wait up to 12 seconds for actual SSID association + non-APIPA DHCP IPv4
  for (int i = 0; i < 48; ++i) {
    if (ctx->aborted.load() || ctx->session_generation.load() != my_gen) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    if (!IsWlanConnectedToSsid(wlan, &iface_guid, ssid)) {
      if (i == 4 || i == 20) {
        ::WlanScan(
            wlan,
            &iface_guid,
            target_ssid_len > 0 ? &target_ssid : nullptr,
            nullptr,
            nullptr);
        ::WlanConnect(wlan, &iface_guid, &params, nullptr);
      } else if (i == 12 || i == 28) {
        ::WlanConnect(wlan, &iface_guid, &params, nullptr);
      }
      continue;
    }
    std::string local_ip;
    std::string gw_ip = fallback_gw;
    if (QueryWifiInterfaceAddresses(&iface_guid, &local_ip, &gw_ip)) {
      SetWlanInterfacePerfMode(wlan, iface_guid, true);
      {
        std::lock_guard<std::mutex> lock(ctx->handle_mu);
        if (ctx->session_generation.load() == my_gen) {
          ctx->perf_tuned_guid = iface_guid;
          ctx->wlan_perf_tuned = true;
        }
      }
      conn.success = 1;
      conn.frequency_mhz = QueryConnectedChannelFrequencyMhz(wlan, iface_guid);
      std::snprintf(conn.local_ip, sizeof(conn.local_ip), "%s", local_ip.c_str());
      std::snprintf(conn.gateway_ip, sizeof(conn.gateway_ip), "%s", gw_ip.c_str());
      break;
    }
  }

  if (!conn.success) {
    const bool stopped_or_superseded =
        ctx->aborted.load() || ctx->session_generation.load() != my_gen;
    if (!stopped_or_superseded && IsWlanConnectedToSsid(wlan, &iface_guid, ssid)) {
      ::WlanDisconnect(wlan, &iface_guid, nullptr);
    }
    if (ctx->session_generation.load() == my_gen) {
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      if (ctx->session_generation.load() == my_gen) {
        ctx->has_active_wlan_guid = false;
        ctx->prev_wifi_profile.clear();
      }
    }
    if (!saved_profile.empty() && (!stopped_or_superseded || !wrote_saved_temp_name)) {
      ::WlanDeleteProfile(wlan, &iface_guid, saved_profile.c_str(), nullptr);
      std::lock_guard<std::mutex> lock(ctx->handle_mu);
      if (ctx->saved_temp_profile_name == saved_profile) {
        ctx->saved_temp_profile_name.clear();
      }
    }
    if (!stopped_or_superseded && !prev_profile.empty()) {
      WLAN_CONNECTION_PARAMETERS rec{};
      rec.wlanConnectionMode = wlan_connection_mode_profile;
      rec.strProfile = prev_profile.c_str();
      rec.pDot11Ssid = nullptr;
      rec.pDesiredBssidList = nullptr;
      rec.dot11BssType = dot11_BSS_type_infrastructure;
      rec.dwFlags = 0;
      ::WlanConnect(wlan, &iface_guid, &rec, nullptr);
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
  const uint64_t stop_gen = ++ctx->session_generation;

  std::wstring temp_profile;
  std::wstring reconnect_profile;
  GUID wlan_guid{};
  bool disconnect_wlan = false;
  GUID perf_guid{};
  bool restore_perf = false;

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
    reconnect_profile = std::move(ctx->prev_wifi_profile);
    ctx->prev_wifi_profile.clear();
    if (ctx->has_active_wlan_guid) {
      wlan_guid = ctx->active_wlan_guid;
      ctx->has_active_wlan_guid = false;
      disconnect_wlan = true;
    }
    if (ctx->wlan_perf_tuned) {
      perf_guid = ctx->perf_tuned_guid;
      ctx->wlan_perf_tuned = false;
      restore_perf = true;
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

  if (disconnect_wlan || !temp_profile.empty() || restore_perf) {
    HANDLE wlan = nullptr;
    DWORD negotiated = 0;
    if (::WlanOpenHandle(2, nullptr, &negotiated, &wlan) == ERROR_SUCCESS && wlan) {
      if (restore_perf) {
        SetWlanInterfacePerfMode(wlan, perf_guid, false);
      }
      if (disconnect_wlan) {
        ::WlanDisconnect(wlan, &wlan_guid, nullptr);
      }
      if (!temp_profile.empty()) {
        ::WlanDeleteProfile(wlan, &wlan_guid, temp_profile.c_str(), nullptr);
      }
      if (disconnect_wlan &&
          !reconnect_profile.empty() &&
          !ctx->aborted.load() &&
          ctx->session_generation.load() == stop_gen) {
        WLAN_CONNECTION_PARAMETERS rec{};
        rec.wlanConnectionMode = wlan_connection_mode_profile;
        rec.strProfile = reconnect_profile.c_str();
        rec.pDot11Ssid = nullptr;
        rec.pDesiredBssidList = nullptr;
        rec.dot11BssType = dot11_BSS_type_infrastructure;
        rec.dwFlags = 0;
        ::WlanConnect(wlan, &wlan_guid, &rec, nullptr);
      }
      ::WlanCloseHandle(wlan, nullptr);
    }
  }
}

int daphq_direct_get_host_client_ips(
    void* handle,
    char* out_ips_csv,
    int out_capacity) {
  if (!handle || !out_ips_csv || out_capacity <= 1) return 0;
  out_ips_csv[0] = '\0';
  ComMtaScope com;
  auto* ctx = static_cast<DirectContext*>(handle);
  if (ctx->aborted.load()) return 0;

  NetworkOperatorTetheringManager tethering{nullptr};
  {
    std::lock_guard<std::mutex> lock(ctx->handle_mu);
    tethering = ctx->tethering_mgr;
  }

  std::vector<std::string> ips;
  auto append_unique_ip = [&ips](const std::string& ip) {
    if (ip.empty() || ip == "0.0.0.0" || ip.rfind("127.", 0) == 0 ||
        ip.rfind("169.254.", 0) == 0) {
      return;
    }
    if (std::find(ips.begin(), ips.end(), ip) == ips.end()) {
      ips.push_back(ip);
    }
  };

  const std::string soft_ap_ip = FindSoftApHostIp();
  const std::string host_ip = soft_ap_ip.empty() ? "192.168.137.1" : soft_ap_ip;
  std::string subnet_prefix;
  const size_t last_dot = host_ip.rfind('.');
  if (last_dot != std::string::npos) {
    subnet_prefix = host_ip.substr(0, last_dot + 1);
  }

  if (tethering) {
    try {
      const auto clients = tethering.GetTetheringClients();
      for (auto const& client : clients) {
        const auto host_names = client.HostNames();
        for (auto const& hn : host_names) {
          if (hn.Type() == winrt::Windows::Networking::HostNameType::Ipv4) {
            const std::string ip = winrt::to_string(hn.CanonicalName());
            if (ip != host_ip) {
              append_unique_ip(ip);
            }
          }
        }
      }
    } catch (...) {}
  }

  // Supplement WinRT tethering clients with active dynamic ARP neighbors on the
  // SoftAP /24 subnet so DHCP clients are discovered immediately.
  if (!subnet_prefix.empty()) {
    ULONG buf_bytes = 0;
    if (::GetIpNetTable(nullptr, &buf_bytes, FALSE) == ERROR_INSUFFICIENT_BUFFER &&
        buf_bytes > 0) {
      std::vector<uint8_t> table_buf(buf_bytes);
      auto* table = reinterpret_cast<MIB_IPNETTABLE*>(table_buf.data());
      if (::GetIpNetTable(table, &buf_bytes, FALSE) == NO_ERROR) {
        for (DWORD i = 0; i < table->dwNumEntries; ++i) {
          const MIB_IPNETROW& row = table->table[i];
          if (row.dwType != MIB_IPNET_TYPE_DYNAMIC || row.dwPhysAddrLen != 6) {
            continue;
          }
          struct in_addr in {};
          in.s_addr = row.dwAddr;
          char ip_buf[INET_ADDRSTRLEN]{};
          if (::inet_ntop(AF_INET, &in, ip_buf, sizeof(ip_buf)) == nullptr) {
            continue;
          }
          const std::string ip(ip_buf);
          if (ip != host_ip &&
              ip.rfind(subnet_prefix, 0) == 0 &&
              ip != (subnet_prefix + "255")) {
            append_unique_ip(ip);
          }
        }
      }
    }
  }

  std::string joined;
  for (size_t i = 0; i < ips.size(); ++i) {
    if (i > 0) joined.push_back(',');
    joined += ips[i];
  }
  const size_t max_copy = static_cast<size_t>(out_capacity - 1);
  const size_t n = (std::min)(joined.size(), max_copy);
  if (n > 0) {
    std::memcpy(out_ips_csv, joined.data(), n);
  }
  out_ips_csv[n] = '\0';
  return static_cast<int>(ips.size());
}

void daphq_direct_set_transfer_power_lock(void* handle, int enabled) {
  if (!handle) return;
  ComMtaScope com;
  auto* ctx = static_cast<DirectContext*>(handle);
  const bool want_enable = (enabled != 0) && !ctx->aborted.load();
  SetWindowsTransferPowerRequest(ctx, want_enable);

  GUID target_guid{};
  bool have_guid = false;
  bool should_restore = false;
  {
    std::lock_guard<std::mutex> lock(ctx->handle_mu);
    if (!want_enable) {
      if (ctx->wlan_perf_tuned) {
        target_guid = ctx->perf_tuned_guid;
        have_guid = true;
        should_restore = true;
        ctx->wlan_perf_tuned = false;
      }
    } else if (ctx->has_active_wlan_guid) {
      target_guid = ctx->active_wlan_guid;
      have_guid = true;
    }
  }

  HANDLE wlan = nullptr;
  DWORD negotiated = 0;
  if (::WlanOpenHandle(2, nullptr, &negotiated, &wlan) == ERROR_SUCCESS && wlan) {
    if (want_enable) {
      if (have_guid || SelectBestWlanInterface(wlan, &target_guid, nullptr)) {
        SetWlanInterfacePerfMode(wlan, target_guid, true);
        std::lock_guard<std::mutex> lock(ctx->handle_mu);
        ctx->perf_tuned_guid = target_guid;
        ctx->wlan_perf_tuned = true;
      }
    } else if (should_restore && have_guid) {
      SetWlanInterfacePerfMode(wlan, target_guid, false);
    }
    ::WlanCloseHandle(wlan, nullptr);
  }
}

}  // extern "C"
