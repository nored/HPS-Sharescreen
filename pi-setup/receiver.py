#!/usr/bin/env python3
"""
ShareScreen WebRTC Receiver for Raspberry Pi
Receives WebRTC video via GStreamer webrtcbin, displays on screen via kmssink.
"""

import sys
import os
import threading
import time
import subprocess
import gi

gi.require_version('Gst', '1.0')
gi.require_version('GstWebRTC', '1.0')
gi.require_version('GstSdp', '1.0')
from gi.repository import Gst, GstWebRTC, GstSdp, GLib

import socketio

Gst.init(None)

ROOM = sys.argv[1] if len(sys.argv) > 1 else open(os.path.expanduser('~/.sharescreen-room')).read().strip()
SERVER = os.environ.get('SHARESCREEN_SERVER', 'https://share.hotel-park-soltau.de')
CONNECTOR_ID = int(os.environ.get('KMS_CONNECTOR_ID', '33'))

print(f'Room: {ROOM}')
print(f'Server: {SERVER}')
print(f'KMS connector: {CONNECTOR_ID}')


class WebRTCReceiver:
    def __init__(self):
        self.pipe = None
        self.webrtc = None
        self.loop = GLib.MainLoop()
        self.sio = socketio.Client(reconnection=True, reconnection_delay=2)
        self._setup_socketio()

        # Show idle screen (test pattern with room name via GStreamer)
        self.idle_pipe = None
        self._show_idle()

    def _setup_socketio(self):
        @self.sio.event
        def connect():
            print('Connected to server')
            self.sio.emit('join', {'room': ROOM, 'type': 'display'})

        @self.sio.event
        def disconnect():
            print('Disconnected from server')

        @self.sio.on('offer')
        def on_offer(data):
            print('Received offer')
            self._handle_offer(data['offer']['sdp'])

        @self.sio.on('ice-candidate')
        def on_ice(data):
            c = data.get('candidate')
            if c and c.get('candidate') and self.webrtc:
                self.webrtc.emit('add-ice-candidate',
                    c.get('sdpMLineIndex', 0), c['candidate'])

        @self.sio.on('sharing-stopped')
        def on_stop():
            print('Sharing stopped')
            self._stop_pipeline()
            self._show_idle()

    def _stop_pipeline(self):
        if self.pipe:
            self.pipe.set_state(Gst.State.NULL)
            # Wait for state change to complete and release DRM
            self.pipe.get_state(Gst.CLOCK_TIME_NONE)
            self.pipe = None
            self.webrtc = None
            print('Pipeline stopped')

    def _stop_idle(self):
        if self.idle_pipe:
            self.idle_pipe.set_state(Gst.State.NULL)
            self.idle_pipe.get_state(Gst.CLOCK_TIME_NONE)
            self.idle_pipe = None

    def _show_idle(self):
        """Show idle screen via GStreamer"""
        self._stop_idle()
        try:
            self.idle_pipe = Gst.parse_launch(
                f'videotestsrc pattern=black ! '
                f'video/x-raw,format=BGRx,width=1920,height=1080,framerate=1/1 ! '
                f'textoverlay text="Raum {ROOM}\\n\\nQR-Code scannen zum Teilen\\n{SERVER}/{ROOM}/share" '
                f'font-desc="Sans Bold 40" valignment=center halignment=center ! '
                f'kmssink connector-id={CONNECTOR_ID} force-modesetting=true restore-crtc=false sync=false'
            )
            self.idle_pipe.set_state(Gst.State.PLAYING)
            print('Idle screen shown')
        except Exception as e:
            print(f'Could not show idle screen: {e}')

    def _handle_offer(self, sdp_text):
        # Clean up everything before new connection
        self._stop_idle()
        self._stop_pipeline()
        time.sleep(0.2)  # Brief pause to release DRM master

        self.pipe = Gst.Pipeline.new('receiver')

        self.webrtc = Gst.ElementFactory.make('webrtcbin', 'webrtc')
        self.webrtc.set_property('bundle-policy',
            GstWebRTC.WebRTCBundlePolicy.MAX_BUNDLE)
        self.webrtc.set_property('stun-server', 'stun://stun.l.google.com:19302')
        self.webrtc.set_property('latency', 0)  # Minimize jitter buffer
        self.pipe.add(self.webrtc)

        self.webrtc.connect('on-ice-candidate', self._on_ice_candidate)
        self.webrtc.connect('pad-added', self._on_incoming_stream)

        self.pipe.set_state(Gst.State.PLAYING)

        # Set remote offer
        res, sdpmsg = GstSdp.SDPMessage.new_from_text(sdp_text)
        if res != GstSdp.SDPResult.OK:
            print(f'Failed to parse SDP')
            return

        offer = GstWebRTC.WebRTCSessionDescription.new(
            GstWebRTC.WebRTCSDPType.OFFER, sdpmsg)
        promise = Gst.Promise.new_with_change_func(self._on_offer_set)
        self.webrtc.emit('set-remote-description', offer, promise)

    def _on_offer_set(self, promise):
        promise.wait()
        promise = Gst.Promise.new_with_change_func(self._on_answer_created)
        self.webrtc.emit('create-answer', None, promise)

    def _on_answer_created(self, promise):
        promise.wait()
        reply = promise.get_reply()
        answer = reply.get_value('answer')
        promise = Gst.Promise.new()
        self.webrtc.emit('set-local-description', answer, promise)
        promise.interrupt()

        sdp_text = answer.sdp.as_text()
        print('Sending answer')
        self.sio.emit('answer', {
            'room': ROOM,
            'answer': {'type': 'answer', 'sdp': sdp_text}
        })

    def _on_ice_candidate(self, webrtc, mline_index, candidate):
        if candidate:
            self.sio.emit('ice-candidate', {
                'room': ROOM,
                'candidate': {
                    'candidate': candidate,
                    'sdpMLineIndex': mline_index,
                    'sdpMid': str(mline_index)
                }
            })

    def _on_incoming_stream(self, webrtc, pad):
        if pad.direction != Gst.PadDirection.SRC:
            return
        print(f'Incoming stream: {pad.get_name()}')

        # Direct low-latency pipeline — no decodebin buffering
        # RTP H264 -> parse -> hardware decode -> convert -> display
        depay = Gst.ElementFactory.make('rtph264depay', None)
        parse = Gst.ElementFactory.make('h264parse', None)
        decoder = Gst.ElementFactory.make('v4l2h264dec', None)

        # v4l2convert to handle DMABuf, no scaling — let kmssink handle it
        convert = Gst.ElementFactory.make('v4l2convert', None)
        # Cap output to display resolution so v4l2convert doesn't upscale
        capsfilter = Gst.ElementFactory.make('capsfilter', None)
        capsfilter.set_property('caps', Gst.Caps.from_string(
            'video/x-raw,format=BGRx'))

        sink = Gst.ElementFactory.make('kmssink', None)
        sink.set_property('connector-id', CONNECTOR_ID)
        sink.set_property('force-modesetting', True)
        sink.set_property('sync', False)
        sink.set_property('can-scale', True)

        elements = [depay, parse, decoder, convert, capsfilter, sink]
        for el in elements:
            self.pipe.add(el)
            el.sync_state_with_parent()

        pad.link(depay.get_static_pad('sink'))
        for i in range(len(elements) - 1):
            elements[i].link(elements[i + 1])

        print('Pipeline connected')

    def run(self):
        loop_thread = threading.Thread(target=self.loop.run, daemon=True)
        loop_thread.start()

        while True:
            try:
                print(f'Connecting to {SERVER}...')
                self.sio.connect(SERVER, transports=['websocket', 'polling'])
                self.sio.wait()
            except Exception as e:
                print(f'Connection error: {e}, retrying in 5s...')
                time.sleep(5)


if __name__ == '__main__':
    receiver = WebRTCReceiver()
    receiver.run()
