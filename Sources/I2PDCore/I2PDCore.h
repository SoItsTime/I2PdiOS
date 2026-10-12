#ifndef I2PD_CORE_H
#define I2PD_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns 1 on success, 0 on failure. Error is a UTF-8, NUL-terminated string.
int i2pd_start_router(const char *data_dir, char *error, int error_capacity);
// Stops accepting new transit tunnels while keeping existing connections alive.
int i2pd_begin_graceful_shutdown(void);
void i2pd_stop_router(void);
int i2pd_is_running(void);

typedef struct I2PDStatusSnapshot {
    uint32_t uptime_seconds;
    int32_t network_status;
    uint32_t known_routers;
    uint32_t known_floodfills;
    int32_t is_floodfill;
    uint32_t known_lease_sets;
    uint32_t known_addresses;
    int32_t addressbook_syncing;
    uint32_t addressbook_failures;
    uint64_t last_addressbook_sync_epoch;
    uint32_t connected_peers;
    uint32_t inbound_tunnels;
    uint32_t outbound_tunnels;
    uint32_t transit_tunnels;
    int32_t accepts_transit_tunnels;
    uint32_t transit_bandwidth_limit_kib;
    uint32_t max_transit_tunnels;
    int32_t transit_contact_route;
    int32_t tunnel_success_percent;
    uint64_t received_bytes;
    uint64_t sent_bytes;
    uint32_t receive_bytes_per_second;
    uint32_t send_bytes_per_second;
    int32_t http_proxy_ready;
    int32_t socks_proxy_ready;
    int32_t socks_destination_ready;
    int32_t network_status_v6;
    int32_t supports_v6;
    int32_t network_testing;
    int32_t network_testing_v6;
    int32_t network_error;
    int32_t network_error_v6;
    int32_t total_tunnel_success_percent;
    uint32_t tunnel_queue_size;
    uint32_t tunnel_build_queue_size;
    uint64_t transit_bytes;
    uint32_t transit_bytes_per_second;
    char router_identity[64];
    char router_caps[64];
    char router_family[128];
    char i2pd_version[24];
    char http_proxy_destination[64];
    char socks_proxy_destination[64];
    char addressbook_last_error[256];
} I2PDStatusSnapshot;

// Returns 1 when a live snapshot is available, 0 while stopped or starting.
int i2pd_get_status(I2PDStatusSnapshot *out);

// Returns UTF-8 JSON bytes (without a trailing NUL) or the required capacity.
// Returns -1 when the live address book is unavailable.
int32_t i2pd_copy_address_book_json(char *buffer, int32_t capacity);

#ifdef __cplusplus
}
#endif

#endif
