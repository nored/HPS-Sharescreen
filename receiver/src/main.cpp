#include "signaling.h"
#include "pipeline.h"
#include <gst/gst.h>
#include <cstdio>
#include <cstdlib>
#include <csignal>
#include <string>
#include <fstream>

static GMainLoop* main_loop = nullptr;

static void signal_handler(int sig) {
    printf("\nSignal %d received, shutting down...\n", sig);
    if (main_loop)
        g_main_loop_quit(main_loop);
}

static std::string read_room_file() {
    std::ifstream f(std::string(getenv("HOME") ? getenv("HOME") : "/home/pi") +
                    "/.sharescreen-room");
    std::string room;
    if (f >> room) return room;
    return "Kiel";
}

int main(int argc, char* argv[]) {
    gst_init(&argc, &argv);

    std::string room = (argc > 1) ? argv[1] : read_room_file();
    std::string server = getenv("SHARESCREEN_SERVER")
        ? getenv("SHARESCREEN_SERVER")
        : "https://share.hotel-park-soltau.de";
    int connector_id = getenv("KMS_CONNECTOR_ID")
        ? atoi(getenv("KMS_CONNECTOR_ID"))
        : 33;
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
