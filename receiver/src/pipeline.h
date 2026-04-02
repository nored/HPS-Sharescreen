#pragma once

#include <string>
#include <gst/gst.h>
#include <gst/webrtc/webrtc.h>
#include <gst/sdp/sdp.h>

class Signaling;

class Pipeline {
public:
    Pipeline(int connector_id);
    ~Pipeline();

    void set_signaling(Signaling* sig) { signaling_ = sig; }

    void show_idle(const std::string& image_path);
    void handle_offer(const std::string& sdp);
    void add_ice_candidate(int mline, const std::string& candidate);
    void stop();

private:
    void cleanup_video();
    void cleanup_idle();

    static void on_offer_set(GstPromise* promise, gpointer user_data);
    static void on_answer_created(GstPromise* promise, gpointer user_data);
    static void on_ice_candidate(GstElement* webrtc, guint mline_index,
                                  gchar* candidate, gpointer user_data);
    static void on_pad_added(GstElement* webrtc, GstPad* pad, gpointer user_data);

    void link_video_chain(GstPad* src_pad);

    int connector_id_;
    Signaling* signaling_ = nullptr;

    GstElement* pipe_ = nullptr;
    GstElement* webrtc_ = nullptr;
    GstElement* idle_pipe_ = nullptr;
};
