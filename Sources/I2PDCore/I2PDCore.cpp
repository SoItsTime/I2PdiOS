#include "I2PDCore.h"

#include "api.h"
#include "ClientContext.h"
#include "Config.h"
#include "HTTPServer.h"
#include "I18N.h"
#include "FS.h"
#include "NetDb.hpp"
#include "RouterContext.h"
#include "Transports.h"
#include "Tunnel.h"
#include "version.h"

#include <algorithm>
#include <cstring>
#include <exception>
#include <limits>
#include <mutex>
#include <memory>
#include <string>
#include <vector>

namespace {
std::mutex routerMutex;
bool initialized = false;
bool running = false;
std::unique_ptr<i2p::http::HTTPServer> webConsole;

void setError(char *buffer, int capacity, const char *message) {
    if (!buffer || capacity <= 0) return;
    const auto count = std::min(static_cast<size_t>(capacity - 1), std::strlen(message));
    std::memcpy(buffer, message, count);
    buffer[count] = '\0';
}

template <size_t N>
void copyText(char (&buffer)[N], const std::string& value) {
    const auto count = std::min(N - 1, value.size());
    std::memcpy(buffer, value.data(), count);
    buffer[count] = '\0';
}

void appendJSONString(std::string& json, const std::string& value) {
    static constexpr char hex[] = "0123456789abcdef";
    json.push_back('"');
    for (unsigned char c : value) {
        switch (c) {
            case '"': json += "\\\""; break;
            case '\\': json += "\\\\"; break;
            case '\n': json += "\\n"; break;
            case '\r': json += "\\r"; break;
            case '\t': json += "\\t"; break;
            default:
                if (c < 0x20) {
                    json += "\\u00";
                    json.push_back(hex[c >> 4]);
                    json.push_back(hex[c & 0x0f]);
                } else {
                    json.push_back(static_cast<char>(c));
                }
        }
    }
    json.push_back('"');
}
}

int i2pd_start_router(const char *data_dir, char *error, int error_capacity) {
    std::lock_guard<std::mutex> lock(routerMutex);
    if (running) return 1;
    if (!data_dir || !data_dir[0]) {
        setError(error, error_capacity, "Missing router data directory");
        return 0;
    }

    try {
        if (!initialized) {
            std::vector<std::string> arguments {
                "i2pd",
                std::string("--datadir=") + data_dir,
                "--reseed.verify=true",
                "--persist.addressbook=true",
                "--persist.profiles=true",
                "--persist.netdbinterval=60",
                "--addressbook.subscriptions=http://shx5vqsw7usdaunyzr2qmes2fq37oumybpudrd4jjj4e4vk4uusa.b32.i2p/hosts.txt,http://nytzrhrjjfsutowojvxi7hphesskpqqr65wpistz6wa7cpajhp7a.b32.i2p/hosts.txt",
                "--http.enabled=true",
                "--http.address=127.0.0.1",
                "--http.port=7070",
                "--http.javascript=true",
                "--httpproxy.enabled=true",
                "--httpproxy.address=127.0.0.1",
                "--httpproxy.port=4444",
                "--socksproxy.enabled=true",
                "--socksproxy.address=127.0.0.1",
                "--socksproxy.port=4447",
                "--sam.enabled=false",
                "--bob.enabled=false",
                "--i2cp.enabled=false",
                "--i2pcontrol.enabled=false",
                "--upnp.enabled=false",
                "--ntcp2.published=false",
                "--ssu2.published=true"
            };
            std::vector<char *> argv;
            argv.reserve(arguments.size());
            for (auto &argument : arguments) argv.push_back(argument.data());
            i2p::api::InitI2P(static_cast<int>(argv.size()), argv.data(), "I2PdiOS");
            // The embedded API does not set this the way the standalone daemon does.
            // Without it, reseed and family certificates are sought at /reseed and /family.
            i2p::fs::SetCertsDir(std::string(data_dir) + "/certificates");
            // The standalone daemon initializes the web console locale after
            // parsing http.lang. The embedded API does not do that for us.
            std::string consoleLanguage = "english";
            i2p::config::GetOption("http.lang", consoleLanguage);
            i2p::i18n::SetLanguage(consoleLanguage);
            initialized = true;
        }

        // The embedded API parses bandwidth/share options but, unlike the
        // standalone daemon, does not apply them to RouterContext. Without a
        // bandwidth limit, i2pd treats transit as fully congested and rejects
        // every build request. Use the daemon's low-bandwidth profile and a
        // bounded number of transit tunnels for this mobile router.
        i2p::context.SetBandwidth('L'); // 48 KiB/s
        i2p::context.SetShareRatio(100);
        i2p::tunnel::tunnels.SetMaxNumTransitTunnels(64);
        i2p::context.SetAcceptsTunnels(true);
        i2p::api::StartI2P();
        try {
            i2p::client::context.Start();
            webConsole = std::make_unique<i2p::http::HTTPServer>("127.0.0.1", 7070);
            webConsole->Start();
        } catch (...) {
            if (webConsole) {
                webConsole->Stop();
                webConsole.reset();
            }
            i2p::client::context.Stop();
            i2p::api::StopI2P();
            throw;
        }
        running = true;
        return 1;
    } catch (const std::exception &exception) {
        setError(error, error_capacity, exception.what());
    } catch (...) {
        setError(error, error_capacity, "Unknown i2pd startup error");
    }
    return 0;
}

void i2pd_stop_router(void) {
    std::lock_guard<std::mutex> lock(routerMutex);
    if (!running) return;
    if (webConsole) {
        webConsole->Stop();
        webConsole.reset();
    }
    i2p::client::context.Stop();
    i2p::api::StopI2P();
    running = false;
}

int i2pd_begin_graceful_shutdown(void) {
    std::lock_guard<std::mutex> lock(routerMutex);
    if (!running) return 0;
    // Matches i2pd's SIGINT graceful-shutdown first step. Transit tunnels
    // that already exist continue until the app completes shutdown.
    i2p::context.SetAcceptsTunnels(false);
    return 1;
}

int i2pd_is_running(void) {
    std::lock_guard<std::mutex> lock(routerMutex);
    return running ? 1 : 0;
}

int i2pd_get_status(I2PDStatusSnapshot *out) {
    if (!out) return 0;
    std::unique_lock<std::mutex> lock(routerMutex, std::try_to_lock);
    if (!lock.owns_lock() || !running) return 0;

    std::memset(out, 0, sizeof(*out));
    out->uptime_seconds = i2p::context.GetUptime();
    out->network_status = static_cast<int32_t>(i2p::context.GetStatus());
    out->known_routers = i2p::data::netdb.GetNumRouters();
    out->known_floodfills = i2p::data::netdb.GetNumFloodfills();
    out->is_floodfill = i2p::context.IsFloodfill() ? 1 : 0;
    out->known_lease_sets = i2p::data::netdb.GetNumLeaseSets();
    out->known_addresses = i2p::client::context.GetAddressBook().GetNumAddresses();
    out->addressbook_syncing = i2p::client::context.GetAddressBook().IsSubscriptionDownloading() ? 1 : 0;
    out->addressbook_failures = i2p::client::context.GetAddressBook().GetSubscriptionFailures();
    out->last_addressbook_sync_epoch = i2p::client::context.GetAddressBook().GetLastSuccessfulDownload();
    copyText(out->addressbook_last_error,
             i2p::client::context.GetAddressBook().GetLastSubscriptionError());
    out->connected_peers = i2p::transport::transports.GetNumPeers();
    out->inbound_tunnels = i2p::tunnel::tunnels.CountInboundTunnels();
    out->outbound_tunnels = i2p::tunnel::tunnels.CountOutboundTunnels();
    out->transit_tunnels = i2p::tunnel::tunnels.CountTransitTunnels();
    out->accepts_transit_tunnels = i2p::context.AcceptsTunnels() ? 1 : 0;
    out->transit_bandwidth_limit_kib = static_cast<uint32_t>(i2p::context.GetTransitBandwidthLimit());
    out->max_transit_tunnels = i2p::tunnel::tunnels.GetMaxNumTransitTunnels();
    out->transit_contact_route = i2p::context.GetRouterInfo().IsReachableBy(i2p::data::RouterInfo::eAllTransports) ? 1 : 0;
    out->tunnel_success_percent = i2p::tunnel::tunnels.GetTunnelCreationSuccessRate();
    out->received_bytes = i2p::transport::transports.GetTotalReceivedBytes();
    out->sent_bytes = i2p::transport::transports.GetTotalSentBytes();
    out->receive_bytes_per_second = i2p::transport::transports.GetInBandwidth15s();
    out->send_bytes_per_second = i2p::transport::transports.GetOutBandwidth15s();
    out->http_proxy_ready = i2p::client::context.GetHttpProxy() ? 1 : 0;
    if (auto proxy = i2p::client::context.GetSocksProxy()) {
        out->socks_proxy_ready = 1;
        auto destination = proxy->GetLocalDestination();
        out->socks_destination_ready = destination && destination->IsReady() ? 1 : 0;
    }
    out->network_status_v6 = static_cast<int32_t>(i2p::context.GetStatusV6());
    out->supports_v6 = i2p::context.SupportsV6() ? 1 : 0;
    out->network_testing = i2p::context.GetTesting() ? 1 : 0;
    out->network_testing_v6 = i2p::context.GetTestingV6() ? 1 : 0;
    out->network_error = static_cast<int32_t>(i2p::context.GetError());
    out->network_error_v6 = static_cast<int32_t>(i2p::context.GetErrorV6());
    out->total_tunnel_success_percent = i2p::tunnel::tunnels.GetTotalTunnelCreationSuccessRate();
    out->tunnel_queue_size = i2p::tunnel::tunnels.GetQueueSize();
    out->tunnel_build_queue_size = i2p::tunnel::tunnels.GetTBMQueueSize();
    out->transit_bytes = i2p::transport::transports.GetTotalTransitTransmittedBytes();
    out->transit_bytes_per_second = i2p::transport::transports.GetTransitBandwidth15s();
    copyText(out->router_identity, i2p::context.GetRouterInfo().GetIdentHashBase64());
    copyText(out->router_caps, i2p::context.GetRouterInfo().GetProperty("caps"));
    copyText(out->router_family, i2p::context.GetFamily());
    copyText(out->i2pd_version, VERSION);
    if (auto proxy = i2p::client::context.GetHttpProxy(); proxy && proxy->GetLocalDestination())
        copyText(out->http_proxy_destination,
                 proxy->GetLocalDestination()->GetIdentHash().ToBase32() + ".b32.i2p");
    if (auto proxy = i2p::client::context.GetSocksProxy(); proxy && proxy->GetLocalDestination())
        copyText(out->socks_proxy_destination,
                 proxy->GetLocalDestination()->GetIdentHash().ToBase32() + ".b32.i2p");
    return 1;
}

int32_t i2pd_copy_address_book_json(char *buffer, int32_t capacity) {
    std::unique_lock<std::mutex> lock(routerMutex, std::try_to_lock);
    if (!lock.owns_lock() || !running) return -1;
    auto entries = i2p::client::context.GetAddressBook().GetAddressesSnapshot();
    lock.unlock();

    std::string json = "[";
    for (const auto& entry : entries) {
        if (json.size() > 1) json.push_back(',');
        json += "{\"name\":";
        appendJSONString(json, entry.first);
        json += ",\"destination\":";
        appendJSONString(json, entry.second);
        json.push_back('}');
    }
    json.push_back(']');
    if (json.size() >= static_cast<size_t>(std::numeric_limits<int32_t>::max())) return -1;
    const auto required = static_cast<int32_t>(json.size() + 1);
    if (!buffer || capacity < required) return required;
    std::memcpy(buffer, json.data(), json.size());
    buffer[json.size()] = '\0';
    return static_cast<int32_t>(json.size());
}
