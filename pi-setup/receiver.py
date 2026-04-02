#!/usr/bin/env python3
"""
ShareScreen WebRTC Receiver for Raspberry Pi
Connects to the signaling server via Socket.IO, receives WebRTC video,
and displays it fullscreen on the framebuffer via kmssink.
"""

import sys
import os
import json
import threading
import time
import subprocess
import gi

gi.require_version('Gst', '1.0')
gi.require_version('GstWebRTC', '1.0')
gi.require_version('GstSdp', '1.0')
from gi.repository import Gst, GstWebRTC, GstSdp, GLib

# We use python-socketio client
try:
    import socketio
except ImportError:
    # Try installing it
    os.system('pip3 install --break-system-packages python-socketio[client] 2>/dev/null || pip3 install python-socketio[client]')
    import socketio

Gst.init(None)

ROOM = sys.argv[1] if len(sys.argv) > 1 else open(os.path.expanduser('~/.sharescreen-room')).read().strip()
SERVER = os.environ.get('SHARESCREEN_SERVER', 'https://share.hotel-park-soltau.de')

print(f'ShareScreen receiver for room: {ROOM}')
print(f'Server: {SERVER}')


class WebRTCReceiver:
    def __init__(self):
        self.pipe = None
        self.webrtc = None
        self.sio = socketio.Client(reconnection=True, reconnection_delay=2)
        self.loop = GLib.MainLoop()
        self.qr_process = None
        self.streaming = False

        self._setup_socketio()

    def _setup_socketio(self):
        @self.sio.event
        def connect():
            print('Socket.IO connected')
            self.sio.emit('join', {'room': ROOM, 'type': 'display'})

        @self.sio.event
        def disconnect():
            print('Socket.IO disconnected')

        @self.sio.on('offer')
        def on_offer(data):
            print('Received offer')
            offer_sdp = data['offer']['sdp']
            self._handle_offer(offer_sdp)

        @self.sio.on('ice-candidate')
        def on_ice(data):
            candidate = data.get('candidate')
            if candidate and candidate.get('candidate'):
                self._add_ice_candidate(candidate)

        @self.sio.on('sharing-stopped')
        def on_stop():
            print('Sharing stopped')
            self._stop_pipeline()
            self._show_qr()

        @self.sio.on('ready')
        def on_ready():
            print('Ready signal received')

    def _create_pipeline(self):
        # Stop existing pipeline
        self._stop_pipeline()

        self.pipe = Gst.parse_launch(
            'webrtcbin name=webrtc bundle-policy=max-bundle '
            'stun-server=stun://stun.l.google.com:19302 '
            '! queue '
            '! decodebin '
            '! videoconvert '
            '! kmssink'
        )

        self.webrtc = self.pipe.get_by_name('webrtc')

        # Handle incoming streams
        self.webrtc.connect('pad-added', self._on_pad_added)
        self.webrtc.connect('on-ice-candidate', self._on_ice_candidate)

        self.pipe.set_state(Gst.State.READY)

    def _on_pad_added(self, webrtc, pad):
        if pad.direction != Gst.PadDirection.SRC:
            return

        print(f'New pad: {pad.get_name()}')
        decodebin = self.pipe.get_by_name('decodebin0')
        if not decodebin:
            # Dynamically link: webrtcbin src -> queue -> decodebin -> videoconvert -> kmssink
            # We need to rebuild the pipeline for dynamic pads
            pass

        # Connect to the decode pipeline
        sink_pad = self.pipe.get_by_name('queue0')
        if sink_pad:
            pad.link(sink_pad.get_static_pad('sink'))

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

    def _handle_offer(self, sdp_text):
        print('Handling offer...')
        self._hide_qr()

        # Build a proper pipeline with dynamic pad handling
        self._stop_pipeline()

        self.pipe = Gst.Pipeline.new('receiver')

        # WebRTC bin
        self.webrtc = Gst.ElementFactory.make('webrtcbin', 'webrtc')
        self.webrtc.set_property('bundle-policy',
            GstWebRTC.WebRTCBundlePolicy.MAX_BUNDLE)
        self.webrtc.set_property('stun-server', 'stun://stun.l.google.com:19302')
        self.pipe.add(self.webrtc)

        self.webrtc.connect('on-ice-candidate', self._on_ice_candidate)
        self.webrtc.connect('pad-added', self._on_incoming_stream)

        self.pipe.set_state(Gst.State.PLAYING)

        # Set remote description (offer)
        res, sdpmsg = GstSdp.SDPMessage.new_from_text(sdp_text)
        if res != GstSdp.SDPResult.OK:
            print(f'Failed to parse SDP: {res}')
            return

        offer = GstWebRTC.WebRTCSessionDescription.new(
            GstWebRTC.WebRTCSDPType.OFFER, sdpmsg)
        promise = Gst.Promise.new_with_change_func(self._on_offer_set)
        self.webrtc.emit('set-remote-description', offer, promise)

    def _on_offer_set(self, promise):
        promise.wait()
        reply = promise.get_reply()
        # Create answer
        promise = Gst.Promise.new_with_change_func(self._on_answer_created)
        self.webrtc.emit('create-answer', None, promise)

    def _on_answer_created(self, promise):
        promise.wait()
        reply = promise.get_reply()
        answer = reply.get_value('answer')
        promise = Gst.Promise.new()
        self.webrtc.emit('set-local-description', answer, promise)
        promise.interrupt()

        # Send answer to signaling server
        sdp_text = answer.sdp.as_text()
        print('Sending answer')
        self.sio.emit('answer', {
            'room': ROOM,
            'answer': {'type': 'answer', 'sdp': sdp_text}
        })
        self.streaming = True

    def _on_incoming_stream(self, webrtc, pad):
        if pad.direction != Gst.PadDirection.SRC:
            return

        print(f'Incoming stream pad: {pad.get_name()}')

        # Use decodebin which auto-selects hardware decoders (v4l2h264dec)
        # when available, with higher rank than software decoders
        decodebin = Gst.ElementFactory.make('decodebin', None)
        decodebin.set_property('force-sw-decoders', False)
        decodebin.connect('pad-added', self._on_decoded_pad)
        self.pipe.add(decodebin)
        decodebin.sync_state_with_parent()
        pad.link(decodebin.get_static_pad('sink'))

    def _on_decoded_pad(self, decodebin, pad):
        caps = pad.get_current_caps()
        if not caps:
            caps = pad.query_caps(None)
        if not caps or caps.get_size() == 0:
            return

        struct_name = caps.to_string()
        print(f'Decoded pad caps: {struct_name}')

        if 'video/' in struct_name:
            # Scale to fit display, convert colorspace, output to DRM
            scale = Gst.ElementFactory.make('videoscale', None)
            convert = Gst.ElementFactory.make('videoconvert', None)
            sink = Gst.ElementFactory.make('kmssink', None)
            sink.set_property('force-modesetting', True)

            self.pipe.add(scale)
            self.pipe.add(convert)
            self.pipe.add(sink)

            scale.sync_state_with_parent()
            convert.sync_state_with_parent()
            sink.sync_state_with_parent()

            pad.link(scale.get_static_pad('sink'))
            scale.link(convert)
            convert.link(sink)

            self._hide_qr()
            print('Video pipeline connected — displaying on screen')

    def _add_ice_candidate(self, candidate):
        if self.webrtc:
            sdp_mline_index = candidate.get('sdpMLineIndex', 0)
            candidate_str = candidate.get('candidate', '')
            if candidate_str:
                self.webrtc.emit('add-ice-candidate', sdp_mline_index, candidate_str)

    def _stop_pipeline(self):
        if self.pipe:
            self.pipe.set_state(Gst.State.NULL)
            self.pipe = None
            self.webrtc = None
        self.streaming = False

    def _show_qr(self):
        if self.qr_process and self.qr_process.poll() is None:
            return  # Already showing
        qr_path = '/tmp/sharescreen-qr.png'
        if not os.path.exists(qr_path):
            subprocess.run([
                'qrencode', '-o', qr_path, '-s', '10', '-m', '2',
                '--foreground=2a2a29',
                f'{SERVER}/{ROOM}/share'
            ])
        try:
            self.qr_process = subprocess.Popen(
                ['fbi', '-T', '1', '-d', '/dev/fb0', '--noverbose', '-a', qr_path],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
        except Exception as e:
            print(f'Could not show QR: {e}')

    def _hide_qr(self):
        # Kill ALL fbi processes
        subprocess.run(['killall', '-9', 'fbi'], capture_output=True)
        if self.qr_process:
            try:
                self.qr_process.kill()
            except:
                pass
            self.qr_process = None
        # Clear framebuffer
        try:
            subprocess.run(['dd', 'if=/dev/zero', 'of=/dev/fb0', 'bs=1M', 'count=10'],
                          capture_output=True, timeout=3)
        except:
            pass

    def run(self):
        self._show_qr()

        # Connect to server
        while True:
            try:
                print(f'Connecting to {SERVER}...')
                self.sio.connect(SERVER, transports=['websocket', 'polling'])
                break
            except Exception as e:
                print(f'Connection failed: {e}, retrying in 5s...')
                time.sleep(5)

        # Run GLib main loop in a thread
        loop_thread = threading.Thread(target=self.loop.run, daemon=True)
        loop_thread.start()

        # Keep running
        try:
            self.sio.wait()
        except KeyboardInterrupt:
            print('Shutting down...')
            self._stop_pipeline()
            self._hide_qr()
            self.sio.disconnect()


if __name__ == '__main__':
    receiver = WebRTCReceiver()
    receiver.run()
