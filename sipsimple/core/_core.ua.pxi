
import errno
import heapq
import re
import random
import sys
import time
import traceback
import os
import tempfile


cdef class Timer:
    cdef int schedule(self, float delay, timer_callback callback, object obj) except -1:
        cdef PJSIPUA ua = _get_ua()
        if delay < 0:
            raise ValueError("delay must be a non-negative number")
        if callback == NULL:
            raise ValueError("callback must be non-NULL")
        if self._scheduled:
            raise RuntimeError("already scheduled")
        self.schedule_time = PyFloat_AsDouble(time.time() + delay)
        self.callback = callback
        self.obj = obj
        ua._add_timer(self)
        self._scheduled = 1
        return 0

    cdef int cancel(self) except -1:
        cdef PJSIPUA ua = _get_ua()
        if not self._scheduled:
            return 0
        ua._remove_timer(self)
        self._scheduled = 0
        return 0

    cdef int call(self) except -1:
        self._scheduled = 0
        self.callback(self.obj, self)

    def __richcmp__(self, other, op):
        cdef double diff
        if not isinstance(self, Timer) or not isinstance(other, Timer):
            return NotImplemented
        diff = (<Timer>self).schedule_time - (<Timer>other).schedule_time
        if op == 0: # <
            return diff < 0.0
        elif op == 1: # <=
            return diff <= 0.0
        elif op == 2: # ==
            return diff == 0.0
        elif op == 3: # !=
            return diff != 0.0
        elif op == 4: # >
            return diff > 0.0
        elif op == 5: # >=
            return diff >= 0.0
        return


cdef class PJSIPUA:
    def __cinit__(self, *args, **kwargs):
        global _ua
        if _ua != NULL:
            raise SIPCoreError("Can only have one PJSUPUA instance at the same time")
        _ua = <void *> self
        self._threads = []
        self._timers = list()
        self._events = {}
        self._incoming_events = set()
        self._incoming_requests = set()
        self._sent_messages = set()

    def __init__(self, event_handler, *args, **kwargs):
        global _event_queue_lock
        cdef object event
        cdef object method
        cdef list accept_types
        cdef int status

        cdef PJSTR message_method = PJSTR(b"MESSAGE")
        cdef PJSTR refer_method = PJSTR(b"REFER")
        cdef PJSTR str_norefersub = PJSTR(b"norefersub")
        cdef PJSTR str_gruu = PJSTR(b"gruu")

        self._event_handler = event_handler
        if kwargs["log_level"] < 0 or kwargs["log_level"] > PJ_LOG_MAX_LEVEL:
            raise ValueError("Log level should be between 0 and %d" % PJ_LOG_MAX_LEVEL)
        pj_log_set_level(kwargs["log_level"])
        pj_log_set_decor(PJ_LOG_HAS_YEAR | PJ_LOG_HAS_MONTH | PJ_LOG_HAS_DAY_OF_MON |
                         PJ_LOG_HAS_TIME | PJ_LOG_HAS_MICRO_SEC | PJ_LOG_HAS_SENDER | PJ_LOG_HAS_INDENT)
        pj_log_set_log_func(_cb_log)
        self._pjlib = PJLIB()
        pj_srand(random.getrandbits(32)) # rely on python seed for now
        self._caching_pool = PJCachingPool()
        self._pjmedia_endpoint = PJMEDIAEndpoint(self._caching_pool)
        self._pjsip_endpoint = PJSIPEndpoint(self._caching_pool, kwargs["ip_address"], kwargs["udp_port"],
                                             kwargs["tcp_port"], kwargs["tls_port"],
                                             kwargs["tls_verify_server"], kwargs["tls_ca_file"],
                                             kwargs["tls_cert_file"], kwargs["tls_privkey_file"], kwargs["tls_timeout"])
        status = pj_mutex_create_simple(self._pjsip_endpoint._pool, "event_queue_lock", &_event_queue_lock)
        if status != 0:
            raise PJSIPError("Could not initialize event queue mutex", status)

        self._ip_address = kwargs["ip_address"].encode() if kwargs["ip_address"] else None
        self.codecs = list(codec.encode() for codec in kwargs["codecs"] if codec in self.available_codecs)
        self.video_codecs = list(codec.encode() for codec in kwargs["video_codecs"] if codec in self.available_video_codecs)

        self._module_name = PJSTR(b"mod-core")
        self._module.name = self._module_name.pj_str
        self._module.id = -1
        self._module.priority = PJSIP_MOD_PRIORITY_APPLICATION
        self._module.on_rx_request = _PJSIPUA_cb_rx_request
        self._module.on_tsx_state = _Request_cb_tsx_state
        status = pjsip_endpt_register_module(self._pjsip_endpoint._obj, &self._module)
        if status != 0:
            raise PJSIPError("Could not load application module", status)

        status = pjsip_endpt_add_capability(self._pjsip_endpoint._obj, &self._module,
                                            PJSIP_H_ALLOW, NULL, 1, &message_method.pj_str)
        if status != 0:
            raise PJSIPError("Could not add MESSAGE method to supported methods", status)
        status = pjsip_endpt_add_capability(self._pjsip_endpoint._obj, &self._module,
                                            PJSIP_H_ALLOW, NULL, 1, &refer_method.pj_str)
        if status != 0:
            raise PJSIPError("Could not add REFER method to supported methods", status)
        status = pjsip_endpt_add_capability(self._pjsip_endpoint._obj, NULL,
                                            PJSIP_H_SUPPORTED, NULL, 1, &str_norefersub.pj_str)
        if status != 0:
            raise PJSIPError("Could not add 'norefsub' to Supported header", status)
        status = pjsip_endpt_add_capability(self._pjsip_endpoint._obj, NULL,
                                            PJSIP_H_SUPPORTED, NULL, 1, &str_gruu.pj_str)
        if status != 0:
            raise PJSIPError("Could not add 'gruu' to Supported header", status)

        self._opus_fix_module_name = PJSTR(b"mod-core-opus-fix")
        self._opus_fix_module.name = self._opus_fix_module_name.pj_str
        self._opus_fix_module.id = -1
        self._opus_fix_module.priority = PJSIP_MOD_PRIORITY_TRANSPORT_LAYER+1
        self._opus_fix_module.on_rx_request = _cb_opus_fix_rx
        self._opus_fix_module.on_rx_response = _cb_opus_fix_rx
        self._opus_fix_module.on_tx_request = _cb_opus_fix_tx
        self._opus_fix_module.on_tx_response = _cb_opus_fix_tx
        status = pjsip_endpt_register_module(self._pjsip_endpoint._obj, &self._opus_fix_module)
        if status != 0:
            raise PJSIPError("Could not load opus-fix module", status)

        self._trace_module_name = PJSTR(b"mod-core-sip-trace")
        self._trace_module.name = self._trace_module_name.pj_str
        self._trace_module.id = -1
        self._trace_module.priority = 0
        self._trace_module.on_rx_request = _cb_trace_rx
        self._trace_module.on_rx_response = _cb_trace_rx
        self._trace_module.on_tx_request = _cb_trace_tx
        self._trace_module.on_tx_response = _cb_trace_tx
        status = pjsip_endpt_register_module(self._pjsip_endpoint._obj, &self._trace_module)
        if status != 0:
            raise PJSIPError("Could not load sip trace module", status)

        self._ua_tag_module_name = PJSTR(b"mod-core-ua-tag")
        self._ua_tag_module.name = self._ua_tag_module_name.pj_str
        self._ua_tag_module.id = -1
        self._ua_tag_module.priority = PJSIP_MOD_PRIORITY_TRANSPORT_LAYER+1
        self._ua_tag_module.on_tx_request = _cb_add_user_agent_hdr
        self._ua_tag_module.on_tx_response = _cb_add_server_hdr
        status = pjsip_endpt_register_module(self._pjsip_endpoint._obj, &self._ua_tag_module)
        if status != 0:
            raise PJSIPError("Could not load User-Agent/Server header tagging module", status)

        self._event_module_name = PJSTR(b"mod-core-events")
        self._event_module.name = self._event_module_name.pj_str
        self._event_module.id = -1
        self._event_module.priority = PJSIP_MOD_PRIORITY_DIALOG_USAGE
        status = pjsip_endpt_register_module(self._pjsip_endpoint._obj, &self._event_module)
        if status != 0:
            raise PJSIPError("Could not load events module", status)

        self._trace_sip = int(bool(kwargs["trace_sip"]))
        self._detect_sip_loops = int(bool(kwargs["detect_sip_loops"]))
        self._enable_colorbar_device = int(bool(kwargs["enable_colorbar_device"]))
        self._user_agent = PJSTR(kwargs["user_agent"].encode())
        self.rtp_port_range = kwargs["rtp_port_range"]
        self.zrtp_cache = kwargs["zrtp_cache"].encode() if kwargs["zrtp_cache"] else None

        status = pjmedia_aud_dev_set_observer_cb(_cb_audio_dev_process_event);
        if status != 0:
            raise PJSIPError("Could not set audio_change callbacks", status)

        status = pj_rwmutex_create(self._pjsip_endpoint._pool, "ua_audio_change_rwlock", &self.audio_change_rwlock)
        if status != 0:
            raise PJSIPError("Could not initialize audio change rwmutex", status)

        status = pj_mutex_create_recursive(self._pjsip_endpoint._pool, "ua_video_lock", &self.video_lock)
        if status != 0:
            raise PJSIPError("Could not initialize video mutex", status)

        for event, accept_types in kwargs["events"].iteritems():
            self.add_event(event, accept_types)

        for event in kwargs["incoming_events"]:
            if event not in self._events.keys():
                raise ValueError('Event "%s" is not known' % event)
            self._incoming_events.add(event)

        for method in kwargs["incoming_requests"]:
            if method in ("ACK", "BYE", "INVITE", "REFER", "SUBSCRIBE"):
                raise ValueError('Handling incoming "%s" requests is not allowed' % method)
            self._incoming_requests.add(method.encode())
        pj_stun_config_init(&self._stun_cfg, &self._caching_pool._obj.factory, 0,
                            pjmedia_endpt_get_ioqueue(self._pjmedia_endpoint._obj),
                            pjsip_endpt_get_timer_heap(self._pjsip_endpoint._obj))

    property trace_sip:

        def __get__(self):
            self._check_self()
            return bool(self._trace_sip)

        def __set__(self, value):
            self._check_self()
            self._trace_sip = int(bool(value))

    property detect_sip_loops:

        def __get__(self):
            self._check_self()
            return bool(self._detect_sip_loops)

        def __set__(self, value):
            self._check_self()
            self._detect_sip_loops = int(bool(value))

    property enable_colorbar_device:

        def __get__(self):
            self._check_self()
            return bool(self._enable_colorbar_device)

        def __set__(self, value):
            self._check_self()
            self._enable_colorbar_device = int(bool(value))
            self.refresh_video_devices()

    property events:

        def __get__(self):
            self._check_self()
            return self._events.copy()

    property ip_address:

        def __get__(self):
            self._check_self()
            return self._ip_address

    def add_event(self, object event, list accept_types):
        cdef pj_str_t event_pj
        cdef pj_str_t accept_types_pj[PJSIP_MAX_ACCEPT_COUNT]
        cdef int index
        cdef object accept_type
        cdef int accept_cnt = len(accept_types)
        cdef int status
        self._check_self()
        if accept_cnt == 0:
            raise SIPCoreError("Need at least one of accept_types")
        if accept_cnt > PJSIP_MAX_ACCEPT_COUNT:
            raise SIPCoreError("Too many accept_types")
        _str_to_pj_str(event, &event_pj)
        for index, accept_type in enumerate(accept_types):
            _str_to_pj_str(accept_type, &accept_types_pj[index])
        status = pjsip_evsub_register_pkg(&self._event_module, &event_pj, 3600, accept_cnt, accept_types_pj)
        if status != 0:
            raise PJSIPError("Could not register event package", status)
        self._events[event] = accept_types[:]

    property incoming_events:

        def __get__(self):
            self._check_self()
            return self._incoming_events.copy()

    def add_incoming_event(self, object event):
        self._check_self()
        if event not in self._events.keys():
            raise ValueError('Event "%s" is not known' % event)
        self._incoming_events.add(event)

    def remove_incoming_event(self, object event):
        self._check_self()
        if event not in self._events.keys():
            raise ValueError('Event "%s" is not known' % event)
        self._incoming_events.discard(event)

    property incoming_requests:

        def __get__(self):
            self._check_self()
            return self._incoming_requests.copy()

    def add_incoming_request(self, object method):
        self._check_self()
        if method in ("ACK", "BYE", "INVITE", "REFER", "SUBSCRIBE"):
            raise ValueError('Handling incoming "%s" requests is not allowed' % method)
        self._incoming_requests.add(method.encode())

    def remove_incoming_request(self, object method):
        self._check_self()
        if method in ("ACK", "BYE", "INVITE", "REFER", "SUBSCRIBE"):
            raise ValueError('Handling incoming "%s" requests is not allowed' % method)
        self._incoming_requests.discard(method.encode())

    cdef pj_pool_t* create_memory_pool(self, bytes name, int initial_size, int resize_size):
        cdef pj_pool_t *pool
        cdef char *c_pool_name
        cdef pjsip_endpoint *endpoint

        c_pool_name = name
        endpoint = self._pjsip_endpoint._obj

        with nogil:
            pool = pjsip_endpt_create_pool(endpoint, c_pool_name, initial_size, resize_size)
        if pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")
        return pool

    cdef void release_memory_pool(self, pj_pool_t* pool):
        cdef pjsip_endpoint *endpoint
        endpoint = self._pjsip_endpoint._obj

        if pool != NULL:
            with nogil:
                pjsip_endpt_release_pool(endpoint, pool)

    cdef void reset_memory_pool(self, pj_pool_t* pool):
        if pool != NULL:
            with nogil:
                pj_pool_reset(pool)

    cdef object _get_sound_devices(self, int is_output):
        cdef int count
        cdef pjmedia_aud_dev_info info
        cdef list retval = list()
        cdef int status

        with nogil:
            status = pj_rwmutex_lock_read(self.audio_change_rwlock)
        if status != 0:
            raise PJSIPError('Could not acquire audio_change_rwlock', status)
        try:
            for i in range(pjmedia_aud_dev_count()):
                with nogil:
                    status = pjmedia_aud_dev_get_info(i, &info)
                if status != 0:
                    raise PJSIPError("Could not get audio device info", status)
                if is_output:
                    count = info.output_count
                else:
                    count = info.input_count
                if count:
                    retval.append(decode_device_name(info.name))
            return retval
        finally:
            pj_rwmutex_unlock_read(self.audio_change_rwlock)

    cdef object _get_default_sound_device(self, int is_output):
        cdef pjmedia_aud_dev_info info
        cdef int dev_id
        cdef int status
        with nogil:
            status = pj_rwmutex_lock_read(self.audio_change_rwlock)
        if status != 0:
            raise SIPCoreError('Could not acquire audio_change_rwlock', status)
        try:
            if is_output:
                dev_id = PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV
            else:
                dev_id = PJMEDIA_AUD_DEFAULT_CAPTURE_DEV
            with nogil:
                status = pjmedia_aud_dev_get_info(dev_id, &info)
            if status != 0:
                raise PJSIPError("Could not get audio device info", status)
            return decode_device_name(info.name)
        finally:
            pj_rwmutex_unlock_read(self.audio_change_rwlock)


    property default_output_device:

        def __get__(self):
            self._check_self()
            return self._get_default_sound_device(1)

    property default_input_device:

        def __get__(self):
            self._check_self()
            return self._get_default_sound_device(0)

    property output_devices:

        def __get__(self):
            self._check_self()
            return self._get_sound_devices(1)

    property input_devices:

        def __get__(self):
            self._check_self()
            return self._get_sound_devices(0)

    property sound_devices:

        def __get__(self):
            self._check_self()
            cdef int count
            cdef pjmedia_aud_dev_info info
            cdef list retval = list()
            cdef int status

            with nogil:
                status = pj_rwmutex_lock_read(self.audio_change_rwlock)
            if status != 0:
                raise SIPCoreError('Could not acquire audio_change_rwlock', status)
            try:
                for i in range(pjmedia_aud_dev_count()):
                    with nogil:
                        status = pjmedia_aud_dev_get_info(i, &info)
                    if status == 0:
                        retval.append(decode_device_name(info.name))
                return retval
            finally:
                pj_rwmutex_unlock_read(self.audio_change_rwlock)

    def refresh_sound_devices(self):
        self._check_self()
        cdef int status
        cdef dict event_dict

        self.old_devices = self.sound_devices
        with nogil:
            status = pj_rwmutex_lock_write(self.audio_change_rwlock)
        if status != 0:
            raise SIPCoreError('Could not acquire audio_change_rwlock', status)
        with nogil:
            pjmedia_aud_dev_refresh()
            status = pj_rwmutex_unlock_write(self.audio_change_rwlock)
        if status != 0:
            raise SIPCoreError('Could not release audio_change_rwlock', status)
        event_dict = dict()
        event_dict["old_devices"] = self.old_devices
        event_dict["new_devices"] = self.sound_devices
        _add_event("AudioDevicesDidChange", event_dict)

    cdef object _get_video_devices(self):
        cdef pjmedia_vid_dev_info info
        cdef list retval = list()
        cdef int direction
        cdef int status

        for i in range(pjmedia_vid_dev_count()):
            with nogil:
                status = pjmedia_vid_dev_get_info(i, &info)
            if status != 0:
                raise PJSIPError("Could not get video device info", status)
            direction = info.dir
            if direction in (PJMEDIA_DIR_CAPTURE, PJMEDIA_DIR_CAPTURE_PLAYBACK):
                if (not self._enable_colorbar_device and bytes(info.driver) == "Colorbar") or bytes(info.driver) == "Null":
                    continue
                retval.append(decode_device_name(info.name))
        return retval

    cdef object _get_default_video_device(self):
        cdef pjmedia_vid_dev_info info
        cdef int status

        with nogil:
            status = pjmedia_vid_dev_get_info(PJMEDIA_VID_DEFAULT_CAPTURE_DEV, &info)
        if status != 0:
            raise PJSIPError("Could not get default video device info", status)
        if (not self._enable_colorbar_device and bytes(info.driver) == "Colorbar") or bytes(info.driver) == "Null":
            raise SIPCoreError("Could not get default video device")
        return decode_device_name(info.name)

    def refresh_video_devices(self):
        self._check_self()
        cdef int status
        cdef dict event_dict

        self.old_video_devices = self.video_devices
        with nogil:
            pjmedia_vid_dev_refresh()
        event_dict = dict()
        event_dict["old_devices"] = self.old_video_devices
        event_dict["new_devices"] = self.video_devices
        _add_event("VideoDevicesDidChange", event_dict)

    property default_video_device:

        def __get__(self):
            self._check_self()
            return self._get_default_video_device()

    property video_devices:

        def __get__(self):
            self._check_self()
            return self._get_video_devices()

    property available_codecs:

        def __get__(self):
            self._check_self()
            return self._pjmedia_endpoint._get_all_codecs()

    property codecs:

        def __get__(self):
            self._check_self()
            return self._pjmedia_endpoint._get_current_codecs()

        def __set__(self, value):
            self._check_self()
            self._pjmedia_endpoint._set_codecs(value)

    property available_video_codecs:

        def __get__(self):
            self._check_self()
            return self._pjmedia_endpoint._get_all_video_codecs()

    property video_codecs:

        def __get__(self):
            self._check_self()
            return self._pjmedia_endpoint._get_current_video_codecs()

        def __set__(self, value):
            self._check_self()
            self._pjmedia_endpoint._set_video_codecs(value)

    property udp_port:

        def __get__(self):
            self._check_self()
            if self._pjsip_endpoint._udp_transport == NULL:
                return None
            return self._pjsip_endpoint._udp_transport.local_name.port

    def set_udp_port(self, value):
        cdef int port
        self._check_self()
        if value is None:
            if self._pjsip_endpoint._udp_transport == NULL:
                return
            self._pjsip_endpoint._stop_udp_transport()
        else:
            port = value
            if not (0 <= port <= 65535):
                raise ValueError("Not a valid UDP port: %d" % value)
            if self._pjsip_endpoint._udp_transport != NULL:
                if port == self._pjsip_endpoint._udp_transport.local_name.port:
                    return
                self._pjsip_endpoint._stop_udp_transport()
            self._pjsip_endpoint._start_udp_transport(port)

    property tcp_port:

        def __get__(self):
            self._check_self()
            if self._pjsip_endpoint._tcp_transport == NULL:
                return None
            return self._pjsip_endpoint._tcp_transport.addr_name.port

    def set_tcp_port(self, value):
        cdef int port
        self._check_self()
        if value is None:
            if self._pjsip_endpoint._tcp_transport == NULL:
                return
            self._pjsip_endpoint._stop_tcp_transport()
        else:
            port = value
            if not (0 <= port <= 65535):
                raise ValueError("Not a valid TCP port: %d" % value)
            if self._pjsip_endpoint._tcp_transport != NULL:
                if port == self._pjsip_endpoint._tcp_transport.addr_name.port:
                    return
                self._pjsip_endpoint._stop_tcp_transport()
            self._pjsip_endpoint._start_tcp_transport(port)

    property tls_port:

        def __get__(self):
            self._check_self()
            if self._pjsip_endpoint._tls_transport == NULL:
                return None
            return self._pjsip_endpoint._tls_transport.addr_name.port

    property rtp_port_range:

        def __get__(self):
            self._check_self()
            return (self._rtp_port_start, self._rtp_port_start + self._rtp_port_count)

        def __set__(self, value):
            cdef int _rtp_port_start
            cdef int _rtp_port_stop
            cdef int _rtp_port_count
            cdef int _rtp_port_usable_count
            cdef int port
            self._check_self()
            for port in value:
                if not (0 <= port <= 65535):
                    raise SIPCoreError("RTP port range values should be between 0 and 65535")
            _rtp_port_start, _rtp_port_stop = value
            _rtp_port_count = _rtp_port_stop - _rtp_port_start
            _rtp_port_usable_count = _rtp_port_count - _rtp_port_count % 2 # we need an even number of ports, so we won't use the last one if an odd number is provided
            if _rtp_port_usable_count < 2:
                raise SIPCoreError("RTP port range should contain at least 2 ports")
            self._rtp_port_start = _rtp_port_start
            self._rtp_port_count = _rtp_port_count
            self._rtp_port_usable_count = _rtp_port_usable_count
            self._rtp_port_index = 0

    property user_agent:

        def __get__(self):
            self._check_self()
            return self._user_agent.str

        def __set__(self, value):
            self._check_self()
            self._user_agent = PJSTR(b"value")

    property log_level:

        def __get__(self):
            self._check_self()
            return pj_log_get_level()

        def __set__(self, value):
            self._check_self()
            if value < 0 or value > PJ_LOG_MAX_LEVEL:
                raise ValueError("Log level should be between 0 and %d" % PJ_LOG_MAX_LEVEL)
            pj_log_set_level(value)

    property tls_verify_server:

        def __get__(self):
            self._check_self()
            return bool(self._pjsip_endpoint._tls_verify_server)

    property tls_ca_file:

        def __get__(self):
            self._check_self()
            if self._pjsip_endpoint._tls_ca_file is None:
                return None
            else:
                return self._pjsip_endpoint._tls_ca_file.str

    property tls_cert_file:

        def __get__(self):
            self._check_self()
            if self._pjsip_endpoint._tls_cert_file is None:
                return None
            else:
                return self._pjsip_endpoint._tls_cert_file.str

    property tls_privkey_file:

        def __get__(self):
            self._check_self()
            if self._pjsip_endpoint._tls_privkey_file is None:
                return None
            else:
                return self._pjsip_endpoint._tls_privkey_file.str

    property tls_timeout:

        def __get__(self):
            self._check_self()
            return self._pjsip_endpoint._tls_timeout

    def set_tls_options(self, port=None, verify_server=False,
                        ca_file=None, cert_file=None, privkey_file=None, int timeout=3000):
        cdef int c_port
        self._check_self()
        if port is None:
            if self._pjsip_endpoint._tls_transport == NULL:
                return
            self._pjsip_endpoint._stop_tls_transport()
        else:
            c_port = port
            if not (0 <= c_port <= 65535):
                raise ValueError("Not a valid TCP port: %d" % port)
            if ca_file is not None and not os.path.isfile(ca_file):
                raise ValueError("Cannot find the specified CA file: %s" % ca_file)
            if cert_file is not None and not os.path.isfile(cert_file):
                raise ValueError("Cannot find the specified certificate file: %s" % cert_file)
            if privkey_file is not None and not os.path.isfile(privkey_file):
                raise ValueError("Cannot find the specified private key file: %s" % privkey_file)
            if timeout < 0:
                raise ValueError("Invalid TLS timeout value: %d" % timeout)
            if self._pjsip_endpoint._tls_transport != NULL:
                self._pjsip_endpoint._stop_tls_transport()
            self._pjsip_endpoint._tls_verify_server = int(bool(verify_server))
            if ca_file is None:
                self._pjsip_endpoint._tls_ca_file = None
            else:
                self._pjsip_endpoint._tls_ca_file = PJSTR(ca_file.encode(sys.getfilesystemencoding()))
            if cert_file is None:
                self._pjsip_endpoint._tls_cert_file = None
            else:
                self._pjsip_endpoint._tls_cert_file = PJSTR(cert_file.encode(sys.getfilesystemencoding()))
            if privkey_file is None:
                self._pjsip_endpoint._tls_privkey_file = None
            else:
                self._pjsip_endpoint._tls_privkey_file = PJSTR(privkey_file.encode(sys.getfilesystemencoding()))
            self._pjsip_endpoint._tls_timeout = timeout
            self._pjsip_endpoint._start_tls_transport(c_port)

    def detect_nat_type(self, stun_server_address, stun_server_port=PJ_STUN_PORT, object user_data=None):
        cdef pj_str_t stun_server_address_pj
        cdef pj_sockaddr_in stun_server
        cdef int status
        self._check_self()
        if not _is_valid_ip(pj_AF_INET(), stun_server_address.encode()):
            raise ValueError("Not a valid IPv4 address: %s" % stun_server_address)
        _str_to_pj_str(stun_server_address.encode(), &stun_server_address_pj)
        status = pj_sockaddr_in_init(&stun_server, &stun_server_address_pj, stun_server_port)
        if status != 0:
            raise PJSIPError("Could not init STUN server address", status)
        status = pj_stun_detect_nat_type(&stun_server, &self._stun_cfg, <void *> user_data, _cb_detect_nat_type)
        if status != 0:
            raise PJSIPError("Could not start NAT type detection", status)
        Py_INCREF(user_data)

    def set_nameservers(self, list nameservers):
        self._check_self()
        return self._pjsip_endpoint._set_dns_nameservers([n for n in nameservers if _re_ipv4.match(n)])

    def set_h264_options(self, profile, level):
        self._check_self()
        self._pjmedia_endpoint._set_h264_options(str(profile), int(level.replace('.', '')))

    def set_video_options(self, max_resolution, int max_framerate, object max_bitrate):
        self._check_self()
        self._pjmedia_endpoint._set_video_options(tuple(max_resolution),
                                                  max_framerate,
                                                  max_bitrate or 0.0)

    property zrtp_cache:

        def __get__(self):
            self._check_self()
            return self._zrtp_cache

        def __set__(self, value):
            self._check_self()
            if value is None:
                value = os.path.join(tempfile.gettempdir(), 'zrtp_cache_%d.db' % os.getpid())
            self._zrtp_cache = value

    def __dealloc__(self):
        self.dealloc()

    def dealloc(self):
        global _ua, _dealloc_handler_queue, _event_queue_lock
        if _ua == NULL:
            return
        self._check_thread()
        pjmedia_aud_dev_set_observer_cb(NULL)
        if self.audio_change_rwlock != NULL:
            pj_rwmutex_destroy(self.audio_change_rwlock)
            self.audio_change_rwlock = NULL
        if self.video_lock != NULL:
            pj_mutex_destroy(self.video_lock)
            self.video_lock = NULL
        _process_handler_queue(self, &_dealloc_handler_queue)
        if _event_queue_lock != NULL:
            pj_mutex_lock(_event_queue_lock)
            pj_mutex_destroy(_event_queue_lock)
            _event_queue_lock = NULL
        self._pjsip_endpoint = None
        self._pjmedia_endpoint = None
        self._caching_pool = None
        self._pjlib = None
        _ua = NULL
        self._poll_log()

    cdef int _poll_log(self) except -1:
        cdef object event_name
        cdef dict event_params
        cdef list events
        events = _get_clear_event_queue()
        for event_name, event_params in events:
            self._event_handler(event_name, **event_params)

    def poll(self):
        global _post_poll_handler_queue
        cdef int status
        cdef double now
        cdef object retval = None
        cdef float max_timeout
        cdef pj_time_val pj_max_timeout
        cdef list timers
        cdef Timer timer

        self._check_self()

        max_timeout = 0.100
        while self._timers:
            if not (<Timer>self._timers[0])._scheduled:
                # timer was cancelled
                heapq.heappop(self._timers)
            else:
                max_timeout = min(max((<Timer>self._timers[0]).schedule_time - time.time(), 0.0), max_timeout)
                break
        pj_max_timeout.sec = int(max_timeout)
        pj_max_timeout.msec = int(max_timeout * 1000) % 1000
        with nogil:
            status = pjsip_endpt_handle_events(self._pjsip_endpoint._obj, &pj_max_timeout)
        IF UNAME_SYSNAME == "Darwin":
            if status not in [0, PJ_ERRNO_START_SYS + errno.EBADF]:
                raise PJSIPError("Error while handling events", status)
        ELSE:
            if status != 0:
                raise PJSIPError("Error while handling events", status)
        _process_handler_queue(self, &_post_poll_handler_queue)

        timers = list()
        now = time.time()
        while self._timers:
            if not (<Timer>self._timers[0])._scheduled:
                # timer was cancelled
                heapq.heappop(self._timers)
            elif (<Timer>self._timers[0]).schedule_time <= now:
                # timer needs to be processed
                timer = heapq.heappop(self._timers)
                timers.append(timer)
            else:
                break
        for timer in timers:
            timer.call()

        self._poll_log()
        if self._fatal_error:
            return True
        else:
            return False

    cdef int _handle_exception(self, int is_fatal) except -1:
        cdef object exc_type
        cdef object exc_val
        cdef object exc_tb
        exc_type, exc_val, exc_tb = sys.exc_info()
        if is_fatal:
            self._fatal_error = is_fatal
        _add_event("SIPEngineGotException",
                    dict(type=exc_type, value=exc_val,
                         traceback="".join(traceback.format_exception(exc_type, exc_val, exc_tb))))
        return 0

    cdef int _check_self(self) except -1:
        global _ua
        if _ua == NULL:
            raise SIPCoreError("The PJSIPUA is no longer running")
        self._check_thread()

    cdef int _check_thread(self) except -1:
        if not pj_thread_is_registered():
            self._threads.append(PJSIPThread())
        return 0

    cdef int _add_timer(self, Timer timer) except -1:
        heapq.heappush(self._timers, timer)
        return 0

    cdef int _remove_timer(self, Timer timer) except -1:
        # Don't remove it from the heap, just mark it as not scheduled
        timer._scheduled = 0
        return 0

    cdef int _cb_rx_request(self, pjsip_rx_data *rdata) except 0:
        global _event_hdr_name
        cdef int status
        cdef int bad_request
        cdef pjsip_tx_data *tdata = NULL
        cdef pjsip_hdr_ptr_const hdr_add
        cdef IncomingRequest request
        cdef Invitation inv
        cdef IncomingSubscription sub
        cdef IncomingReferral ref
        cdef list extra_headers
        cdef dict event_dict
        cdef dict message_params
        cdef pj_str_t tsx_key
        cdef pjsip_via_hdr *top_via
        cdef pjsip_via_hdr *via
        cdef pjsip_transaction *tsx = NULL
        cdef unsigned int options = PJSIP_INV_SUPPORT_100REL
        cdef pjsip_event_hdr *event_hdr
        cdef object method_name = _pj_str_to_bytes(rdata.msg_info.msg.line.req.method.name)
        if method_name != b"ACK":
            if self._detect_sip_loops:
                # Temporarily trick PJSIP into believing the last Via header is actually the first
                top_via = via = rdata.msg_info.via
                while True:
                    rdata.msg_info.via = via
                    via = <pjsip_via_hdr *> pjsip_msg_find_hdr(rdata.msg_info.msg, PJSIP_H_VIA, (<pj_list *> via).next)
                    if via == NULL:
                        break
                status = pjsip_tsx_create_key(rdata.tp_info.pool, &tsx_key,
                                              PJSIP_ROLE_UAC, &rdata.msg_info.msg.line.req.method, rdata)
                rdata.msg_info.via = top_via
                if status != 0:
                    raise PJSIPError("Could not generate transaction key for incoming request", status)
                tsx = pjsip_tsx_layer_find_tsx(&tsx_key, 0)
        if tsx != NULL:
            status = pjsip_endpt_create_response(self._pjsip_endpoint._obj, rdata, 482, NULL, &tdata)
            if status != 0:
                raise PJSIPError("Could not create response", status)
        elif method_name in self._incoming_requests:
            request = IncomingRequest()
            request.init(self, rdata)
        elif method_name == b"OPTIONS":
            status = pjsip_endpt_create_response(self._pjsip_endpoint._obj, rdata, 200, NULL, &tdata)
            if status != 0:
                raise PJSIPError("Could not create response", status)
            for hdr_type in [PJSIP_H_ALLOW, PJSIP_H_ACCEPT, PJSIP_H_SUPPORTED]:
                hdr_add = pjsip_endpt_get_capability(self._pjsip_endpoint._obj, hdr_type, NULL)
                if hdr_add != NULL:
                    pjsip_msg_add_hdr(tdata.msg, <pjsip_hdr *> pjsip_hdr_clone(tdata.pool, hdr_add))
        elif method_name == b"INVITE":
            status = pjsip_inv_verify_request(rdata, &options, NULL, NULL, self._pjsip_endpoint._obj, &tdata)
            if status == 0:
                inv = Invitation()
                inv.init_incoming(self, rdata, options)
        elif method_name == b"SUBSCRIBE":
            event_hdr = <pjsip_event_hdr *> pjsip_msg_find_hdr_by_name(rdata.msg_info.msg, &_event_hdr_name.pj_str, NULL)
            if event_hdr == NULL or _pj_str_to_bytes(event_hdr.event_type) not in self._incoming_events:
                status = pjsip_endpt_create_response(self._pjsip_endpoint._obj, rdata, 489, NULL, &tdata)
                if status != 0:
                    raise PJSIPError("Could not create response", status)
            else:
                sub = IncomingSubscription()
                sub.init(self, rdata, _pj_str_to_bytes(event_hdr.event_type))
        elif method_name == b"REFER":
            ref = IncomingReferral()
            ref.init(self, rdata)
        elif method_name == b"MESSAGE":
            bad_request = 0
            extra_headers = list()
            message_params = dict()
            event_dict = dict()
            _pjsip_msg_to_dict(rdata.msg_info.msg, event_dict)
            message_params["request_uri"] = event_dict["request_uri"]
            message_params["from_header"] = event_dict["headers"].get("From", None)
            message_params["to_header"] = event_dict["headers"].get("To", None)
            message_params["headers"] = event_dict["headers"]
            message_params["body"] = event_dict["body"]
            content_type = message_params["headers"].get("Content-Type", None)
            if content_type is not None:
                message_params["content_type"] = content_type.content_type
                if message_params["headers"].get("Content-Length", 0) > 0 and message_params["body"] is None:
                    bad_request = 1
                    extra_headers.append(WarningHeader(399, "local", "Missing body"))
            else:
                message_params["content_type"] = None
                if message_params["headers"].get("Content-Length", 0) > 0 and message_params["body"] is None:
                    bad_request = 1
                    extra_headers.append(WarningHeader(399, "local", "Missing Content-Type header"))
            if bad_request:
                status = pjsip_endpt_create_response(self._pjsip_endpoint._obj, rdata, 400, NULL, &tdata)
                if status != 0:
                    raise PJSIPError("Could not create response", status)
                _add_headers_to_tdata(tdata, extra_headers)
            else:
                _add_event("SIPEngineGotMessage", message_params)
                status = pjsip_endpt_create_response(self._pjsip_endpoint._obj, rdata, 200, NULL, &tdata)
                if status != 0:
                    raise PJSIPError("Could not create response", status)
        elif method_name != b"ACK":
            status = pjsip_endpt_create_response(self._pjsip_endpoint._obj, rdata, 405, NULL, &tdata)
            if status != 0:
                raise PJSIPError("Could not create response", status)
        if tdata != NULL:
            status = pjsip_endpt_send_response2(self._pjsip_endpoint._obj, rdata, tdata, NULL, NULL)
            if status != 0:
                pjsip_tx_data_dec_ref(tdata)
                raise PJSIPError("Could not send response", status)
        return 1


cdef class PJSIPThread:
    def __cinit__(self):
        str_id = "python_%d" % id(self)
        cdef object thread_name = str_id.encode()
        cdef int status
        status = pj_thread_register(thread_name, self._thread_desc, &self._obj)
        if status != 0:
            raise PJSIPError("Error while registering thread", status)


# callback functions

cdef void _cb_audio_dev_process_event_impl(pjmedia_aud_dev_event event) with gil:
    cdef PJSIPUA ua
    event_dict = dict()
    try:
       ua = _get_ua()
    except:
       return
    try:
        if event in (PJMEDIA_AUD_DEV_DEFAULT_INPUT_CHANGED, PJMEDIA_AUD_DEV_DEFAULT_OUTPUT_CHANGED):
            event_dict["changed_input"] = event == PJMEDIA_AUD_DEV_DEFAULT_INPUT_CHANGED
            event_dict["changed_output"] = event == PJMEDIA_AUD_DEV_DEFAULT_OUTPUT_CHANGED
            _add_event("DefaultAudioDeviceDidChange", event_dict)
        elif event == PJMEDIA_AUD_DEV_LIST_WILL_REFRESH:
            ua.old_devices = ua.sound_devices
            with nogil:
                status = pj_rwmutex_lock_write(ua.audio_change_rwlock)
            if status != 0:
                raise SIPCoreError('Could not acquire audio_change_rwlock for writing', status)
        elif event == PJMEDIA_AUD_DEV_LIST_DID_REFRESH:
            with nogil:
                status = pj_rwmutex_unlock_write(ua.audio_change_rwlock)
            if status != 0:
                raise SIPCoreError('Could not release the audio_change_rwlock', status)
            event_dict["old_devices"] = ua.old_devices
            event_dict["new_devices"] = ua.sound_devices
            _add_event("AudioDevicesDidChange", event_dict)
    except:
        ua._handle_exception(1)

cdef void _cb_audio_dev_process_event(pjmedia_aud_dev_event event) noexcept nogil:
    with gil:
        _cb_audio_dev_process_event_impl(event)

cdef void _cb_detect_nat_type_impl(void *user_data, pj_stun_nat_detect_result_ptr_const res) with gil:
    cdef PJSIPUA ua
    cdef dict event_dict
    cdef object user_data_obj = <object> user_data
    Py_DECREF(user_data_obj)
    try:
        ua = _get_ua()
    except:
        return
    try:
        event_dict = dict()
        event_dict["succeeded"] = res.status == 0
        event_dict["user_data"] = user_data_obj
        if res.status == 0:
            event_dict["nat_type"] = res.nat_type_name
        else:
            event_dict["error"] = res.status_text
        _add_event("SIPEngineDetectedNATType", event_dict)
    except:
        ua._handle_exception(0)

cdef void _cb_detect_nat_type(void *user_data, pj_stun_nat_detect_result_ptr_const res) noexcept nogil:
    with gil:
        _cb_detect_nat_type_impl(user_data, res)

cdef int _PJSIPUA_cb_rx_request_impl(pjsip_rx_data *rdata) with gil:
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return 0
    try:
        return ua._cb_rx_request(rdata)
    except:
        ua._handle_exception(0)

cdef int _PJSIPUA_cb_rx_request(pjsip_rx_data *rdata) noexcept nogil:
    cdef int result
    with gil:
        result = _PJSIPUA_cb_rx_request_impl(rdata)
    return result

cdef int _cb_opus_fix_tx_impl(pjsip_tx_data *tdata) with gil:
    cdef PJSIPUA ua
    cdef pjsip_msg_body *body
    cdef pjsip_msg_body *new_body
    cdef pjmedia_sdp_session *sdp
    cdef pjmedia_sdp_media *media
    cdef pjmedia_sdp_attr *attr
    cdef pj_str_t new_value
    try:
        ua = _get_ua()
    except:
        return 0
    try:
        if tdata != NULL and tdata.msg != NULL:
            body = tdata.msg.body
            if body != NULL and _pj_str_to_str(body.content_type.type).lower() == "application" and _pj_str_to_str(body.content_type.subtype).lower() == "sdp":
                new_body = pjsip_msg_body_clone(tdata.pool, body)
                sdp = <pjmedia_sdp_session *> new_body.data
                for i in range(sdp.media_count):
                    media = sdp.media[i]
                    if _pj_str_to_str(media.desc.media).lower() != "audio":
                        continue
                    for j in range(media.attr_count):
                        attr = media.attr[j]
                        if _pj_str_to_str(attr.name).lower() != "rtpmap":
                            continue
                        attr_value = _pj_str_to_str(attr.value).lower()
                        pos = attr_value.find("opus")
                        if pos == -1:
                            continue
                        # this is the opus rtpmap attribute
                        opus_line = attr_value[:pos] + "opus/48000/2"
                        opus_line = opus_line.encode()
                        new_value.slen = len(opus_line)
                        new_value.ptr = <char *> pj_pool_alloc(tdata.pool, new_value.slen)
                        memcpy(new_value.ptr, PyBytes_AsString(opus_line), new_value.slen)
                        attr.value = new_value
                        break
                tdata.msg.body = new_body
    except:
        ua._handle_exception(0)
    return 0

cdef int _cb_opus_fix_tx(pjsip_tx_data *tdata) noexcept nogil:
    cdef int result
    with gil:
        result = _cb_opus_fix_tx_impl(tdata)
    return result

cdef int _cb_opus_fix_rx_impl(pjsip_rx_data *rdata) with gil:
    cdef PJSIPUA ua
    cdef pjsip_msg_body *body
    cdef int pos1
    cdef int pos2
    cdef char *body_ptr
    try:
        ua = _get_ua()
    except:
        return 0
    try:
        if rdata != NULL and rdata.msg_info.msg != NULL:
            body = rdata.msg_info.msg.body
            if body != NULL and _pj_str_to_str(body.content_type.type).lower() == "application" and _pj_str_to_str(body.content_type.subtype).lower() == "sdp":
                body_ptr = <char*>body.data
                body_str = _pj_buf_len_to_str(body_ptr, body.len).decode().lower()
                pos1 = body_str.find("opus/48000")
                if pos1 != -1:
                    pos2 = body_str.find("opus/48000/2")
                    if pos2 != -1:
                        memcpy(body_ptr + pos2 + 11, b'1', 1)
                    else:
                        # old opus, we must make it fail
                        memcpy(body_ptr + pos1 + 5, b'XXXXX', 5)
    except:
        ua._handle_exception(0)
    return 0

cdef int _cb_opus_fix_rx(pjsip_rx_data *rdata) noexcept nogil:
    cdef int result
    with gil:
        result = _cb_opus_fix_rx_impl(rdata)
    return result

cdef int _cb_trace_rx_impl(pjsip_rx_data *rdata) with gil:
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return 0
    try:
        if ua._trace_sip:
            _add_event("SIPEngineSIPTrace",
                        dict(received=True,
                             source_ip=rdata.pkt_info.src_name.decode(),
                             source_port=rdata.pkt_info.src_port,
                             destination_ip=_pj_str_to_str(rdata.tp_info.transport.local_name.host),
                             destination_port=rdata.tp_info.transport.local_name.port,
                             data=_pj_buf_len_to_str(rdata.pkt_info.packet, rdata.pkt_info.len),
                             transport=rdata.tp_info.transport.type_name.decode()))
    except:
        ua._handle_exception(0)
    return 0

cdef int _cb_trace_rx(pjsip_rx_data *rdata) noexcept nogil:
    cdef int result
    with gil:
        result = _cb_trace_rx_impl(rdata)
    return result

cdef int _cb_trace_tx_impl(pjsip_tx_data *tdata) with gil:
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return 0
    try:
        if ua._trace_sip:
            _add_event("SIPEngineSIPTrace",
                        dict(received=False,
                             source_ip=_pj_str_to_str(tdata.tp_info.transport.local_name.host),
                             source_port=tdata.tp_info.transport.local_name.port,
                             destination_ip=tdata.tp_info.dst_name.decode(),
                             destination_port=tdata.tp_info.dst_port,
                             data=_pj_buf_len_to_str(tdata.buf.start, tdata.buf.cur - tdata.buf.start),
                             transport=tdata.tp_info.transport.type_name.decode()))
    except:
        ua._handle_exception(0)
    return 0

cdef int _cb_trace_tx(pjsip_tx_data *tdata) noexcept nogil:
    cdef int result
    with gil:
        result = _cb_trace_tx_impl(tdata)
    return result

cdef int _cb_add_user_agent_hdr_impl(pjsip_tx_data *tdata) with gil:
    cdef PJSIPUA ua
    cdef pjsip_hdr *hdr
    cdef void *found_hdr
    try:
        ua = _get_ua()
    except:
        return 0
    try:
        found_hdr = pjsip_msg_find_hdr_by_name(tdata.msg, &_user_agent_hdr_name.pj_str, NULL)
        if found_hdr == NULL:
            hdr = <pjsip_hdr *> pjsip_generic_string_hdr_create(tdata.pool, &_user_agent_hdr_name.pj_str,
                                                                &ua._user_agent.pj_str)
            if hdr == NULL:
                raise SIPCoreError('Could not add "User-Agent" header to outgoing request')
            pjsip_msg_add_hdr(tdata.msg, hdr)
    except:
        ua._handle_exception(0)
    return 0

cdef int _cb_add_user_agent_hdr(pjsip_tx_data *tdata) noexcept nogil:
    cdef int result
    with gil:
        result = _cb_add_user_agent_hdr_impl(tdata)
    return result

cdef int _cb_add_server_hdr_impl(pjsip_tx_data *tdata) with gil:
    cdef PJSIPUA ua
    cdef pjsip_hdr *hdr
    cdef void *found_hdr
    try:
        ua = _get_ua()
    except:
        return 0
    try:
        found_hdr = pjsip_msg_find_hdr_by_name(tdata.msg, &_server_hdr_name.pj_str, NULL)
        if found_hdr == NULL:
            hdr = <pjsip_hdr *> pjsip_generic_string_hdr_create(tdata.pool, &_server_hdr_name.pj_str,
                                                                &ua._user_agent.pj_str)
            if hdr == NULL:
                raise SIPCoreError('Could not add "Server" header to outgoing response')
            pjsip_msg_add_hdr(tdata.msg, hdr)
    except:
        ua._handle_exception(0)
    return 0

cdef int _cb_add_server_hdr(pjsip_tx_data *tdata) noexcept nogil:
    cdef int result
    with gil:
        result = _cb_add_server_hdr_impl(tdata)
    return result

# functions

cdef PJSIPUA _get_ua():
    global _ua
    cdef PJSIPUA ua
    if _ua == NULL:
        raise SIPCoreError("PJSIPUA is not instantiated")
    ua = <object> _ua
    ua._check_thread()
    return ua

cdef int deallocate_weakref(object weak_ref, object timer) except -1:
    Py_DECREF(weak_ref)


# globals

cdef void *_ua = NULL
cdef PJSTR _user_agent_hdr_name = PJSTR(b"User-Agent")
cdef PJSTR _server_hdr_name = PJSTR(b"Server")
cdef PJSTR _event_hdr_name = PJSTR(b"Event")
cdef object _re_ipv4 = re.compile(r"^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$")
