#include "I2PDCore.h"

#include "api.h"
#include "ClientContext.h"
#include "Config.h"
#include "HTTPServer.h"
#include "HTTP.h"
#include "I18N.h"
#include "FS.h"
#include "NetDb.hpp"
#include "RouterContext.h"
#include "Transports.h"
#include "Tunnel.h"
#include "version.h"
#include "TorrentsTunnel.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <exception>
#include <limits>
#include <mutex>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <boost/asio/post.hpp>
#include <boost/asio/use_future.hpp>

namespace {
std::mutex routerMutex;
bool initialized = false;
bool running = false;
std::string defaultReseedURLs, defaultReseedFile;
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

bool normalizeOutproxyURL(const char *input, std::string& normalized) {
    normalized.clear();
    if (!input || !input[0]) return true;
    const std::string value(input);
    if (value.size() > 512 || !value.starts_with("http://")) return false;
    auto authority = value.substr(7);
    if (authority.ends_with('/')) authority.pop_back();
    if (authority.empty() || authority.find_first_of("/?#@\\ \t\r\n") != std::string::npos)
        return false;
    const auto colon = authority.find(':');
    if (colon != std::string::npos && authority.find(':', colon + 1) != std::string::npos)
        return false;
    auto host = authority.substr(0, colon);
    std::transform(host.begin(), host.end(), host.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (host.size() <= 4 || !host.ends_with(".i2p") || host.front() == '.' ||
        host.find("..") != std::string::npos ||
        !std::all_of(host.begin(), host.end(), [](unsigned char c) {
            return std::isalnum(c) || c == '-' || c == '.';
        })) return false;
    normalized = "http://" + host;
    if (colon != std::string::npos) {
        const auto port = authority.substr(colon + 1);
        if (port.empty() || port.size() > 5 ||
            !std::all_of(port.begin(), port.end(), [](unsigned char c) { return std::isdigit(c); }))
            return false;
        const auto number = std::stoi(port);
        if (number == 0 || number > 65535) return false;
        normalized += ":" + std::to_string(number);
    }
    return true;
}

bool normalizeReseedURL(const char *input, std::string& normalized, bool& isFile) {
    normalized.clear();
    isFile = false;
    if (!input || !input[0]) return true;
    std::string value(input);
    if (value.size() > 2048 || !value.starts_with("https://") ||
        value.find_first_of(",@?#\\ \t\r\n") != std::string::npos ||
        std::any_of(value.begin(), value.end(), [](unsigned char c) { return c < 0x20 || c == 0x7f; }))
        return false;
    i2p::http::URL parsed;
    if (!parsed.parse(value) || parsed.schema != "https" || parsed.host.empty() ||
        !parsed.user.empty() || !parsed.pass.empty() || parsed.hasquery || !parsed.frag.empty())
        return false;
    isFile = value.size() >= 4 && value.substr(value.size() - 4) == ".su3";
    if (!isFile && value.back() != '/') value.push_back('/');
    normalized = std::move(value);
    return true;
}

std::shared_ptr<i2p::torrents::TorrentsTunnel> torrentTunnel() {
    if (!running) return {};
    const auto& tunnels = i2p::client::context.GetTorrentsTunnels();
    for (const auto& item : tunnels)
        if (std::string_view(item.second->GetName()) == "iOS Torrents") return item.second;
    return {};
}

void appendJSONNumber(std::string& json, uint64_t value) {
    json += std::to_string(value);
}
}

int32_t i2pd_copy_torrents_json(char *buffer, int32_t capacity) {
    std::lock_guard<std::mutex> lock(routerMutex);
    auto tunnel = torrentTunnel();
    if (!tunnel) return -1;
    try {
        auto result = boost::asio::post(tunnel->GetService(), boost::asio::use_future([tunnel] {
            std::string json = "[";
            bool first = true;
            for (int id : tunnel->GetTorrentIDs()) {
                auto torrent = tunnel->FindTorrentByID(id);
                if (!torrent) continue;
                if (!first) json.push_back(',');
                first = false;
                json += "{\"id\":";
                appendJSONNumber(json, id);
                json += ",\"name\":";
                appendJSONString(json, std::string(torrent->GetName()));
                json += ",\"status\":";
                appendJSONNumber(json, torrent->GetStatus());
                json += ",\"totalBytes\":";
                appendJSONNumber(json, torrent->GetLength());
                json += ",\"leftBytes\":";
                appendJSONNumber(json, torrent->GetLeft());
                json += ",\"downloadRate\":";
                appendJSONNumber(json, torrent->GetDownloadRate());
                json += ",\"uploadRate\":";
                appendJSONNumber(json, torrent->GetUploadRate());
                json += ",\"error\":";
                appendJSONString(json, std::string(torrent->GetErrorStr()));
                json.push_back('}');
            }
            json.push_back(']');
            return json;
        })).get();
        if (result.size() > static_cast<size_t>(std::numeric_limits<int32_t>::max())) return -1;
        if (buffer && capacity > 0 && static_cast<size_t>(capacity) >= result.size())
            std::memcpy(buffer, result.data(), result.size());
        return static_cast<int32_t>(result.size());
    } catch (...) { return -1; }
}

int i2pd_add_magnet(const char *magnet, char *error, int error_capacity) {
    std::lock_guard<std::mutex> lock(routerMutex);
    auto tunnel = torrentTunnel();
    if (!tunnel) { setError(error, error_capacity, "Torrent tunnel is not running"); return 0; }
    if (!magnet || std::strlen(magnet) > 8192 || !std::string_view(magnet).starts_with("magnet:?")) {
        setError(error, error_capacity, "Enter a valid I2P magnet link"); return 0;
    }
    try {
        std::string value(magnet);
        auto added = boost::asio::post(tunnel->GetService(), boost::asio::use_future([tunnel, value] {
            auto [torrent, id] = tunnel->AddMagnet(value);
            return id > 0 && torrent && !torrent->GetError();
        })).get();
        if (added) return 1;
        setError(error, error_capacity, "i2pd could not add this magnet link");
    } catch (const std::exception& e) { setError(error, error_capacity, e.what()); }
    return 0;
}

int i2pd_add_torrent_file(const uint8_t *bytes, int32_t length, char *error, int error_capacity) {
    std::lock_guard<std::mutex> lock(routerMutex);
    auto tunnel = torrentTunnel();
    if (!tunnel) { setError(error, error_capacity, "Torrent tunnel is not running"); return 0; }
    if (!bytes || length <= 0 || length > 8 * 1024 * 1024) {
        setError(error, error_capacity, "Torrent file must be under 8 MB"); return 0;
    }
    try {
        std::string value(reinterpret_cast<const char *>(bytes), length);
        auto added = boost::asio::post(tunnel->GetService(), boost::asio::use_future([tunnel, value = std::move(value)] {
            auto [torrent, id] = tunnel->AddTorrent(value);
            return id > 0 && torrent && !torrent->GetError();
        })).get();
        if (added) return 1;
        setError(error, error_capacity, "i2pd rejected this torrent file");
    } catch (const std::exception& e) { setError(error, error_capacity, e.what()); }
    return 0;
}

int i2pd_torrent_action(int32_t id, int32_t action, char *error, int error_capacity) {
    std::lock_guard<std::mutex> lock(routerMutex);
    auto tunnel = torrentTunnel();
    if (!tunnel) { setError(error, error_capacity, "Torrent tunnel is not running"); return 0; }
    if (id <= 0 || action < 0 || action > 3) {
        setError(error, error_capacity, "Invalid torrent action"); return 0;
    }
    bool succeeded = action == 0 ? tunnel->StopTorrent(id) :
                     action == 1 ? tunnel->StartTorrent(id) :
                     tunnel->RemoveTorrent(id, action == 3);
    if (!succeeded) setError(error, error_capacity, "Torrent is no longer available");
    return succeeded ? 1 : 0;
}

int i2pd_start_router(const char *data_dir, const char *outproxy_url,
                      const char *reseed_url, char *error, int error_capacity) {
    std::lock_guard<std::mutex> lock(routerMutex);
    if (running) return 1;
    if (!data_dir || !data_dir[0]) {
        setError(error, error_capacity, "Missing router data directory");
        return 0;
    }

    std::string outproxy;
    if (!normalizeOutproxyURL(outproxy_url, outproxy)) {
        setError(error, error_capacity, "Outproxy must be an http:// address ending in .i2p, with an optional port");
        return 0;
    }

    std::string reseed;
    bool reseedIsFile = false;
    if (!normalizeReseedURL(reseed_url, reseed, reseedIsFile)) {
        setError(error, error_capacity, "Reseed URL must be an HTTPS server base URL or .su3 file URL");
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
                "--httpproxy.senduseragent=true",
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
            if (!outproxy.empty())
                arguments.push_back("--httpproxy.outproxy=" + outproxy);
            std::vector<char *> argv;
            argv.reserve(arguments.size());
            for (auto &argument : arguments) argv.push_back(argument.data());
            i2p::api::InitI2P(static_cast<int>(argv.size()), argv.data(), "I2PdiOS");
            i2p::config::GetOption("reseed.urls", defaultReseedURLs);
            i2p::config::GetOption("reseed.file", defaultReseedFile);
            // The embedded API does not set this the way the standalone daemon does.
            // Without it, reseed and family certificates are sought at /reseed and /family.
            i2p::fs::SetCertsDir(std::string(data_dir) + "/certificates");
            // The standalone daemon initializes the web console locale after
            // parsing http.lang. The embedded API does not do that for us.
            std::string consoleLanguage = "english";
            i2p::config::GetOption("http.lang", consoleLanguage);
            i2p::i18n::SetLanguage(consoleLanguage);
            initialized = true;
        } else if (!i2p::config::SetOption("httpproxy.outproxy", outproxy)) {
            setError(error, error_capacity, "Could not configure HTTP outproxy");
            return 0;
        }

        // Configure both forms before StartI2P starts netDb and its reseeder.
        // Restore i2pd's original values when the user clears the custom URL.
        const std::string activeReseedURLs = reseed.empty() || reseedIsFile ? defaultReseedURLs : reseed;
        const std::string activeReseedFile = reseedIsFile ? reseed :
            (reseed.empty() ? defaultReseedFile : std::string());
        if (!i2p::config::SetOption("reseed.urls", activeReseedURLs) ||
            !i2p::config::SetOption("reseed.file", activeReseedFile)) {
            setError(error, error_capacity, "Could not configure reseed URL");
            return 0;
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

int i2pd_set_outproxy(const char *outproxy_url, char *error, int error_capacity) {
    std::lock_guard<std::mutex> lock(routerMutex);
    if (!running) {
        setError(error, error_capacity, "Router is not running");
        return 0;
    }
    std::string outproxy;
    if (!normalizeOutproxyURL(outproxy_url, outproxy)) {
        setError(error, error_capacity, "Outproxy must be an http:// address ending in .i2p, with an optional port");
        return 0;
    }
    std::string previous;
    i2p::config::GetOption("httpproxy.outproxy", previous);
    if (previous == outproxy) return 1;
    try {
        if (!i2p::config::SetOption("httpproxy.outproxy", outproxy))
            throw std::runtime_error("Could not configure HTTP outproxy");
        i2p::client::context.ReloadConfig();
        return 1;
    } catch (const std::exception &exception) {
        i2p::config::SetOption("httpproxy.outproxy", previous);
        try { i2p::client::context.ReloadConfig(); } catch (...) {}
        setError(error, error_capacity, exception.what());
    } catch (...) {
        i2p::config::SetOption("httpproxy.outproxy", previous);
        try { i2p::client::context.ReloadConfig(); } catch (...) {}
        setError(error, error_capacity, "Could not apply HTTP outproxy");
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
    if (auto proxy = i2p::client::context.GetHttpProxy()) {
        out->http_proxy_ready = 1;
        auto destination = proxy->GetLocalDestination();
        out->http_destination_ready = destination && destination->IsReady() ? 1 : 0;
    }
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
