#ifndef DAPHQ_DIRECT_WIN_H_
#define DAPHQ_DIRECT_WIN_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DaphqRadioCapabilities {
  int has_wifi;
  int has_ble;
  int can_host_direct_5g;
} DaphqRadioCapabilities;

typedef struct DaphqDirectHostInfo {
  int success;
  char ssid[64];
  char psk[96];
  char host_ip[64];
  int frequency_mhz;
} DaphqDirectHostInfo;

typedef struct DaphqDirectClientConn {
  int success;
  char local_ip[64];
  char gateway_ip[64];
} DaphqDirectClientConn;

typedef void (*DaphqBleBeaconCallback)(
    const char* ble_address,
    const char* device_name,
    int rssi,
    const uint8_t* payload,
    int payload_len,
    void* user_data);

typedef void (*DaphqGattRequestCallback)(
    const char* json_payload,
    void* user_data);

void* daphq_direct_create(
    DaphqBleBeaconCallback beacon_cb,
    DaphqGattRequestCallback gatt_cb,
    void* user_data);

void daphq_direct_destroy(void* handle);

DaphqRadioCapabilities daphq_direct_get_capabilities(void* handle);

int daphq_direct_start_ble_discovery(
    void* handle,
    uint16_t manufacturer_id,
    const uint8_t* beacon_payload,
    int beacon_len,
    const char* info_json);

void daphq_direct_stop_ble_discovery(void* handle);

DaphqDirectHostInfo daphq_direct_start_host(void* handle, int prefer_5ghz);

DaphqDirectClientConn daphq_direct_connect_client(
    void* handle,
    const char* ssid,
    const char* psk,
    const char* expected_gateway_ip);

int daphq_direct_exchange_gatt_link(
    void* handle,
    const char* ble_address,
    const char* request_json,
    char* out_response_json,
    int out_capacity);

void daphq_direct_stop_session(void* handle);

void daphq_direct_request_abort(void* handle);

#ifdef __cplusplus
}
#endif

#endif  // DAPHQ_DIRECT_WIN_H_
