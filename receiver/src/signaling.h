#pragma once

#include <functional>
#include <string>
#include <glib.h>
#include <libsoup/soup.h>
#include <json-glib/json-glib.h>

struct SignalingCallbacks {
    std::function<void()> on_connected;
    std::function<void(const std::string& sdp)> on_offer;
    std::function<void(int mline, const std::string& candidate)> on_ice_candidate;
    std::function<void()> on_sharing_stopped;
    std::function<void()> on_disconnected;
};

class Signaling {
public:
    Signaling(const std::string& server_url, const std::string& room,
              const SignalingCallbacks& callbacks);
    ~Signaling();

    void connect();
    void send_answer(const std::string& sdp);
    void send_ice_candidate(int mline_index, const std::string& candidate);

private:
    void on_ws_message(SoupWebsocketConnection* conn, gint type,
                       GBytes* message);
    void send_event(const std::string& event, JsonNode* data);
    void handle_event(const std::string& event, JsonNode* data);
    void schedule_reconnect();

    static void on_ws_connected(GObject* source, GAsyncResult* result, gpointer user_data);
    static void on_ws_message_cb(SoupWebsocketConnection* conn, gint type,
                                  GBytes* message, gpointer user_data);
    static void on_ws_closed_cb(SoupWebsocketConnection* conn, gpointer user_data);

    std::string server_url_;
    std::string room_;
    SignalingCallbacks callbacks_;
    SoupSession* session_ = nullptr;
    SoupWebsocketConnection* ws_ = nullptr;
    std::string sid_;
    bool connected_ = false;
};
