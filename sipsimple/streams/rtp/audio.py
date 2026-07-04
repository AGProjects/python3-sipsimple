
__all__ = ['AudioStream']

from application.notification import NotificationCenter, NotificationData
from zope.interface import implementer

from sipsimple.audio import AudioBridge, AudioDevice, IAudioPort, WaveRecorder
from sipsimple.configuration.settings import SIPSimpleSettings
from sipsimple.core import AudioTransport, PJSIPError, SIPCoreError
from sipsimple.streams.rtp import RTPStream


@implementer(IAudioPort)
class AudioStream(RTPStream):

    type = 'audio'
    priority = 1

    def __init__(self):
        super(AudioStream, self).__init__()

        from sipsimple.application import SIPApplication
        from sipsimple.streams.rtp import stream_creation_context
        # Born on the mixer chosen by the application's factory (set per-thread
        # in Session.init_incoming), or the default voice mixer. Building the
        # bridge on the right mixer here avoids moving it later.
        mixer = getattr(stream_creation_context, 'mixer', None)
        self.mixer = mixer if mixer is not None else SIPApplication.voice_audio_mixer
        self.bridge = AudioBridge(self.mixer)
        self.device = AudioDevice(self.mixer)
        self._audio_rec = None

        self.bridge.add(self.device)

    @property
    def muted(self):
        return self.__dict__.get('muted', False)

    @muted.setter
    def muted(self, value):
        if not isinstance(value, bool):
            raise ValueError("illegal value for muted property: %r" % (value,))
        if value == self.muted:
            return
        old_producer_slot = self.producer_slot
        self.__dict__['muted'] = value
        notification_center = NotificationCenter()
        data = NotificationData(consumer_slot_changed=False, producer_slot_changed=True, old_producer_slot=old_producer_slot, new_producer_slot=self.producer_slot)
        notification_center.post_notification('AudioPortDidChangeSlots', sender=self, data=data)

    @property
    def consumer_slot(self):
        return self._transport.slot if self._transport else None

    @property
    def producer_slot(self):
        return self._transport.slot if self._transport and not self.muted else None

    @property
    def recorder(self):
        return self._audio_rec

    @property
    def signal_level(self):
        """Return (tx_level, rx_level) for this stream as a tuple of ints in
        the range 0..255, or (0, 0) if the stream is not currently attached
        to a conference bridge slot. rx_level is how loud audio is arriving
        from the remote peer; tx_level is how loud audio is being sent to it.
        """
        transport = self._transport
        if transport is None or transport.slot is None:
            return (0, 0)
        try:
            return self.mixer.get_signal_level(transport.slot)
        except Exception:
            return (0, 0)

    def start(self, local_sdp, remote_sdp, stream_index):
        with self._lock:
            if self.state != "INITIALIZED":
                raise RuntimeError("AudioStream.start() may only be called in the INITIALIZED state")
            settings = SIPSimpleSettings()
            self._transport.start(local_sdp, remote_sdp, stream_index, timeout=settings.rtp.timeout)
            self._save_remote_sdp_rtp_info(remote_sdp, stream_index)
            self._check_hold(self._transport.direction.decode(), True)
            if self._try_ice and self._ice_state == "NULL":
                self.state = 'WAIT_ICE'
            else:
                self.state = 'ESTABLISHED'
                # For an opportunistic transport chain, decide which keying
                # actually won (SDES vs ZRTP) BEFORE other observers run, so
                # Session._NH_MediaStreamDidStart sees the resolved type.
                self.encryption._resolve_opportunistic_type()
                self.notification_center.post_notification('MediaStreamDidStart', sender=self)

    def validate_update(self, remote_sdp, stream_index):
        with self._lock:
            # TODO: implement
            return True

    def update(self, local_sdp, remote_sdp, stream_index):
        with self._lock:
            connection = remote_sdp.media[stream_index].connection or remote_sdp.connection
            if not self._rtp_transport.ice_active and (connection.address != self._remote_rtp_address_sdp or self._remote_rtp_port_sdp != remote_sdp.media[stream_index].port):
                # Port and/or address change re-INVITE.
                #
                # The old codepath teared down AudioTransport, then built a
                # new one against the same RTPTransport. After media_stop()
                # the SRTP wrapper's transport_get_info() returns a zeroed
                # sock_info, the new AudioTransport's _get_info reads it,
                # pjmedia_endpt_create_base_sdp fails with PJ_EAFNOTSUP, and
                # the application sees "Could not generate base SDP
                # (PJ_EAFNOTSUP)" with the audio stream dead. Same
                # behaviour on stock python-sipsimple and on Blink.
                #
                # New codepath: rebind the underlying UDP transport's
                # rem_rtp_addr / rem_rtcp_addr in place via
                # pjmedia_transport_rebind_remote_peer (exposed as
                # RTPTransport.rebind_remote_peer). SRTP keys, ROC,
                # AEAD wrapper state and the AudioTransport itself
                # all survive. See deps/patches/27_pjmedia_rebind_remote_peer.patch.
                old_remote = (self._remote_rtp_address_sdp, self._remote_rtp_port_sdp)
                new_remote = (connection.address, remote_sdp.media[stream_index].port)
                try:
                    self._rtp_transport.rebind_remote_peer(remote_sdp, stream_index)
                except SIPCoreError as e:
                    self._failure_reason = e.args[0] if e.args else str(e)
                    self.state = "ENDED"
                    self.notification_center.post_notification('MediaStreamDidFail', sender=self, data=NotificationData(context='update', reason=self._failure_reason))
                    return
                # _save_remote_sdp_rtp_info runs unconditionally below.
                # If the peer is sending us a hold-encoded c=0.0.0.0 with
                # sendrecv, treat it as recvonly so we don't blast media
                # at a black-hole.
                if connection.address == b'0.0.0.0' and remote_sdp.media[stream_index].direction == b'sendrecv':
                    self._transport.update_direction(b'recvonly')
                else:
                    new_direction = local_sdp.media[stream_index].direction
                    self._transport.update_direction(new_direction)
                self._check_hold(self._transport.direction.decode(), False)
                # Surface the change in any RTP log (Blink's RTP Log
                # window listens for RTPStreamDidChangeRTPParameters).
                self.notification_center.post_notification(
                    'RTPStreamDidChangeRTPParameters', sender=self,
                    data=NotificationData(
                        change='remote_peer_rebind',
                        old_remote_address=old_remote[0],
                        old_remote_port=old_remote[1],
                        new_remote_address=new_remote[0],
                        new_remote_port=new_remote[1]))
            else:
                new_direction = local_sdp.media[stream_index].direction
                self._transport.update_direction(new_direction)
                self._check_hold(new_direction.decode(), False)
            self._save_remote_sdp_rtp_info(remote_sdp, stream_index)
            self._transport.update_sdp(local_sdp, remote_sdp, stream_index)
            self._hold_request = None

    def deactivate(self):
        with self._lock:
            self.bridge.stop()

    def end(self):
        with self._lock:
            if self.state == "ENDED" or self._done:
                return
            self._done = True
            if not self._initialized:
                self.state = "ENDED"
                self.notification_center.post_notification('MediaStreamDidNotInitialize', sender=self, data=NotificationData(reason='Interrupted'))
                return
            self.notification_center.post_notification('MediaStreamWillEnd', sender=self)
            if self._transport is not None:
                if self._audio_rec is not None:
                    self._stop_recording()
                self.notification_center.remove_observer(self, sender=self._transport)
                self.notification_center.remove_observer(self, sender=self._rtp_transport)
                self._transport.stop()
                self._transport = None
                self._rtp_transport = None
            self.state = "ENDED"
            self.notification_center.post_notification('MediaStreamDidEnd', sender=self, data=NotificationData(error=self._failure_reason))
            self.session = None

    def reset(self, stream_index):
        with self._lock:
            if self.direction == "inactive" and not self.on_hold_by_local:
                new_direction = b"sendrecv"
                self._transport.update_direction(new_direction)
                self._check_hold(new_direction.decode(), False)
                # TODO: do a full reset, re-creating the AudioTransport, so that a new offer
                # would contain all codecs and ICE would be renegotiated -Saul

    def send_dtmf(self, digit):
        with self._lock:
            if self.state != "ESTABLISHED":
                raise RuntimeError("AudioStream.send_dtmf() cannot be used in %s state" % self.state)
            try:
                self._transport.send_dtmf(digit)
            except PJSIPError as e:
                if not e.args[0].endswith("(PJ_ETOOMANY)"):
                    raise

    def start_recording(self, filename):
        with self._lock:
            if self.state == "ENDED":
                raise RuntimeError("AudioStream.start_recording() may not be called in the ENDED state")
            if self._audio_rec is not None:
                raise RuntimeError("Already recording audio to a file")
            self._audio_rec = WaveRecorder(self.mixer, filename)
            if self.state == "ESTABLISHED":
                self._check_recording()

    def stop_recording(self):
        with self._lock:
            if self._audio_rec is None:
                raise RuntimeError("Not recording any audio")
            self._stop_recording()

    def _NH_RTPAudioStreamGotDTMF(self, notification):
        notification.center.post_notification('AudioStreamGotDTMF', sender=self, data=NotificationData(digit=notification.data.digit))

    def _NH_RTPAudioTransportDidTimeout(self, notification):
        notification.center.post_notification('RTPStreamDidTimeout', sender=self)

    # Private methods
    #

    def _create_transport(self, rtp_transport, remote_sdp=None, stream_index=None):
        settings = SIPSimpleSettings()
        available_codecs = list(self.session.account.rtp.audio_codec_list or settings.rtp.audio_codec_list)
        if remote_sdp is not None:
            # Enforce audio_codec_list preference order
            remote_codecs = list(remote_sdp.media[stream_index or 0].codec_list)
            preferred_codec = next((codec for codec in available_codecs if codec in remote_codecs), None)
            if preferred_codec is not None:
                available_codecs = [preferred_codec] + [codec for codec in available_codecs if codec not in remote_codecs]
        codecs = list(c.encode() for c in available_codecs)
        return AudioTransport(self.mixer, rtp_transport, remote_sdp=remote_sdp, sdp_index=stream_index or 0, codecs=codecs)

    def _check_hold(self, direction, is_initial):
        was_on_hold_by_local = self.on_hold_by_local
        was_on_hold_by_remote = self.on_hold_by_remote
        was_inactive = self.direction == "inactive"
        self.direction = direction
        inactive = self.direction == "inactive"
        self.on_hold_by_local = was_on_hold_by_local if inactive else direction == "sendonly"
        self.on_hold_by_remote = "send" not in direction
        if (is_initial or was_on_hold_by_local or was_inactive) and not inactive and not self.on_hold_by_local and self._hold_request != 'hold':
            self._resume()
        if not was_on_hold_by_local and self.on_hold_by_local:
            self.notification_center.post_notification('RTPStreamDidChangeHoldState', sender=self, data=NotificationData(originator="local", on_hold=True))
        if was_on_hold_by_local and not self.on_hold_by_local:
            self.notification_center.post_notification('RTPStreamDidChangeHoldState', sender=self, data=NotificationData(originator="local", on_hold=False))
        if not was_on_hold_by_remote and self.on_hold_by_remote:
            self.notification_center.post_notification('RTPStreamDidChangeHoldState', sender=self, data=NotificationData(originator="remote", on_hold=True))
        if was_on_hold_by_remote and not self.on_hold_by_remote:
            self.notification_center.post_notification('RTPStreamDidChangeHoldState', sender=self, data=NotificationData(originator="remote", on_hold=False))
        if self._audio_rec is not None:
            self._check_recording()

    def _check_recording(self):
        if not self._audio_rec.is_active:
            self.notification_center.post_notification('AudioStreamWillStartRecording', sender=self, data=NotificationData(filename=self._audio_rec.filename))
            try:
                self._audio_rec.start()
            except SIPCoreError as e:
                self._audio_rec = None
                self.notification_center.post_notification('AudioStreamDidStopRecording', sender=self, data=NotificationData(filename=self._audio_rec.filename, reason=e.args[0]))
                return
            self.notification_center.post_notification('AudioStreamDidStartRecording', sender=self, data=NotificationData(filename=self._audio_rec.filename))
        if not self.on_hold:
            self.bridge.add(self._audio_rec)
        elif self._audio_rec in self.bridge:
            self.bridge.remove(self._audio_rec)

    def _stop_recording(self):
        self.notification_center.post_notification('AudioStreamWillStopRecording', sender=self, data=NotificationData(filename=self._audio_rec.filename))
        try:
            if self._audio_rec.is_active:
                self._audio_rec.stop()
        finally:
            self.notification_center.post_notification('AudioStreamDidStopRecording', sender=self, data=NotificationData(filename=self._audio_rec.filename))
            self._audio_rec = None

    def _pause(self):
        try:
            self.bridge.remove(self)
        except ValueError:
            pass

    def _resume(self):
        try:
            self.bridge.add(self)
        except ValueError:
            pass
