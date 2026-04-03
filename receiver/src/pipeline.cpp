#include "pipeline.h"
#include "signaling.h"
#include <cstdio>
#include <cstring>

Pipeline::Pipeline(int connector_id) : connector_id_(connector_id) {
}

Pipeline::~Pipeline() {
    stop();
    cleanup_idle();
}

void Pipeline::cleanup_video() {
    if (pipe_) {
        gst_element_set_state(pipe_, GST_STATE_NULL);
        gst_object_unref(pipe_);
        pipe_ = nullptr;
        webrtc_ = nullptr;
    }
}

void Pipeline::cleanup_idle() {
    if (idle_pipe_) {
        gst_element_set_state(idle_pipe_, GST_STATE_NULL);
        gst_object_unref(idle_pipe_);
        idle_pipe_ = nullptr;
    }
}

void Pipeline::show_idle(const std::string& image_path) {
    cleanup_idle();

    // Display a PNG image on the framebuffer via kmssink
    char pipeline_str[1024];
    snprintf(pipeline_str, sizeof(pipeline_str),
        "filesrc location=%s ! pngdec ! imagefreeze ! videoconvert ! "
        "video/x-raw,format=BGRx ! "
        "kmssink connector-id=%d force-modesetting=true sync=false",
        image_path.c_str(), connector_id_);

    GError* error = nullptr;
    idle_pipe_ = gst_parse_launch(pipeline_str, &error);
    if (error) {
        fprintf(stderr, "Failed to create idle pipeline: %s\n", error->message);
        g_error_free(error);
        return;
    }

    gst_element_set_state(idle_pipe_, GST_STATE_PLAYING);
    printf("Idle screen shown: %s\n", image_path.c_str());
}

void Pipeline::handle_offer(const std::string& sdp) {
    // Stop idle and any previous video pipeline
    cleanup_idle();
    cleanup_video();

    // Small delay to release DRM master
    g_usleep(100000);

    pipe_ = gst_pipeline_new("receiver");

    webrtc_ = gst_element_factory_make("webrtcbin", "webrtc");
    g_object_set(webrtc_,
        "bundle-policy", GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE,
        "stun-server", "stun://stun.l.google.com:19302",
        "latency", 0,
        nullptr);

    gst_bin_add(GST_BIN(pipe_), webrtc_);

    g_signal_connect(webrtc_, "on-ice-candidate",
                     G_CALLBACK(on_ice_candidate), this);
    g_signal_connect(webrtc_, "pad-added",
                     G_CALLBACK(on_pad_added), this);

    // Drop late packets instead of buffering them
    g_signal_connect(webrtc_, "deep-element-added",
        G_CALLBACK(+[](GstBin* bin, GstBin* sub_bin, GstElement* element, gpointer) {
            auto* name = gst_element_get_name(element);
            if (g_str_has_prefix(name, "rtpjitterbuffer")) {
                g_object_set(element,
                    "latency", 0,
                    "drop-on-latency", TRUE,
                    "mode", 0,  // RTP timestamps only, no clock slaving
                    "faststart-min-packets", 1,
                    nullptr);
                printf("Jitter buffer: latency=0, drop-on-latency, mode=none\n");
            }
            g_free(name);
        }), nullptr);

    gst_element_set_state(pipe_, GST_STATE_PLAYING);

    // Set remote description (offer)
    GstSDPMessage* sdp_msg;
    gst_sdp_message_new_from_text(sdp.c_str(), &sdp_msg);
    auto* offer = gst_webrtc_session_description_new(
        GST_WEBRTC_SDP_TYPE_OFFER, sdp_msg);

    GstPromise* promise = gst_promise_new_with_change_func(
        on_offer_set, this, nullptr);
    g_signal_emit_by_name(webrtc_, "set-remote-description", offer, promise);
    gst_webrtc_session_description_free(offer);
}

void Pipeline::on_offer_set(GstPromise* promise, gpointer user_data) {
    gst_promise_unref(promise);
    auto* self = static_cast<Pipeline*>(user_data);

    GstPromise* answer_promise = gst_promise_new_with_change_func(
        on_answer_created, self, nullptr);
    g_signal_emit_by_name(self->webrtc_, "create-answer", nullptr, answer_promise);
}

void Pipeline::on_answer_created(GstPromise* promise, gpointer user_data) {
    auto* self = static_cast<Pipeline*>(user_data);
    auto* reply = gst_promise_get_reply(promise);

    GstWebRTCSessionDescription* answer = nullptr;
    gst_structure_get(reply, "answer",
        GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &answer, nullptr);

    GstPromise* local_promise = gst_promise_new();
    g_signal_emit_by_name(self->webrtc_, "set-local-description",
                          answer, local_promise);
    gst_promise_interrupt(local_promise);
    gst_promise_unref(local_promise);

    // Send answer via signaling
    auto* sdp_text = gst_sdp_message_as_text(answer->sdp);
    printf("Sending answer\n");
    if (self->signaling_)
        self->signaling_->send_answer(sdp_text);
    g_free(sdp_text);

    gst_webrtc_session_description_free(answer);
    gst_promise_unref(promise);
}

void Pipeline::on_ice_candidate(GstElement* webrtc, guint mline_index,
                                 gchar* candidate, gpointer user_data) {
    auto* self = static_cast<Pipeline*>(user_data);
    if (candidate && self->signaling_) {
        self->signaling_->send_ice_candidate(mline_index, candidate);
    }
}

void Pipeline::on_pad_added(GstElement* webrtc, GstPad* pad, gpointer user_data) {
    auto* self = static_cast<Pipeline*>(user_data);

    if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC)
        return;

    printf("Incoming stream: %s\n", GST_PAD_NAME(pad));
    self->link_video_chain(pad);
}

void Pipeline::link_video_chain(GstPad* src_pad) {
    // rtph264depay -> h264parse -> v4l2h264dec -> kmssink
    auto* depay = gst_element_factory_make("rtph264depay", nullptr);
    auto* parse = gst_element_factory_make("h264parse", nullptr);
    auto* decoder = gst_element_factory_make("v4l2h264dec", nullptr);
    auto* sink = gst_element_factory_make("kmssink", nullptr);

    if (!depay || !parse || !decoder || !sink) {
        fprintf(stderr, "FATAL: Failed to create hardware pipeline elements.\n");
        return;
    }

    g_object_set(sink,
        "connector-id", connector_id_,
        "force-modesetting", TRUE,
        "sync", FALSE,
        "can-scale", TRUE,
        nullptr);

    gst_bin_add_many(GST_BIN(pipe_), depay, parse, decoder, sink, nullptr);

    gst_element_sync_state_with_parent(depay);
    gst_element_sync_state_with_parent(parse);
    gst_element_sync_state_with_parent(decoder);
    gst_element_sync_state_with_parent(sink);

    gst_element_link_many(depay, parse, decoder, sink, nullptr);

    auto* sink_pad = gst_element_get_static_pad(depay, "sink");
    auto ret = gst_pad_link(src_pad, sink_pad);
    gst_object_unref(sink_pad);

    if (ret != GST_PAD_LINK_OK) {
        fprintf(stderr, "Failed to link pipeline: %d\n", ret);
    } else {
        printf("Pipeline: rtph264depay -> h264parse -> v4l2h264dec -> kmssink\n");
    }
}

void Pipeline::stop() {
    cleanup_video();
}

void Pipeline::add_ice_candidate(int mline, const std::string& candidate) {
    if (webrtc_) {
        g_signal_emit_by_name(webrtc_, "add-ice-candidate", mline,
                              candidate.c_str());
    }
}
