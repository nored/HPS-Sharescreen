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
        // Skip comments and empty lines
        if (line.empty() || line[0] == '#') continue;
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        auto key = line.substr(0, eq);
        auto val = line.substr(eq + 1);
        // Trim whitespace
        while (!key.empty() && key.back() == ' ') key.pop_back();
        while (!val.empty() && val.front() == ' ') val.erase(val.begin());
        config[key] = val;
    }
    return config;
}

// Try multiple config file locations (boot partition first)
static std::map<std::string, std::string> find_config() {
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

// Try mDNS discovery via avahi-browse (available on Pi)
static std::string discover_server() {
    printf("Searching for ShareScreen server via mDNS...\n");
    FILE* pipe = popen("avahi-browse -rpt _sharescreen._tcp 2>/dev/null | head -20", "r");
    if (!pipe) return "";

    std::string result;
    char buf[512];
    while (fgets(buf, sizeof(buf), pipe)) {
        result += buf;
    }
    pclose(pipe);

    // Parse avahi-browse output: look for address and port
    // Format: =;eth0;IPv4;ShareScreen;_sharescreen._tcp;local;hostname;address;port;txt
    std::string address, port;
    std::istringstream stream(result);
    std::string line;
    while (std::getline(stream, line)) {
        if (line.empty() || line[0] != '=') continue;
        // Split by semicolons
        std::vector<std::string> fields;
        std::istringstream ls(line);
        std::string field;
        while (std::getline(ls, field, ';')) fields.push_back(field);
        if (fields.size() >= 9) {
            address = fields[7];
            port = fields[8];
            // Check TXT record for url
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
            if (!address.empty() && !port.empty()) {
                auto url = "http://" + address + ":" + port;
                printf("Found server via mDNS: %s\n", url.c_str());
                return url;
            }
        }
    }
    return "";
}

int main(int argc, char* argv[]) {
    gst_init(&argc, &argv);

    // Config priority: CLI args > env vars > config file > mDNS > defaults
    auto config = find_config();

    std::string room;
    std::string server;

    // Room: CLI arg > env > config file
    if (argc > 1) {
        room = argv[1];
    } else if (getenv("SHARESCREEN_ROOM")) {
        room = getenv("SHARESCREEN_ROOM");
    } else if (config.count("room")) {
        room = config["room"];
    }

    // Server: env > config file > mDNS
    if (getenv("SHARESCREEN_SERVER")) {
        server = getenv("SHARESCREEN_SERVER");
    } else if (config.count("server")) {
        server = config["server"];
    } else {
        server = discover_server();
    }

    // If still no server, retry mDNS periodically
    if (server.empty()) {
        printf("No server configured and mDNS discovery failed.\n");
        printf("Place a config file at /boot/firmware/sharescreen.conf with:\n");
        printf("  server=https://your-server.example.com\n");
        printf("  room=YourRoom\n");
        printf("Retrying mDNS every 10 seconds...\n");

        while (server.empty()) {
            sleep(10);
            server = discover_server();
        }
    }

    if (room.empty()) {
        printf("No room configured, using hostname\n");
        char hostname[64];
        gethostname(hostname, sizeof(hostname));
        room = hostname;
    }

    int connector_id = getenv("KMS_CONNECTOR_ID")
        ? atoi(getenv("KMS_CONNECTOR_ID"))
        : config.count("connector_id") ? atoi(config["connector_id"].c_str()) : 33;
    std::string idle_image = getenv("IDLE_IMAGE")
        ? getenv("IDLE_IMAGE")
        : "/tmp/sharescreen-idle.png";

    printf("ShareScreen Receiver (C++)\n");
    printf("  Room: %s\n", room.c_str());
    printf("  Server: %s\n", server.c_str());
    printf("  KMS connector: %d\n", connector_id);
    printf("  Idle image: %s\n", idle_image.c_str());

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    main_loop = g_main_loop_new(nullptr, FALSE);

    Pipeline pipeline(connector_id);

    // Fetch idle image from server if not cached
    if (!std::ifstream(idle_image).good()) {
        std::string cmd = "curl -sf -o " + idle_image + " " +
                          server + "/" + room + "/idle.png";
        printf("Fetching idle image...\n");
        system(cmd.c_str());
    }
    if (std::ifstream(idle_image).good()) {
        pipeline.show_idle(idle_image);
    } else {
        printf("No idle image available\n");
    }

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

    callbacks.on_disconnected = [&]() {
        printf("Disconnected, stopping pipeline\n");
        pipeline.stop();
    };

    Signaling signaling(server, room, callbacks);
    pipeline.set_signaling(&signaling);

    // Connect in an idle callback so the main loop is running
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
