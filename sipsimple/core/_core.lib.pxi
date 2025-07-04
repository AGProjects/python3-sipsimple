
import sys


# classes

cdef class PJLIB:
    def __cinit__(self):
        cdef int status
        status = pj_init()
        if status != 0:
            raise PJSIPError("Could not initialize PJLIB", status)
        self._init_done = 1
        status = pjlib_util_init()
        if status != 0:
            raise PJSIPError("Could not initialize PJLIB-UTIL", status)
        status = pjnath_init()
        if status != 0:
            raise PJSIPError("Could not initialize PJNATH", status)

    def __dealloc__(self):
        if self._init_done:
            with nogil:
                pj_shutdown()


cdef class PJCachingPool:
    def __cinit__(self):
        pj_caching_pool_init(&self._obj, &pj_pool_factory_default_policy, 0)
        self._init_done = 1

    def __dealloc__(self):
        if self._init_done:
            pj_caching_pool_destroy(&self._obj)


cdef class PJSIPEndpoint:
    def __cinit__(self, PJCachingPool caching_pool, ip_address, udp_port, tcp_port, tls_port,
                  tls_verify_server, tls_ca_file, tls_cert_file, tls_privkey_file, int tls_timeout):
        cdef pj_dns_resolver *resolver
        cdef pjsip_tpmgr *tpmgr
        cdef int status

        if ip_address is not None and not _is_valid_ip(pj_AF_INET(), ip_address.encode()):
            raise ValueError("Not a valid IPv4 address: %s" % ip_address)
        self._local_ip_used = ip_address

        status = pjsip_endpt_create(&caching_pool._obj.factory, "core",  &self._obj)
        if status != 0:
            raise PJSIPError("Could not initialize PJSIP endpoint", status)
        self._pool = pjsip_endpt_create_pool(self._obj, "PJSIPEndpoint", 4096, 4096)
        if self._pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")

        status = pjsip_tsx_layer_init_module(self._obj)
        if status != 0:
            raise PJSIPError("Could not initialize transaction layer module", status)
        status = pjsip_ua_init_module(self._obj, NULL) # TODO: handle forking
        if status != 0:
            raise PJSIPError("Could not initialize common dialog layer module", status)
        status = pjsip_evsub_init_module(self._obj)
        if status != 0:
            raise PJSIPError("Could not initialize event subscription module", status)
        status = pjsip_100rel_init_module(self._obj)
        if status != 0:
            raise PJSIPError("Could not initialize 100rel module", status)
        status = pjsip_replaces_init_module(self._obj)
        if status != 0:
            raise PJSIPError("Could not initialize replaces module", status)
        status = pjsip_inv_usage_init(self._obj, &_inv_cb)
        if status != 0:
            raise PJSIPError("Could not initialize invitation module", status)
        status = pjsip_endpt_create_resolver(self._obj, &resolver)
        if status != 0:
            raise PJSIPError("Could not create fake DNS resolver for endpoint", status)
        status = pjsip_endpt_set_resolver(self._obj, resolver)
        if status != 0:
            raise PJSIPError("Could not set fake DNS resolver on endpoint", status)

        tpmgr = pjsip_endpt_get_tpmgr(self._obj)
        if tpmgr == NULL:
            raise SIPCoreError("Could not get the transport manager")
        status = pjsip_tpmgr_set_state_cb(tpmgr, _transport_state_cb)
        if status != 0:
            raise PJSIPError("Could not set transport state callback", status)
        if udp_port is not None:
            self._start_udp_transport(udp_port)
        if tcp_port is not None:
            self._start_tcp_transport(tcp_port)
        self._tls_verify_server = int(tls_verify_server)
        if tls_ca_file is not None:
            self._tls_ca_file = PJSTR(tls_ca_file.encode(sys.getfilesystemencoding()))
        if tls_cert_file is not None:
            self._tls_cert_file = PJSTR(tls_cert_file.encode(sys.getfilesystemencoding()))
        if tls_privkey_file is not None:
            self._tls_privkey_file = PJSTR(tls_privkey_file.encode(sys.getfilesystemencoding()))
        if tls_timeout < 0:
            raise ValueError("Invalid TLS timeout value: %d" % tls_timeout)
        self._tls_timeout = tls_timeout
        if tls_port is not None:
            self._start_tls_transport(tls_port)

    cdef int _make_local_addr(self, pj_sockaddr_in *local_addr, object ip_address, int port) except -1:
        cdef pj_str_t local_ip_pj
        cdef pj_str_t *local_ip_p = NULL
        cdef int status
        if not (0 <= port <= 65535):
            raise SIPCoreError("Invalid port: %d" % port)
        if ip_address is not None and ip_address is not "0.0.0.0":
            local_ip_p = &local_ip_pj
            _str_to_pj_str(ip_address.encode(), local_ip_p)
        status = pj_sockaddr_in_init(local_addr, local_ip_p, port)
        if status != 0:
            raise PJSIPError("Could not create local address", status)
        return 0

    cdef int _start_udp_transport(self, int port) except -1:
        cdef pj_sockaddr_in local_addr
        self._make_local_addr(&local_addr, self._local_ip_used, port)
        status = pjsip_udp_transport_start(self._obj, &local_addr, NULL, 1, &self._udp_transport)
        if status != 0:
            raise PJSIPError("Could not create UDP transport", status)
        return 0

    cdef int _stop_udp_transport(self) except -1:
        pjsip_transport_shutdown(self._udp_transport)
        self._udp_transport = NULL
        return 0

    cdef int _start_tcp_transport(self, int port) except -1:
        cdef pj_sockaddr_in local_addr
        self._make_local_addr(&local_addr, self._local_ip_used, port)
        status = pjsip_tcp_transport_start2(self._obj, &local_addr, NULL, 1, &self._tcp_transport)
        if status != 0:
            raise PJSIPError("Could not create TCP transport", status)
        return 0

    cdef int _stop_tcp_transport(self) except -1:
        self._tcp_transport.destroy(self._tcp_transport)
        self._tcp_transport = NULL
        return 0

    cdef int _start_tls_transport(self, port) except -1:
        cdef pj_sockaddr_in local_addr
        cdef pjsip_tls_setting tls_setting
        self._make_local_addr(&local_addr, self._local_ip_used, port)
        pjsip_tls_setting_default(&tls_setting)
        # The following value needs to be reasonably low, as TLS negotiation hogs the PJSIP polling loop
        tls_setting.timeout.sec = <long>(self._tls_timeout / 1000)
        tls_setting.timeout.msec = self._tls_timeout % 1000
        if self._tls_ca_file is not None:
            tls_setting.ca_list_file = self._tls_ca_file.pj_str
        if self._tls_cert_file is not None:
            tls_setting.cert_file = self._tls_cert_file.pj_str
        if self._tls_privkey_file is not None:
            tls_setting.privkey_file = self._tls_privkey_file.pj_str
        tls_setting.method = PJSIP_SSLV23_METHOD
        tls_setting.verify_server = self._tls_verify_server
        status = pjsip_tls_transport_start(self._obj, &tls_setting, &local_addr, NULL, 1, &self._tls_transport)
        if status in (PJSIP_TLS_EUNKNOWN, PJSIP_TLS_EINVMETHOD, PJSIP_TLS_ECACERT, PJSIP_TLS_ECERTFILE, PJSIP_TLS_EKEYFILE, PJSIP_TLS_ECIPHER, PJSIP_TLS_ECTX):
            raise PJSIPTLSError("Could not create TLS transport", status)
        elif status != 0:
            raise PJSIPError("Could not create TLS transport", status)
        return 0

    cdef int _stop_tls_transport(self) except -1:
        self._tls_transport.destroy(self._tls_transport)
        self._tls_transport = NULL
        return 0

    cdef int _set_dns_nameservers(self, list servers) except -1:
        cdef int num_servers = len(servers)
        cdef pj_str_t *pj_servers
        cdef int status
        cdef pj_dns_resolver *resolver

        if num_servers == 0:
            return 0

        resolver = pjsip_endpt_get_resolver(self._obj)
        if resolver == NULL:
            raise SIPCoreError("Could not get DNS resolver on endpoint")

        pj_servers = <pj_str_t *> malloc(sizeof(pj_str_t))
        if pj_servers == NULL:
            raise MemoryError()

	# set only 1st nameserver
        _str_to_pj_str(servers[0].encode(), &pj_servers[0])
        status = pj_dns_resolver_set_ns(resolver, 1, pj_servers, NULL)
        free(pj_servers)
        if status != 0:
            raise PJSIPError("Could not set nameservers on DNS resolver", status)

        return 0

    def __dealloc__(self):
        cdef pjsip_tpmgr *tpmgr
        tpmgr = pjsip_endpt_get_tpmgr(self._obj)
        if tpmgr != NULL:
            pjsip_tpmgr_set_state_cb(tpmgr, NULL)
        if self._udp_transport != NULL:
            self._stop_udp_transport()
        if self._tcp_transport != NULL:
            self._stop_tcp_transport()
        if self._tls_transport != NULL:
            self._stop_tls_transport()
        if self._pool != NULL:
            pjsip_endpt_release_pool(self._obj, self._pool)
        if self._obj != NULL:
            with nogil:
                pjsip_endpt_destroy(self._obj)


cdef class PJMEDIAEndpoint:
    def __cinit__(self, PJCachingPool caching_pool):
        cdef int status
        status = pjmedia_endpt_create(&caching_pool._obj.factory, NULL, 1, &self._obj)
        if status != 0:
            raise PJSIPError("Could not create PJMEDIA endpoint", status)
        self._pool = pjmedia_endpt_create_pool(self._obj, "PJMEDIAEndpoint", 4096, 4096)
        if self._pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")

        self._audio_subsystem_init(caching_pool)
        self._video_subsystem_init(caching_pool)

    def __dealloc__(self):
        self._audio_subsystem_shutdown()
        self._video_subsystem_shutdown()
        if self._pool != NULL:
            pj_pool_release(self._pool)
        if self._obj != NULL:
            with nogil:
                pjmedia_endpt_destroy(self._obj)

    cdef void _audio_subsystem_init(self, PJCachingPool caching_pool):
        cdef int status
        cdef pjmedia_audio_codec_config audio_codec_cfg

        pjmedia_audio_codec_config_default(&audio_codec_cfg)
        audio_codec_cfg.speex.option = PJMEDIA_SPEEX_NO_NB
        audio_codec_cfg.ilbc.mode = 30

        status = pjmedia_codec_register_audio_codecs(self._obj, &audio_codec_cfg)
        if status != 0:
            raise PJSIPError("Could not initialize audio codecs", status)
        self._has_audio_codecs = 1

    cdef void _audio_subsystem_shutdown(self):
        pass

    cdef void _video_subsystem_init(self, PJCachingPool caching_pool):
        cdef int status

        status = pjmedia_video_format_mgr_create(self._pool, 64, 0, NULL)
        if status != 0:
            raise PJSIPError("Could not initialize video format manager", status)
        status = pjmedia_converter_mgr_create(self._pool, NULL)
        if status != 0:
            raise PJSIPError("Could not initialize converter manager", status)
        status = pjmedia_event_mgr_create(self._pool, 0, NULL)
        if status != 0:
            raise PJSIPError("Could not initialize event manager", status)
        status = pjmedia_vid_codec_mgr_create(self._pool, NULL)
        if status != 0:
            raise PJSIPError("Could not initialize video codec manager", status)
        status = pjmedia_codec_ffmpeg_vid_init(NULL, &caching_pool._obj.factory)
        if status != 0:
            raise PJSIPError("Could not initialize ffmpeg video codecs", status)
        self._has_ffmpeg_video = 1
        status = pjmedia_codec_vpx_vid_init(NULL, &caching_pool._obj.factory)
        if status != 0:
            raise PJSIPError("Could not initialize vpx video codecs", status)
        self._has_vpx = 1
        status = pjmedia_vid_dev_subsys_init(&caching_pool._obj.factory)
        if status != 0:
            raise PJSIPError("Could not initialize video subsystem", status)
        self._has_video = 1

    cdef void _video_subsystem_shutdown(self):
        if self._has_video:
            pjmedia_vid_dev_subsys_shutdown()
        if self._has_ffmpeg_video:
            pjmedia_codec_ffmpeg_vid_deinit()
        if self._has_vpx:
            pjmedia_codec_vpx_vid_deinit()
        if pjmedia_vid_codec_mgr_instance() != NULL:
            pjmedia_vid_codec_mgr_destroy(NULL)
        if pjmedia_event_mgr_instance() != NULL:
            pjmedia_event_mgr_destroy(NULL)
        if pjmedia_converter_mgr_instance() != NULL:
            pjmedia_converter_mgr_destroy(NULL)
        if pjmedia_video_format_mgr_instance() != NULL:
            pjmedia_video_format_mgr_destroy(NULL)

    cdef list _get_codecs(self):
        cdef unsigned int count = PJMEDIA_CODEC_MGR_MAX_CODECS
        cdef pjmedia_codec_info info[PJMEDIA_CODEC_MGR_MAX_CODECS]
        cdef unsigned int prio[PJMEDIA_CODEC_MGR_MAX_CODECS]
        cdef list retval
        cdef int status
        status = pjmedia_codec_mgr_enum_codecs(pjmedia_endpt_get_codec_mgr(self._obj), &count, info, prio)
        if status != 0:
            raise PJSIPError("Could not get available codecs", status)
        retval = list()
        for i from 0 <= i < count:
            retval.append((prio[i], _pj_str_to_bytes(info[i].encoding_name), info[i].channel_cnt, info[i].clock_rate))
        return retval

    cdef list _get_all_codecs(self):
        cdef list codecs
        cdef tuple codec_data
        codecs = self._get_codecs()
        return list(set([codec_data[1] for codec_data in codecs]))

    cdef list _get_current_codecs(self):
        cdef list codecs
        cdef tuple codec_data
        cdef list retval
        codecs = [codec_data for codec_data in self._get_codecs() if codec_data[0] > 0]
        codecs.sort(reverse=True)
        retval = list(set([codec_data[1] for codec_data in codecs]))
        return retval

    cdef int _set_codecs(self, list req_codecs) except -1:
        cdef object new_codecs
        cdef object all_codecs
        cdef object codec_set
        cdef list codecs
        cdef tuple codec_data
        cdef object codec
        cdef int sample_rate
        cdef int channel_count
        cdef object codec_name
        cdef int prio
        cdef list codec_prio
        cdef pj_str_t codec_pj
        new_codecs = set(req_codecs)
        if len(new_codecs) != len(req_codecs):
            raise ValueError("Requested codec list contains doubles")
        all_codecs = set(self._get_all_codecs())
        codec_set = new_codecs.difference(all_codecs)
        if len(codec_set) > 0:
            raise SIPCoreError("Unknown audio codecs: %s" % ", ".join(cdc.decode() for cdc in codec_set))
        # reverse the codec data tuples so that we can easily sort on sample rate
        # to make sure that bigger sample rates get higher priority
        codecs = [list(reversed(codec_data)) for codec_data in self._get_codecs()]
        codecs.sort(reverse=True)
        codec_prio = list()
        
        for codec in req_codecs:
            for sample_rate, channel_count, codec_name, prio in codecs:
                if codec == codec_name and channel_count == 1:
                    codec_prio.append("%s/%d/%d" % (codec_name.decode(), sample_rate, channel_count))
        for prio, codec in enumerate(reversed(codec_prio)):
            _str_to_pj_str(codec.encode(), &codec_pj)
            status = pjmedia_codec_mgr_set_codec_priority(pjmedia_endpt_get_codec_mgr(self._obj), &codec_pj, prio + 1)
            if status != 0:
                raise PJSIPError("Could not set codec priority", status)
        for sample_rate, channel_count, codec_name, prio in codecs:
            if codec_name not in req_codecs or channel_count > 1:
                codec = "%s/%d/%d" % (codec_name.decode(), sample_rate, channel_count)
                _str_to_pj_str(codec.encode(), &codec_pj)
                status = pjmedia_codec_mgr_set_codec_priority(pjmedia_endpt_get_codec_mgr(self._obj), &codec_pj, 0)
                if status != 0:
                    raise PJSIPError("Could not set codec priority", status)
        return 0

    cdef list _get_video_codecs(self):
        cdef unsigned int count = PJMEDIA_VID_CODEC_MGR_MAX_CODECS
        cdef pjmedia_vid_codec_info info[PJMEDIA_VID_CODEC_MGR_MAX_CODECS]
        cdef unsigned int prio[PJMEDIA_VID_CODEC_MGR_MAX_CODECS]
        cdef list retval
        cdef int status
        status = pjmedia_vid_codec_mgr_enum_codecs(NULL, &count, info, prio)
        if status != 0:
            raise PJSIPError("Could not get available video codecs", status)
        retval = list()
        for i from 0 <= i < count:
            if info[i].packings & PJMEDIA_VID_PACKING_PACKETS:
                retval.append((prio[i], _pj_str_to_bytes(info[i].encoding_name), info[i].pt))
        return retval

    cdef list _get_all_video_codecs(self):
        cdef list codecs
        cdef tuple codec_data
        codecs = self._get_video_codecs()
        return list(set([codec_data[1] for codec_data in codecs]))

    cdef list _get_current_video_codecs(self):
        cdef list codecs
        cdef tuple codec_data
        cdef list retval
        codecs = [codec_data for codec_data in self._get_video_codecs() if codec_data[0] > 0]
        codecs.sort(reverse=True)
        retval = list(set([codec_data[1] for codec_data in codecs]))
        return retval

    cdef int _set_video_codecs(self, list req_codecs) except -1:
        cdef object new_codecs
        cdef object codec_set
        cdef list codecs
        cdef tuple codec_data
        cdef object codec
        cdef int payload_type
        cdef object codec_name
        cdef int prio
        cdef list codec_prio
        cdef pj_str_t codec_pj
        new_codecs = set(req_codecs)
        if len(new_codecs) != len(req_codecs):
            raise ValueError("Requested video codec list contains doubles")
        codec_set = new_codecs.difference(set(self._get_all_video_codecs()))
        if len(codec_set) > 0:
            raise SIPCoreError("Unknown video codecs: %s" % ", ".join(cdc.decode() for cdc in codec_set))
        codecs = self._get_video_codecs()
        codec_prio = list()
        for codec in req_codecs:
            for prio, codec_name, payload_type in codecs:
                if codec == codec_name:
                    codec_prio.append("%s/%d" % (codec_name.decode(), payload_type))
        for prio, codec in enumerate(reversed(codec_prio)):
            _str_to_pj_str(codec.encode(), &codec_pj)
            status = pjmedia_vid_codec_mgr_set_codec_priority(NULL, &codec_pj, prio + 1)
            if status != 0:
                raise PJSIPError("Could not set video codec priority", status)
        for prio, codec_name, payload_type in codecs:
            if codec_name not in req_codecs:
                codec = "%s/%d" % (codec_name.decode(), payload_type)
                _str_to_pj_str(codec.encode(), &codec_pj)
                status = pjmedia_vid_codec_mgr_set_codec_priority(NULL, &codec_pj, 0)
                if status != 0:
                    raise PJSIPError("Could not set video codec priority", status)
        return 0

    cdef void _set_h264_options(self, object profile, int level):
        global h264_profiles_map, h264_profile_level_id, h264_packetization_mode

        cdef unsigned int count = PJMEDIA_VID_CODEC_MGR_MAX_CODECS
        cdef pjmedia_vid_codec_info info[PJMEDIA_VID_CODEC_MGR_MAX_CODECS]
        cdef pjmedia_vid_codec_param vparam
        cdef unsigned int prio[PJMEDIA_VID_CODEC_MGR_MAX_CODECS]
        cdef int status
        cdef PJSTR h264_profile_level_id_value
        cdef PJSTR h264_packetization_mode_value = PJSTR(b"1")    # TODO; make it configurable?

        try:
            profile_n = h264_profiles_map[profile]
        except KeyError:
            raise ValueError("invalid profile specified: %s" % profile)
        h264_profile_level_id_value = PJSTR(b"%xe0%x" % (profile_n, level))    # use common subset (e0)

        status = pjmedia_vid_codec_mgr_enum_codecs(NULL, &count, info, prio)
        if status != 0:
            raise PJSIPError("Could not get available video codecs", status)
        for i from 0 <= i < count:
            if not (info[i].packings & PJMEDIA_VID_PACKING_PACKETS):
                continue
            if _pj_str_to_bytes(info[i].encoding_name) != b'H264':
                continue
            status = pjmedia_vid_codec_mgr_get_default_param(NULL, &info[i], &vparam)
            if status != 0:
                continue
            # 2 format parameters are currently defined for H264: profile-level-id and packetization-mode
            vparam.dec_fmtp.param[0].name = h264_profile_level_id.pj_str
            vparam.dec_fmtp.param[0].val = h264_profile_level_id_value.pj_str
            vparam.dec_fmtp.param[1].name = h264_packetization_mode.pj_str
            vparam.dec_fmtp.param[1].val = h264_packetization_mode_value.pj_str
            vparam.dec_fmtp.cnt = 2

            status = pjmedia_vid_codec_mgr_set_default_param(NULL, &info[i], &vparam)
            if status != 0:
                raise PJSIPError("Could not set H264 options", status)


    cdef void _set_video_options(self, tuple max_resolution, int max_framerate, float max_bitrate):
        cdef unsigned int count = PJMEDIA_VID_CODEC_MGR_MAX_CODECS
        cdef pjmedia_vid_codec_info info[PJMEDIA_VID_CODEC_MGR_MAX_CODECS]
        cdef pjmedia_vid_codec_param vparam
        cdef unsigned int prio[PJMEDIA_VID_CODEC_MGR_MAX_CODECS]
        cdef int status

        max_width, max_height = max_resolution

        status = pjmedia_vid_codec_mgr_enum_codecs(NULL, &count, info, prio)
        if status != 0:
            raise PJSIPError("Could not get available video codecs", status)
        for i from 0 <= i < count:
            if not (info[i].packings & PJMEDIA_VID_PACKING_PACKETS):
                continue
            status = pjmedia_vid_codec_mgr_get_default_param(NULL, &info[i], &vparam)
            if status != 0:
                continue
            # Max resolution
            vparam.enc_fmt.det.vid.size.w = max_width
            vparam.enc_fmt.det.vid.size.h = max_height
            vparam.dec_fmt.det.vid.size.w = max_width
            vparam.dec_fmt.det.vid.size.h = max_height
            # Max framerate
            vparam.enc_fmt.det.vid.fps.num = max_framerate
            vparam.enc_fmt.det.vid.fps.denum = 1
            vparam.dec_fmt.det.vid.fps.num = 10
            vparam.dec_fmt.det.vid.fps.denum = 1
            # Average and max bitrate (set to 0 for 'unlimited')
            vparam.enc_fmt.det.vid.avg_bps = int(max_bitrate * 1e6)
            vparam.enc_fmt.det.vid.max_bps = int(max_bitrate * 1e6)
            vparam.dec_fmt.det.vid.avg_bps = 0
            vparam.dec_fmt.det.vid.max_bps = 0

            status = pjmedia_vid_codec_mgr_set_default_param(NULL, &info[i], &vparam)
            if status != 0:
                raise PJSIPError("Could not set video options", status)


cdef void _transport_state_cb_impl(pjsip_transport *tp, pjsip_transport_state state, pjsip_transport_state_info_ptr_const info) with gil:
    cdef PJSIPUA ua
    cdef str local_address
    cdef str remote_address
    cdef char buf[PJ_INET6_ADDRSTRLEN]
    cdef dict event_dict
    try:
        ua = _get_ua()
    except:
        return

    if pj_sockaddr_has_addr(&tp.local_addr):
        pj_sockaddr_print(&tp.local_addr, buf, 512, 0)
        local_address = '%s:%d' % (_buf_to_str(buf), pj_sockaddr_get_port(&tp.local_addr))
    else:
        local_address = None

    transport = tp.type_name.decode().lower()
    remote_address = '%s:%d' % (_pj_str_to_str(tp.remote_name.host), tp.remote_name.port)
    event_dict = dict(transport=transport, local_address=local_address, remote_address=remote_address)
    
    if state == PJSIP_TP_STATE_CONNECTED:
        _add_event("SIPEngineTransportDidConnect", event_dict)
    else:
        reason = _pj_status_to_str(info.status)
        event_dict['reason'] = reason
        _add_event("SIPEngineTransportDidDisconnect", event_dict)


cdef void _transport_state_cb(pjsip_transport *tp, pjsip_transport_state state, pjsip_transport_state_info_ptr_const info) noexcept nogil:
    with gil:
        _transport_state_cb_impl(tp, state, info)

# globals
cdef PJSTR h264_profile_level_id = PJSTR(b"profile-level-id")
cdef PJSTR h264_packetization_mode = PJSTR(b"packetization-mode")
cdef dict h264_profiles_map = dict(baseline=66, main=77, high=100)
