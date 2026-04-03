#include "signaling.h"
#include <cstring>
#include <cstdio>

// Socket.IO protocol: Engine.IO packet types
// '0' = open, '2' = ping, '3' = pong, '4' = message
// Socket.IO on top: '0' = connect, '2' = event, '42' = event (EIO4 + SIO event)

Signaling::Signaling(const std::string& server_url, const std::string& room,
                     const SignalingCallbacks& callbacks)
    : server_url_(server_url), room_(room), callbacks_(callbacks) {
    session_ = soup_session_new();
}

Signaling::~Signaling() {
    if (ws_) {
        soup_websocket_connection_close(ws_, SOUP_WEBSOCKET_CLOSE_NORMAL, nullptr);
        g_object_unref(ws_);
    }
    if (session_) {
        g_object_unref(session_);
    }
}

void Signaling::connect() {
    // Socket.IO connects via: GET /socket.io/?EIO=4&transport=polling first,
    // then upgrades to WebSocket. We go direct WebSocket.
    // First get the sid via polling
    std::string poll_url = server_url_ + "/socket.io/?EIO=4&transport=polling";

    auto* msg = soup_message_new("GET", poll_url.c_str());
    GError* error = nullptr;
    auto* body = soup_session_send_and_read(session_, msg, nullptr, &error);

    if (error) {
        fprintf(stderr, "Polling failed: %s — retrying in 5s\n", error->message);
        g_error_free(error);
        g_object_unref(msg);
        schedule_reconnect();
        return;
    }

    gsize size;
    auto* data = (const char*)g_bytes_get_data(body, &size);

    // Response is Engine.IO: "0{...}" — skip the '0' prefix
    // Find the JSON part
    const char* json_start = strchr(data, '{');
    if (!json_start) {
        fprintf(stderr, "No JSON in polling response — retrying in 5s\n");
        g_bytes_unref(body);
        g_object_unref(msg);
        schedule_reconnect();
        return;
    }

    auto* parser = json_parser_new();
    json_parser_load_from_data(parser, json_start, -1, nullptr);
    auto* root = json_parser_get_root(parser);
    auto* obj = json_node_get_object(root);
    sid_ = json_object_get_string_member(obj, "sid");
    printf("Got SID: %s\n", sid_.c_str());
    g_object_unref(parser);
    g_bytes_unref(body);
    g_object_unref(msg);

    // Now upgrade to WebSocket
    std::string ws_url = server_url_ + "/socket.io/?EIO=4&transport=websocket&sid=" + sid_;
    // Replace https:// with wss://
    if (ws_url.substr(0, 8) == "https://")
        ws_url = "wss://" + ws_url.substr(8);
    else if (ws_url.substr(0, 7) == "http://")
        ws_url = "ws://" + ws_url.substr(7);

    auto* ws_msg = soup_message_new("GET", ws_url.c_str());
    soup_session_websocket_connect_async(session_, ws_msg,
        nullptr, nullptr, G_PRIORITY_DEFAULT, nullptr,
        on_ws_connected, this);
    g_object_unref(ws_msg);
}

void Signaling::on_ws_connected(GObject* source, GAsyncResult* result, gpointer user_data) {
    auto* self = static_cast<Signaling*>(user_data);
    GError* error = nullptr;
    self->ws_ = soup_session_websocket_connect_finish(
        SOUP_SESSION(source), result, &error);

    if (error) {
        fprintf(stderr, "WebSocket connect failed: %s\n", error->message);
        g_error_free(error);
        return;
    }

    printf("WebSocket connected\n");

    g_signal_connect(self->ws_, "message",
                     G_CALLBACK(on_ws_message_cb), self);
    g_signal_connect(self->ws_, "closed",
                     G_CALLBACK(on_ws_closed_cb), self);

    // Engine.IO: send '2probe' then '5' for upgrade
    soup_websocket_connection_send_text(self->ws_, "2probe");
}

void Signaling::on_ws_message_cb(SoupWebsocketConnection* conn, gint type,
                                  GBytes* message, gpointer user_data) {
    auto* self = static_cast<Signaling*>(user_data);
    gsize size;
    auto* data = (const char*)g_bytes_get_data(message, &size);
    std::string msg(data, size);

    if (msg == "3probe") {
        // Upgrade confirmed, send upgrade packet
        soup_websocket_connection_send_text(conn, "5");

        // Now send Socket.IO connect for default namespace
        soup_websocket_connection_send_text(conn, "40");
        return;
    }

    if (msg == "2") {
        // Engine.IO ping, respond with pong
        soup_websocket_connection_send_text(conn, "3");
        return;
    }

    if (msg.substr(0, 2) == "40") {
        // Socket.IO connected to namespace
        printf("Socket.IO connected to namespace\n");
        self->connected_ = true;

        // Join the room as display
        auto* builder = json_builder_new();
        json_builder_begin_object(builder);
        json_builder_set_member_name(builder, "room");
        json_builder_add_string_value(builder, self->room_.c_str());
        json_builder_set_member_name(builder, "type");
        json_builder_add_string_value(builder, "display");
        json_builder_end_object(builder);

        auto* node = json_builder_get_root(builder);
        self->send_event("join", node);
        json_node_unref(node);
        g_object_unref(builder);

        if (self->callbacks_.on_connected)
            self->callbacks_.on_connected();
        return;
    }

    // Socket.IO event: "42[event, data]"
    if (msg.size() > 2 && msg.substr(0, 2) == "42") {
        auto* parser = json_parser_new();
        if (json_parser_load_from_data(parser, msg.c_str() + 2, -1, nullptr)) {
            auto* root = json_parser_get_root(parser);
            auto* arr = json_node_get_array(root);
            if (arr && json_array_get_length(arr) >= 1) {
                auto* event_str = json_array_get_string_element(arr, 0);
                JsonNode* data_node = nullptr;
                if (json_array_get_length(arr) >= 2)
                    data_node = json_array_get_element(arr, 1);
                self->handle_event(event_str, data_node);
            }
        }
        g_object_unref(parser);
    }
}

void Signaling::handle_event(const std::string& event, JsonNode* data) {
    if (event == "offer" && data) {
        auto* obj = json_node_get_object(data);
        auto* offer_obj = json_object_get_object_member(obj, "offer");
        auto* sdp = json_object_get_string_member(offer_obj, "sdp");
        printf("Received offer (%zu bytes)\n", strlen(sdp));
        if (callbacks_.on_offer)
            callbacks_.on_offer(sdp);
    }
    else if (event == "ice-candidate" && data) {
        auto* obj = json_node_get_object(data);
        auto* cand_obj = json_object_get_object_member(obj, "candidate");
        if (cand_obj && json_object_has_member(cand_obj, "candidate")) {
            auto* candidate = json_object_get_string_member(cand_obj, "candidate");
            if (candidate && strlen(candidate) > 0) {
                int mline = (int)json_object_get_int_member(cand_obj, "sdpMLineIndex");
                if (callbacks_.on_ice_candidate)
                    callbacks_.on_ice_candidate(mline, candidate);
            }
        }
    }
    else if (event == "sharing-stopped") {
        printf("Sharing stopped\n");
        if (callbacks_.on_sharing_stopped)
            callbacks_.on_sharing_stopped();
    }
    else if (event == "reboot") {
        printf("Reboot command received from admin\n");
        system("sudo reboot");
    }
    else if (event == "refresh-idle") {
        printf("Refresh idle image command received\n");
        system("rm -f /tmp/sharescreen-idle.png");
        // Will be re-fetched on next idle
    }
    else if (event == "update") {
        printf("Update command received from admin\n");
        system("/usr/local/bin/sharescreen-update.sh");
    }
    else if (event == "ready") {
        printf("Ready signal received\n");
    }
    else if (event == "room-status") {
        // ignore
    }
}

void Signaling::send_event(const std::string& event, JsonNode* data) {
    if (!ws_ || !connected_) return;

    auto* gen = json_generator_new();
    auto* arr = json_array_new();
    json_array_add_string_element(arr, event.c_str());
    if (data)
        json_array_add_element(arr, json_node_copy(data));

    auto* root = json_node_new(JSON_NODE_ARRAY);
    json_node_set_array(root, arr);
    json_generator_set_root(gen, root);

    gsize len;
    auto* json_str = json_generator_to_data(gen, &len);

    // Prefix with "42" for Socket.IO event
    std::string packet = "42" + std::string(json_str, len);
    soup_websocket_connection_send_text(ws_, packet.c_str());

    g_free(json_str);
    json_node_unref(root);
    g_object_unref(gen);
}

void Signaling::send_answer(const std::string& sdp) {
    auto* builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "room");
    json_builder_add_string_value(builder, room_.c_str());
    json_builder_set_member_name(builder, "answer");
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "type");
    json_builder_add_string_value(builder, "answer");
    json_builder_set_member_name(builder, "sdp");
    json_builder_add_string_value(builder, sdp.c_str());
    json_builder_end_object(builder);
    json_builder_end_object(builder);

    auto* node = json_builder_get_root(builder);
    send_event("answer", node);
    json_node_unref(node);
    g_object_unref(builder);
    printf("Answer sent\n");
}

void Signaling::send_ice_candidate(int mline_index, const std::string& candidate) {
    auto* builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "room");
    json_builder_add_string_value(builder, room_.c_str());
    json_builder_set_member_name(builder, "candidate");
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "candidate");
    json_builder_add_string_value(builder, candidate.c_str());
    json_builder_set_member_name(builder, "sdpMLineIndex");
    json_builder_add_int_value(builder, mline_index);
    json_builder_set_member_name(builder, "sdpMid");
    auto mline_str = std::to_string(mline_index);
    json_builder_add_string_value(builder, mline_str.c_str());
    json_builder_end_object(builder);
    json_builder_end_object(builder);

    auto* node = json_builder_get_root(builder);
    send_event("ice-candidate", node);
    json_node_unref(node);
    g_object_unref(builder);
}

void Signaling::on_ws_closed_cb(SoupWebsocketConnection* conn, gpointer user_data) {
    auto* self = static_cast<Signaling*>(user_data);
    printf("WebSocket closed, reconnecting in 5s...\n");
    self->connected_ = false;
    if (self->ws_) {
        g_object_unref(self->ws_);
        self->ws_ = nullptr;
    }

    if (self->callbacks_.on_disconnected)
        self->callbacks_.on_disconnected();

    self->schedule_reconnect();
}

void Signaling::schedule_reconnect() {
    g_timeout_add_seconds(5, [](gpointer data) -> gboolean {
        auto* sig = static_cast<Signaling*>(data);
        printf("Reconnecting...\n");
        sig->connect();
        return G_SOURCE_REMOVE;
    }, this);
}
