#include "signaling.h"
#include "pipeline.h"
#include <gst/gst.h>
#include <cstdio>
#include <cstdlib>
#include <csignal>
#include <string>
#include <fstream>
#include <sstream>
#include <map>
#include <vector>
#include <unistd.h>

static GMainLoop* main_loop = nullptr;

static void signal_handler(int sig) {
    printf("\nSignal %d received, shutting down...\n", sig);
    if (main_loop)
        g_main_loop_quit(main_loop);
}

// Parse simple key=value config file
static std::map<std::string, std::string> read_config(const std::string& path) {
    std::map<std::string, std::string> config;
    std::ifstream f(path);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        auto key = line.substr(0, eq);
        auto val = line.substr(eq + 1);
        while (!key.empty() && key.back() == ' ') key.pop_back();
        while (!val.empty() && val.front() == ' ') val.erase(val.begin());
        config[key] = val;
    }
    return config;
}

// Ensure boot partition is mounted
static void ensure_boot_mounted() {
    // Check if already mounted
    std::ifstream mounts("/proc/mounts");
    std::string line;
    while (std::getline(mounts, line)) {
        if (line.find("/boot/firmware") != std::string::npos) return;
    }
    // Try to mount it
    printf("Mounting /boot/firmware...\n");
    system("mount /boot/firmware 2>/dev/null || true");
}

// Find and read config from boot partition
static std::map<std::string, std::string> find_config() {
    ensure_boot_mounted();
    const char* paths[] = {
        "/boot/firmware/sharescreen.conf",
        "/boot/sharescreen.conf",
        "/etc/sharescreen.conf",
        nullptr
    };
    for (int i = 0; paths[i]; i++) {
        auto config = read_config(paths[i]);
        if (!config.empty()) {
            printf("Config loaded from %s\n", paths[i]);
            return config;
        }
    }
    return {};
}

// Read Pi CPU serial from /proc/cpuinfo
static std::string get_cpu_serial() {
    std::ifstream f("/proc/cpuinfo");
    std::string line;
    while (std::getline(f, line)) {
        if (line.find("Serial") != std::string::npos) {
            auto pos = line.find(':');
            if (pos != std::string::npos) {
                auto serial = line.substr(pos + 1);
                // Trim whitespace
                while (!serial.empty() && serial.front() == ' ') serial.erase(serial.begin());
                while (!serial.empty() && serial.back() == ' ') serial.pop_back();
                return serial;
            }
        }
    }
    return "unknown";
}

// Check if device ID is in the public license list
static bool check_license(const std::string& device_id, const std::string& license_url) {
    std::string cmd = "curl -sf " + license_url + " 2>/dev/null";
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) return false;

    std::string result;
    char buf[512];
    while (fgets(buf, sizeof(buf), pipe)) result += buf;
    pclose(pipe);

    // Simple check: is the device_id in the JSON array?
    return result.find("\"" + device_id + "\"") != std::string::npos;
}

// Configure WiFi and hostname from config
static void apply_system_config(const std::map<std::string, std::string>& config) {
    // Hostname
    if (config.count("hostname")) {
        auto& h = config.at("hostname");
        printf("Setting hostname: %s\n", h.c_str());
        std::ofstream("/etc/hostname") << h;
        sethostname(h.c_str(), h.size());
    }

    // WiFi
    if (config.count("wifi_ssid")) {
        auto& ssid = config.at("wifi_ssid");
        auto pass = config.count("wifi_password") ? config.at("wifi_password") : "";
        auto country = config.count("wifi_country") ? config.at("wifi_country") : "DE";

        printf("Configuring WiFi: %s\n", ssid.c_str());

        std::ofstream wpa("/etc/wpa_supplicant/wpa_supplicant-wlan0.conf");
        wpa << "ctrl_interface=/var/run/wpa_supplicant\n"
            << "update_config=1\n"
            << "country=" << country << "\n\n"
            << "network={\n"
            << "    ssid=\"" << ssid << "\"\n"
            << "    psk=\"" << pass << "\"\n"
            << "    key_mgmt=WPA-PSK\n"
            << "}\n";
        wpa.close();

        system("rfkill unblock wifi 2>/dev/null");
        system("wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf 2>/dev/null");
        system("dhclient wlan0 2>/dev/null || udhcpc -i wlan0 2>/dev/null");

        // Wait for network
        for (int i = 0; i < 30; i++) {
            if (system("ping -c1 -W1 8.8.8.8 >/dev/null 2>&1") == 0) break;
            sleep(1);
        }
    }
}

// Try mDNS discovery via avahi-browse
static std::string discover_server() {
    printf("Searching for ShareScreen server via mDNS...\n");
    FILE* pipe = popen("timeout 10 avahi-browse -rpt _sharescreen._tcp 2>/dev/null", "r");
    if (!pipe) return "";

    std::string result;
    char buf[512];
    while (fgets(buf, sizeof(buf), pipe)) result += buf;
    pclose(pipe);

    std::istringstream stream(result);
    std::string line;
    while (std::getline(stream, line)) {
        if (line.empty() || line[0] != '=') continue;
        std::vector<std::string> fields;
        std::istringstream ls(line);
        std::string field;
        while (std::getline(ls, field, ';')) fields.push_back(field);
        if (fields.size() >= 9) {
            if (fields.size() >= 10) {
                auto txt = fields[9];
                auto url_pos = txt.find("\"url=");
                if (url_pos != std::string::npos) {
                    auto start = url_pos + 5;
                    auto end = txt.find('"', start);
                    if (end != std::string::npos) {
                        auto url = txt.substr(start, end - start);
                        printf("Found server via mDNS: %s\n", url.c_str());
                        return url;
                    }
                }
            }
            auto url = "http://" + fields[7] + ":" + fields[8];
            printf("Found server via mDNS: %s\n", url.c_str());
            return url;
        }
    }
    return "";
}

int main(int argc, char* argv[]) {
    gst_init(&argc, &argv);

    // Read config from boot partition
    auto config = find_config();

    // Apply WiFi and hostname before anything else
    apply_system_config(config);

    // Device identity
    std::string device_id = get_cpu_serial();
    printf("Device ID (CPU serial): %s\n", device_id.c_str());

    // License check
    std::string license_url = getenv("LICENSE_URL")
        ? getenv("LICENSE_URL")
        : "https://raw.githubusercontent.com/nored/sharescreen-licenses/main/devices.json";

    while (!check_license(device_id, license_url)) {
        printf("\n");
        printf("========================================\n");
        printf("  DEVICE NOT LICENSED\n");
        printf("  Device ID: %s\n", device_id.c_str());
        printf("  Send this ID to activate.\n");
        printf("========================================\n");
        printf("Retrying in 60 seconds...\n\n");
        sleep(60);
    }
    printf("License valid!\n");

    // Find server: env > mDNS > retry
    std::string server = getenv("SHARESCREEN_SERVER")
        ? getenv("SHARESCREEN_SERVER")
        : "";

    if (server.empty()) server = discover_server();

    while (server.empty()) {
        printf("No server found. Retrying mDNS in 10 seconds...\n");
        sleep(10);
        server = discover_server();
    }

    int connector_id = getenv("KMS_CONNECTOR_ID")
        ? atoi(getenv("KMS_CONNECTOR_ID"))
        : config.count("connector_id") ? atoi(config.at("connector_id").c_str()) : 33;
    std::string idle_image = "/tmp/sharescreen-idle.png";

    printf("ShareScreen Receiver (C++)\n");
    printf("  Device ID: %s\n", device_id.c_str());
    printf("  Server: %s\n", server.c_str());
    printf("  KMS connector: %d\n", connector_id);

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    main_loop = g_main_loop_new(nullptr, FALSE);

    Pipeline pipeline(connector_id);

    // Register as device, wait for room assignment from admin
    // The signaling will handle register-device and assign-room
    SignalingCallbacks callbacks;

    callbacks.on_connected = [&]() {
        printf("Connected to signaling server\n");
        if (std::ifstream(idle_image).good()) {
            pipeline.show_idle(idle_image);
        }
    };

    callbacks.on_offer = [&](const std::string& sdp) {
        pipeline.handle_offer(sdp);
    };

    callbacks.on_ice_candidate = [&](int mline, const std::string& candidate) {
        pipeline.add_ice_candidate(mline, candidate);
    };

    callbacks.on_sharing_stopped = [&]() {
        printf("Sharing stopped, returning to idle\n");
        pipeline.stop();
        if (std::ifstream(idle_image).good()) {
            pipeline.show_idle(idle_image);
        }
    };

    callbacks.on_room_assigned = [&](const std::string& room) {
        printf("Room assigned: %s — fetching idle image\n", room.c_str());
        std::string cmd = "curl -sf -o " + idle_image + " " +
                          server + "/" + room + "/idle.png";
        system(cmd.c_str());
        if (std::ifstream(idle_image).good()) {
            pipeline.show_idle(idle_image);
        }
    };

    callbacks.on_disconnected = [&]() {
        printf("Disconnected, stopping pipeline\n");
        pipeline.stop();
    };

    Signaling signaling(server, device_id, callbacks);
    pipeline.set_signaling(&signaling);

    g_idle_add([](gpointer data) -> gboolean {
        static_cast<Signaling*>(data)->connect();
        return G_SOURCE_REMOVE;
    }, &signaling);

    printf("Starting main loop...\n");
    g_main_loop_run(main_loop);

    printf("Shutting down...\n");
    pipeline.stop();
    g_main_loop_unref(main_loop);
    gst_deinit();

    return 0;
}
