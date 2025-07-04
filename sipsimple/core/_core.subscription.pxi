
import re


cdef class Subscription:
    expire_warning_time = 30

    #public methods

    def __cinit__(self, *args, **kwargs):
        self.state = "NULL"
        pj_timer_entry_init(&self._timeout_timer, 0, <void *> self, _Subscription_cb_timer)
        self._timeout_timer_active = 0
        pj_timer_entry_init(&self._refresh_timer, 1, <void *> self, _Subscription_cb_timer)
        self._refresh_timer_active = 0
        self.extra_headers = frozenlist()
        self.peer_address = None
        self.call_id = None

    def __init__(self, SIPURI request_uri not None, FromHeader from_header not None, ToHeader to_header not None, ContactHeader contact_header not None,
                 object event, RouteHeader route_header not None, Credentials credentials=None, int refresh=300):
        global _subs_cb
        cdef PJSTR from_header_str
        cdef PJSTR to_header_str
        cdef PJSTR contact_str
        cdef PJSTR request_uri_str
        cdef pj_str_t event_pj
        cdef pjsip_cred_info *cred_info
        cdef PJSIPUA ua = _get_ua()
        cdef int status
        if self._obj != NULL or self.state != "NULL":
            raise SIPCoreError("Subscription.__init__() was already called")
        if refresh <= 0:
            raise ValueError("refresh argument needs to be a non-negative integer")
        
        supported_events = list(ua._events.keys())
        if event not in supported_events:
            raise ValueError('Unknown event %s, supported events: %s' % (event.decode(), (e.decode() for e in supported_events)))

        self.contact_header = FrozenContactHeader.new(contact_header)
        self.event = event
        self.route_header = FrozenRouteHeader.new(route_header)
        self.route_header.uri.parameters.dict["lr"] = None # always send lr parameter in Route header
        self.route_header.uri.parameters.dict["hide"] = None # always hide Route header
        if credentials is not None:
            self.credentials = FrozenCredentials.new(credentials)
        self.refresh = refresh
        from_header_parameters = from_header.parameters.copy()
        from_header_parameters.pop("tag", None)
        from_header.parameters = {}
        from_header_str = PJSTR(from_header.body.encode())
        to_header_parameters = to_header.parameters.copy()
        to_header_parameters.pop("tag", None)
        to_header.parameters = {}
        to_header_str = PJSTR(to_header.body.encode())
        contact_str = PJSTR(str(contact_header.body).encode())
        request_uri_str = PJSTR(str(request_uri).encode())
        _str_to_pj_str(self.event, &event_pj)
        with nogil:
            status = pjsip_dlg_create_uac(pjsip_ua_instance(), &from_header_str.pj_str, &contact_str.pj_str,
                                          &to_header_str.pj_str, &request_uri_str.pj_str, &self._dlg)
        if status != 0:
            raise PJSIPError("Could not create dialog for SUBSCRIBE", status)
        # Increment dialog session count so that it's never destroyed by PJSIP
        with nogil:
            status = pjsip_dlg_inc_session(self._dlg, &ua._module)
        if status != 0:
            raise PJSIPError("Could not increment dialog session count", status)
        self.call_id = _pj_str_to_str(self._dlg.call_id.id)
        if contact_header.expires is not None:
            self._dlg.local.contact.expires = contact_header.expires
        if contact_header.q is not None:
            self._dlg.local.contact.q1000 = int(contact_header.q*1000)
        contact_parameters = contact_header.parameters.copy()
        contact_parameters.pop("q", None)
        contact_parameters.pop("expires", None)
        _dict_to_pjsip_param(contact_parameters, &self._dlg.local.contact.other_param, self._dlg.pool)
        _dict_to_pjsip_param(from_header_parameters, &self._dlg.local.info.other_param, self._dlg.pool)
        _dict_to_pjsip_param(to_header_parameters, &self._dlg.remote.info.other_param, self._dlg.pool)
        self.from_header = FrozenFromHeader_create(self._dlg.local.info)
        self.to_header = FrozenToHeader.new(to_header)
        with nogil:
            status = pjsip_evsub_create_uac(self._dlg, &_subs_cb, &event_pj, PJSIP_EVSUB_NO_EVENT_ID, &self._obj)
        if status != 0:
            raise PJSIPError("Could not create SUBSCRIBE", status)
        pjsip_evsub_set_mod_data(self._obj, ua._event_module.id, <void *> self)
        _BaseRouteHeader_to_pjsip_route_hdr(self.route_header, &self._route_header, self._dlg.pool)
        pj_list_init(<pj_list *> &self._route_set)
        pj_list_insert_after(<pj_list *> &self._route_set, <pj_list *> &self._route_header)
        with nogil:
            status = pjsip_dlg_set_route_set(self._dlg, <pjsip_route_hdr *> &self._route_set)
        if status != 0:
            raise PJSIPError("Could not set route on SUBSCRIBE", status)
        if self.credentials is not None:
            cred_info = self.credentials.get_cred_info()
            with nogil:
                status = pjsip_auth_clt_set_credentials(&self._dlg.auth_sess, 1, cred_info)
            if status != 0:
                raise PJSIPError("Could not set credentials for SUBSCRIBE", status)

    def __dealloc__(self):
        cdef PJSIPUA ua = self._get_ua()
        if ua is not None:
            self._cancel_timers(ua, 1, 1)
        if self._obj != NULL:
            pjsip_evsub_set_mod_data(self._obj, ua._event_module.id, NULL)
            with nogil:
                pjsip_evsub_terminate(self._obj, 0)
            self._obj = NULL
        if self._dlg != NULL and ua is not None:
            with nogil:
                pjsip_dlg_dec_session(self._dlg, &ua._module)
            self._dlg = NULL

    def subscribe(self, list extra_headers not None=list(), object content_type=None, object body=None, object timeout=None):
        cdef str prev_state = self.state
        cdef PJSIPUA ua = self._get_ua()

        with nogil:
            pjsip_dlg_inc_lock(self._dlg)
        try:
            if self.state == "TERMINATED":
                raise SIPCoreError('This method may not be called in the "TERMINATED" state')
            if (content_type is not None and body is None) or (content_type is None and body is not None):
                raise ValueError("Both or none of content_type and body arguments need to be specified")
            if timeout is not None:
                if timeout <= 0:
                    raise ValueError("Timeout value cannot be negative")
                self._subscribe_timeout.sec = int(timeout)
                self._subscribe_timeout.msec = (timeout * 1000) % 1000
            else:
                self._subscribe_timeout.sec = 0
                self._subscribe_timeout.msec = 0
            if extra_headers is not None:
                self.extra_headers = frozenlist([header.frozen_type.new(header) for header in extra_headers])
            self.content_type = content_type
            self.body = body
            self._send_subscribe(ua, self.refresh, &self._subscribe_timeout, self.extra_headers, content_type, body)
            self._cancel_timers(ua, 0, 1)
            if prev_state == "NULL":
                _add_event("SIPSubscriptionWillStart", dict(obj=self))
        finally:
            with nogil:
                pjsip_dlg_dec_lock(self._dlg)

    def end(self, object timeout=None):
        cdef pj_time_val end_timeout
        cdef PJSIPUA ua = self._get_ua()

        with nogil:
            pjsip_dlg_inc_lock(self._dlg)
        try:
            if self.state == "TERMINATED":
                return
            if self.state == "NULL":
                raise SIPCoreError('This method may not be called in the "NULL" state')
            if timeout is not None:
                if timeout <= 0:
                    raise ValueError("Timeout value cannot be negative")
                end_timeout.sec = int(timeout)
                end_timeout.msec = (timeout * 1000) % 1000
            else:
                end_timeout.sec = 0
                end_timeout.msec = 0
            self._want_end = 1
            self._cancel_timers(ua, 1, 1)
            _add_event("SIPSubscriptionWillEnd", dict(obj=self))
            try:
                self._send_subscribe(ua, 0, &end_timeout, self.extra_headers, None, None)
            except PJSIPError, e:
                self._term_reason = e.args[0]
                if self._obj != NULL:
                    with nogil:
                        pjsip_evsub_terminate(self._obj, 1)
        finally:
            with nogil:
                pjsip_dlg_dec_lock(self._dlg)


    # private methods

    cdef PJSIPUA _get_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except SIPCoreError:
            self._obj = NULL
            self._timeout_timer_active = 0
            self._refresh_timer_active = 0
            self.state = "TERMINATED"
            return None
        else:
            return ua

    cdef int _cancel_timers(self, PJSIPUA ua, int cancel_timeout, int cancel_refresh) except -1:
        if cancel_timeout and self._timeout_timer_active:
            pjsip_endpt_cancel_timer(ua._pjsip_endpoint._obj, &self._timeout_timer)
            self._timeout_timer_active = 0
        if cancel_refresh and self._refresh_timer_active:
            pjsip_endpt_cancel_timer(ua._pjsip_endpoint._obj, &self._refresh_timer)
            self._refresh_timer_active = 0

    cdef int _send_subscribe(self, PJSIPUA ua, int expires, pj_time_val *timeout,
                             object extra_headers, object content_type, object body) except -1:
        cdef pjsip_tx_data *tdata
        cdef pj_str_t body_pj
        cdef object content_type_spl
        cdef PJSTR content_type_str
        cdef PJSTR content_subtype_str
        cdef int status
        if body is not None:
            content_type_spl = content_type.split("/")
            if len(content_type_spl) != 2:
                raise ValueError('Supplied content_type argument does not contain a "/" character')
            content_type_str = PJSTR(content_type_spl[0].encode())
            content_subtype_str = PJSTR(content_type_spl[1].encode())
            _str_to_pj_str(body, &body_pj)
        with nogil:
            status = pjsip_evsub_initiate(self._obj, NULL, expires, &tdata)
        if status != 0:
            raise PJSIPError("Could not create SUBSCRIBE message", status)
        _add_headers_to_tdata(tdata, extra_headers)
        if body is not None:
            tdata.msg.body = pjsip_msg_body_create(tdata.pool, &content_type_str.pj_str, &content_subtype_str.pj_str, &body_pj)
        with nogil:
            status = pjsip_evsub_send_request(self._obj, tdata)
        if status != 0:
            raise PJSIPError("Could not send SUBSCRIBE message", status)
        self._cancel_timers(ua, 1, 0)
        if timeout.sec or timeout.msec:
            status = pjsip_endpt_schedule_timer(ua._pjsip_endpoint._obj, &self._timeout_timer, timeout)
            if status == 0:
                self._timeout_timer_active = 1
        self._expires = self.refresh

    # callback methods

    cdef int _cb_state(self, PJSIPUA ua, str state, int code, object reason, dict headers) except -1:
        # PJSIP holds the dialog lock when this callback is entered
        cdef str prev_state = self.state
        cdef int expires
        cdef int status
        cdef pj_time_val end_timeout
        self.state = state
        if state == "ACCEPTED" and prev_state == "SENT":
            try:
                contact_header = headers['Contact'][0]
            except LookupError:
                self._term_code = 1400
                self._term_reason = "Contact header missing"
                with nogil:
                    pjsip_evsub_terminate(self._obj, 1)
                return 0
            _add_event("SIPSubscriptionDidStart", dict(obj=self))
            try:
                expires = int(headers["Expires"])
            except (KeyError, ValueError):
                return 0
            if expires == 0:
                self._want_end = 1
                self._cancel_timers(ua, 1, 1)
                end_timeout.sec = 1
                end_timeout.msec = 0
                _add_event("SIPSubscriptionWillEnd", dict(obj=self))
                try:
                    self._send_subscribe(ua, 0, &end_timeout, self.extra_headers, None, None)
                except PJSIPError, e:
                    self._term_reason = e.args[0]
                    if self._obj != NULL:
                        with nogil:
                            pjsip_evsub_terminate(self._obj, 1)
                return 0
        elif state == "TERMINATED":
            pjsip_evsub_set_mod_data(self._obj, ua._event_module.id, NULL)
            self._cancel_timers(ua, 1, 1)
            self._obj = NULL
            if self._want_end:
                _add_event("SIPSubscriptionDidEnd", dict(obj=self))
            else:
                min_expires = headers.get('Min-Expires')
                if self._term_reason is not None:
                    _add_event("SIPSubscriptionDidFail", dict(obj=self, code=self._term_code, reason=self._term_reason, min_expires=min_expires))
                else:
                    subscription_state = headers.get('Subscription-State')
                    if subscription_state is not None and subscription_state.state == 'terminated':
                        _add_event("SIPSubscriptionDidEnd", dict(obj=self))
                    else:
                        _add_event("SIPSubscriptionDidFail", dict(obj=self, code=code, reason=reason, min_expires=min_expires))
        if prev_state != state:
            _add_event("SIPSubscriptionChangedState", dict(obj=self, prev_state=prev_state, state=state))

    cdef int _cb_got_response(self, PJSIPUA ua, pjsip_rx_data *rdata) except -1:
        # PJSIP holds the dialog lock when this callback is entered
        cdef dict event_dict = dict()
        cdef int expires = self._expires
        cdef int status
        cdef pj_time_val refresh
        _pjsip_msg_to_dict(rdata.msg_info.msg, event_dict)
        self.to_header = FrozenToHeader_create(rdata.msg_info.to_hdr)
        if self.state != "TERMINATED":
            try:
                contact_header = event_dict["headers"]["Contact"][0]
            except LookupError:
                return 0
            try:
                expires = int(event_dict["headers"]["Expires"])
            except (KeyError, ValueError):
                expires = self._expires
            if expires == 0:
                return 0
        if self.state != "TERMINATED" and not self._want_end:
            self._cancel_timers(ua, 1, 0)
            refresh.sec = max(1, expires - self.expire_warning_time, expires/2)
            refresh.msec = 0
            status = pjsip_endpt_schedule_timer(ua._pjsip_endpoint._obj, &self._refresh_timer, &refresh)
            if status == 0:
                self._refresh_timer_active = 1

    cdef int _cb_notify(self, PJSIPUA ua, pjsip_rx_data *rdata) except -1:
        # PJSIP holds the dialog lock when this callback is entered
        cdef dict event_dict = dict()
        cdef dict notify_dict = dict(obj=self)
        _pjsip_msg_to_dict(rdata.msg_info.msg, event_dict)
        body = event_dict["body"]
        content_type = event_dict["headers"].get("Content-Type", None)
        event = event_dict["headers"].get("Event", None)

        if event is None or event.event != self.event.decode() or (body is not None and content_type is not None and content_type.content_type.encode() not in ua.events[event.event.encode()]):
            return 0
        notify_dict["request_uri"] = event_dict["request_uri"]
        notify_dict["from_header"] = event_dict["headers"].get("From", None)
        notify_dict["to_header"] = event_dict["headers"].get("To", None)
        notify_dict["headers"] = event_dict["headers"]
        notify_dict["body"] = body
        notify_dict["content_type"] = content_type.content_type if content_type and body else None
        notify_dict["event"] = event.event
        _add_event("SIPSubscriptionGotNotify", notify_dict)

    cdef int _cb_timeout_timer(self, PJSIPUA ua):
        # Timer callback, dialog lock is not held by PJSIP
        global sip_status_messages

        with nogil:
            pjsip_dlg_inc_lock(self._dlg)
        try:
            self._term_code = PJSIP_SC_TSX_TIMEOUT
            self._term_reason = sip_status_messages[PJSIP_SC_TSX_TIMEOUT]
            if self._obj != NULL:
                with nogil:
                    pjsip_evsub_terminate(self._obj, 1)
        finally:
            with nogil:
                pjsip_dlg_dec_lock(self._dlg)

    cdef int _cb_refresh_timer(self, PJSIPUA ua):
        # Timer callback, dialog lock is not held by PJSIP
        with nogil:
            pjsip_dlg_inc_lock(self._dlg)
        try:
            self._send_subscribe(ua, self.refresh, &self._subscribe_timeout,
                                 self.extra_headers, self.content_type, self.body)
        except PJSIPError, e:
            self._term_reason = e.args[0]
            if self._obj != NULL:
                with nogil:
                    pjsip_evsub_terminate(self._obj, 1)
        finally:
            with nogil:
                pjsip_dlg_dec_lock(self._dlg)


cdef class IncomingSubscription:
    # properties

    property content_type:

        def __get__(self):
            if self._content_type is None:
                return None
            return "%s/%s" % (self._content_type.str, self._content_subtype.str)

    property content:

        def __get__(self):
            if self._content is None:
                return None
            return self._content.str

    def __cinit__(self):
        self.state = None
        self.peer_address = None
        self.call_id = None

    def __dealloc__(self):
        cdef PJSIPUA ua = self._get_ua(0)
        self._initial_response = NULL
        self._initial_tsx = NULL
        if self._obj != NULL:
            pjsip_evsub_set_mod_data(self._obj, ua._event_module.id, NULL)
            with nogil:
                pjsip_evsub_terminate(self._obj, 0)
            self._obj = NULL
        if self._dlg != NULL and ua is not None:
            with nogil:
                pjsip_dlg_dec_session(self._dlg, &ua._module)
            self._dlg = NULL

    cdef int init(self, PJSIPUA ua, pjsip_rx_data *rdata, object event) except -1:
        global _incoming_subs_cb
        cdef int status
        cdef str transport
        cdef FrozenSIPURI request_uri
        cdef FrozenContactHeader contact_header
        cdef PJSTR contact_str
        cdef dict event_dict
        cdef pjsip_expires_hdr *expires_header
        cdef char *error_message

        expires_header = <pjsip_expires_hdr *> pjsip_msg_find_hdr(rdata.msg_info.msg, PJSIP_H_EXPIRES, NULL)
        if expires_header == NULL:
            self._expires = 3600
        else:
            self._expires = min(expires_header.ivalue, 3600)
        self._set_state("INCOMING")
        self.event = event
        self.peer_address = EndpointAddress(rdata.pkt_info.src_name, rdata.pkt_info.src_port)
        event_dict = dict(obj=self)
        _pjsip_msg_to_dict(rdata.msg_info.msg, event_dict)
        transport = rdata.tp_info.transport.type_name.decode().lower()
        request_uri = event_dict["request_uri"]
        if _is_valid_ip(pj_AF_INET(), request_uri.host.encode()):
            contact_header = FrozenContactHeader(request_uri)
        else:
            contact_header = FrozenContactHeader(FrozenSIPURI(host=_pj_str_to_str(rdata.tp_info.transport.local_name.host),
                                                            user=request_uri.user, port=rdata.tp_info.transport.local_name.port,
                                                            parameters=(frozendict(transport=transport) if transport != "udp" else frozendict())))
        contact_str = PJSTR(str(contact_header.body).encode())

        with nogil:
            status = pjsip_dlg_create_uas_and_inc_lock(pjsip_ua_instance(), rdata, &contact_str.pj_str, &self._dlg)
            if status != 0:
                error_message = "Could not create dialog for incoming SUBSCRIBE"
            else:
                pjsip_dlg_inc_session(self._dlg, &ua._module)  # Increment dialog session count so it's never destroyed by PJSIP
                # setting the transport to rdata.tp_info.transport doesn't work as the NOTIFY has to be sent to the Contact URI and the transports can conflict
        if status != 0:
            raise PJSIPError(error_message, status)
        self._initial_tsx = pjsip_rdata_get_tsx(rdata)
        self.call_id = _pj_str_to_str(self._dlg.call_id.id)
        with nogil:
            status = pjsip_evsub_create_uas(self._dlg, &_incoming_subs_cb, rdata, 0, &self._obj)
            pjsip_dlg_dec_lock(self._dlg)
            if status != 0:
                pjsip_tsx_terminate(self._initial_tsx, 500)
                self._initial_tsx = NULL
                self._dlg = NULL
                error_message = "Could not create incoming SUBSCRIBE session"
            else:
                pjsip_evsub_set_mod_data(self._obj, ua._event_module.id, <void *> self)
                status = pjsip_dlg_create_response(self._dlg, rdata, 500, NULL, &self._initial_response)
                if status != 0:
                    pjsip_tsx_terminate(self._initial_tsx, 500)
                    self._initial_tsx = NULL
                    error_message = "Could not create response for incoming SUBSCRIBE"

        if status != 0:
            raise PJSIPError(error_message, status)

        _add_event("SIPIncomingSubscriptionGotSubscribe", event_dict)
        return 0

    def reject(self, int code):
        cdef PJSIPUA ua = self._get_ua(1)

        with nogil:
            pjsip_dlg_inc_lock(self._dlg)
        try:
            if self.state != "INCOMING":
                raise SIPCoreInvalidStateError('Can only reject an incoming SUBSCRIBE in the "INCOMING" state, '+
                                        'object is currently in the "%s" state' % self.state)
            if not (300 <= code < 700):
                raise ValueError("Invalid negative SIP response code: %d" % code)
            self._send_initial_response(code)
            pjsip_evsub_set_mod_data(self._obj, ua._event_module.id, NULL)
            with nogil:
                pjsip_evsub_terminate(self._obj, 0)
            self._obj = NULL
            self._set_state("TERMINATED")
            _add_event("SIPIncomingSubscriptionDidEnd", dict(obj=self))
        finally:
            with nogil:
                pjsip_dlg_dec_lock(self._dlg)

    def accept_pending(self):
        cdef PJSIPUA ua = self._get_ua(1)

        with nogil:
            pjsip_dlg_inc_lock(self._dlg)
        try:
            if self.state != "INCOMING":
                raise SIPCoreInvalidStateError('Can only accept an incoming SUBSCRIBE as pending in the "INCOMING" state, '+
                                        'object is currently in the "%s" state' % self.state)
            self._send_initial_response(202)
            self._set_state("PENDING")
            if self._expires > 0:
                self._send_notify()
            else:
                # cleanup will be done by _cb_tsx
                self._terminate(ua, "timeout", 0)
        finally:
            with nogil:
                pjsip_dlg_dec_lock(self._dlg)

    def accept(self, str content_type=None, object content=None):
        global _re_content_type
        cdef object content_type_match
        cdef PJSIPUA ua = self._get_ua(1)

        with nogil:
            pjsip_dlg_inc_lock(self._dlg)
        try:
            if self.state not in ("INCOMING", "PENDING"):
                raise SIPCoreInvalidStateError('Can only accept an incoming SUBSCRIBE in the "INCOMING" or "PENDING" state, object is currently in the "%s" state' % self.state)
            if (content_type is None and content is not None) or (content_type is not None and content is None):
                raise ValueError('Either both or neither of the "content_type" and "content" arguments should be specified')
            if content_type is not None:
                content_type_match = _re_content_type.match(content_type)
                if content_type_match is None:
                    raise ValueError("content_type parameter is not properly formatted")
                self._content_type = PJSTR(content_type_match.group(1).encode())
                self._content_subtype = PJSTR(content_type_match.group(2).encode())
                self._content = PJSTR(content)
            if self.state == "INCOMING":
                self._send_initial_response(200)
            self._set_state("ACTIVE")
            if self._expires > 0:
                self._send_notify()
            else:
                # cleanup will be done by _cb_tsx
                self._terminate(ua, "timeout", 0)
        finally:
            with nogil:
                pjsip_dlg_dec_lock(self._dlg)

    def push_content(self, str content_type not None, object content not None):
        global _re_content_type
        cdef object content_type_match
        cdef PJSIPUA ua = self._get_ua(1)

        with nogil:
            pjsip_dlg_inc_lock(self._dlg)
        try:
            if self.state != "ACTIVE":
                raise SIPCoreInvalidStateError('Can only push the content for a SUBSCRIBE session in the "ACTIVE" state, '
                                            'object is currently in the "%s" state' % self.state)
            content_type_match = _re_content_type.match(content_type)
            if content_type_match is None:
                raise ValueError("content_type parameter is not properly formatted")
            self._content_type = PJSTR(content_type_match.group(1).encode())
            self._content_subtype = PJSTR(content_type_match.group(2).encode())
            payload = content if isinstance(content, bytes) else content.encode()
            self._content = PJSTR(payload)
            self._send_notify()
        finally:
            with nogil:
                pjsip_dlg_dec_lock(self._dlg)

    def end(self, reason=None):
        cdef PJSIPUA ua = self._get_ua(0)

        with nogil:
            pjsip_dlg_inc_lock(self._dlg)
        try:
            if self.state == "TERMINATED":
                return
            if self.state not in ("PENDING", "ACTIVE"):
                raise SIPCoreInvalidStateError('Can only end an incoming SUBSCRIBE session in the "PENDING" or '+
                                        '"ACTIVE" state, object is currently in the "%s" state' % self.state)
            self._terminate(ua, reason, 1)
        finally:
            with nogil:
                pjsip_dlg_dec_lock(self._dlg)

    cdef int _set_state(self, str state) except -1:
        cdef str prev_state
        prev_state = self.state
        self.state = state
        if prev_state != state and prev_state is not None:
            _add_event("SIPIncomingSubscriptionChangedState", dict(obj=self, prev_state=prev_state, state=state))

    cdef PJSIPUA _get_ua(self, int raise_exception):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except SIPCoreError:
            self._obj = NULL
            self._initial_response = NULL
            self._initial_tsx = NULL
            self._set_state("TERMINATED")
            if raise_exception:
                raise
            else:
                return None
        else:
            return ua

    cdef int _send_initial_response(self, int code) except -1:
        cdef PJSIPUA ua = self._get_ua(1)
        cdef int status

        with nogil:
            status = pjsip_dlg_modify_response(self._dlg, self._initial_response, code, NULL)
        if status != 0:
            raise PJSIPError("Could not modify response", status)
        # pjsip_dlg_modify_response() increases ref count unncessarily
        with nogil:
            pjsip_tx_data_dec_ref(self._initial_response)
        if code / 100 == 2:
            pjsip_msg_add_hdr(self._initial_response.msg,
                              <pjsip_hdr *> pjsip_expires_hdr_create(self._initial_response.pool, self._expires))
        with nogil:
            status = pjsip_dlg_send_response(self._dlg, self._initial_tsx, self._initial_response)
        if status != 0:
            raise PJSIPError("Could not send response", status)
        self._initial_response = NULL
        self._initial_tsx = NULL
        if self._expires > 0:
            with nogil:
                # Start TIMER_TYPE_UAS_TIMEOUT, which PJSIP doesn't do for the initial SUBSCRIBE
                pjsip_evsub_set_timer(self._obj, 2, self._expires)

    cdef int _send_notify(self, object reason=None) except -1:
        cdef pjsip_evsub_state state
        cdef pj_str_t reason_pj
        cdef pj_str_t *reason_p
        cdef pjsip_tx_data *tdata
        cdef int status

        reason_p = NULL
        if self.state == "PENDING":
            state = PJSIP_EVSUB_STATE_PENDING
        elif self.state == "ACTIVE":
            state = PJSIP_EVSUB_STATE_ACTIVE
        else:
            state = PJSIP_EVSUB_STATE_TERMINATED
            if reason is not None:
                _str_to_pj_str(reason, &reason_pj)
                reason_p = &reason_pj
        with nogil:
            status = pjsip_evsub_notify(self._obj, state, NULL, reason_p, &tdata)
        if status != 0:
            raise PJSIPError("Could not create NOTIFY request", status)
        if self.state == "ACTIVE" and None not in (self._content_type, self._content_subtype, self._content):
            tdata.msg.body = pjsip_msg_body_create(tdata.pool, &self._content_type.pj_str,
                                                   &self._content_subtype.pj_str, &self._content.pj_str)
        with nogil:
            status = pjsip_evsub_send_request(self._obj, tdata)
        if status != 0:
            raise PJSIPError("Could not send NOTIFY request", status)
        event_dict = dict(obj=self)
        _pjsip_msg_to_dict(tdata.msg, event_dict)
        _add_event("SIPIncomingSubscriptionSentNotify", event_dict)
        return 0

    cdef int _terminate(self, PJSIPUA ua, object reason, int do_cleanup) except -1:
        cdef int status
        self._set_state("TERMINATED")
        try:
            self._send_notify(reason)
        except SIPCoreError:
            pass
        if do_cleanup:
            pjsip_evsub_set_mod_data(self._obj, ua._event_module.id, NULL)
            self._obj = NULL
        _add_event("SIPIncomingSubscriptionDidEnd", dict(obj=self))


    # callback methods

    cdef int _cb_rx_refresh(self, PJSIPUA ua, pjsip_rx_data *rdata) except -1:
        # PJSIP holds the dialog lock when this callback is entered
        cdef int status
        cdef pjsip_expires_hdr *expires_header
        cdef int expires
        cdef dict event_dict

        event_dict = dict(obj=self)
        _pjsip_msg_to_dict(rdata.msg_info.msg, event_dict)
        expires_header = <pjsip_expires_hdr *> pjsip_msg_find_hdr(rdata.msg_info.msg, PJSIP_H_EXPIRES, NULL)
        if expires_header == NULL:
            self._expires = 3600
        else:
            if expires_header.ivalue == 0:
                _add_event("SIPIncomingSubscriptionGotUnsubscribe", event_dict)
                # cleanup will be done by _cb_tsx
                self._terminate(ua, None, 0)
                return 200
            else:
                self._expires = min(expires_header.ivalue, 3600)
        _add_event("SIPIncomingSubscriptionGotRefreshingSubscribe", event_dict)
        try:
            self._send_notify()
        except SIPCoreError, e:
            _add_event("SIPIncomingSubscriptionNotifyDidFail", dict(obj=self, code=0, reason=e.args[0]))
        if self.state == "ACTIVE":
            return 200
        else:
            return 202

    cdef int _cb_server_timeout(self, PJSIPUA ua) except -1:
        # PJSIP holds the dialog lock when this callback is entered
        _add_event("SIPIncomingSubscriptionDidTimeout", dict(obj=self))
        self._terminate(ua, "timeout", 1)

    cdef int _cb_tsx(self, PJSIPUA ua, pjsip_event *event) except -1:
        # PJSIP holds the dialog lock when this callback is entered
        cdef pjsip_rx_data *rdata
        cdef dict event_dict
        cdef int status_code

        if (event != NULL and event.type == PJSIP_EVENT_TSX_STATE and
            event.body.tsx_state.tsx.role == PJSIP_ROLE_UAC and
            _pj_str_to_str(event.body.tsx_state.tsx.method.name) == "NOTIFY" and
            event.body.tsx_state.tsx.state == PJSIP_TSX_STATE_COMPLETED):
            event_dict = dict(obj=self)
            rdata = event.body.tsx_state.src.rdata
            if rdata != NULL:
                if self.peer_address is None:
                    self.peer_address = EndpointAddress(rdata.pkt_info.src_name, rdata.pkt_info.src_port)
                else:
                    self.peer_address.ip = rdata.pkt_info.src_name
                    self.peer_address.port = rdata.pkt_info.src_port
            status_code = event.body.tsx_state.tsx.status_code
            if event.body.tsx_state.type==PJSIP_EVENT_RX_MSG and status_code/100==2:
                _pjsip_msg_to_dict(rdata.msg_info.msg, event_dict)
                _add_event("SIPIncomingSubscriptionNotifyDidSucceed", event_dict)
            else:
                if event.body.tsx_state.type == PJSIP_EVENT_RX_MSG:
                    _pjsip_msg_to_dict(rdata.msg_info.msg, event_dict)
                else:
                    event_dict["code"] = status_code
                    event_dict["reason"] = _pj_str_to_str(event.body.tsx_state.tsx.status_text)
                _add_event("SIPIncomingSubscriptionNotifyDidFail", event_dict)
                if status_code in (408, 481) or status_code/100==7:
                    # PJSIP will terminate the subscription and the dialog will be destroyed
                    self._terminate(ua, None, 1)
        elif (event != NULL and event.type == PJSIP_EVENT_TSX_STATE and
            event.body.tsx_state.tsx.role == PJSIP_ROLE_UAC and
            _pj_str_to_str(event.body.tsx_state.tsx.method.name) == "NOTIFY" and
            event.body.tsx_state.tsx.state == PJSIP_TSX_STATE_TERMINATED):
            event_dict = dict(obj=self)
            status_code = event.body.tsx_state.tsx.status_code
            if status_code == 408:
                # Local timeout, PJSIP will terminate the subscription and the dialog will be destroyed
                event_dict["code"] = status_code
                event_dict["reason"] = _pj_str_to_str(event.body.tsx_state.tsx.status_text)
                _add_event("SIPIncomingSubscriptionNotifyDidFail", event_dict)
                self._terminate(ua, None, 1)
        elif (event != NULL and event.type == PJSIP_EVENT_TSX_STATE and
            event.body.tsx_state.tsx.role == PJSIP_ROLE_UAS and
            _pj_str_to_str(event.body.tsx_state.tsx.method.name) == "SUBSCRIBE" and
            event.body.tsx_state.tsx.state == PJSIP_TSX_STATE_COMPLETED and
            event.body.tsx_state.type == PJSIP_EVENT_TX_MSG):
            event_dict = dict(obj=self)
            _pjsip_msg_to_dict(event.body.tsx_state.src.tdata.msg, event_dict)
            _add_event("SIPIncomingSubscriptionAnsweredSubscribe", event_dict)
            if self.state == "TERMINATED" and self._obj != NULL:
                pjsip_evsub_set_mod_data(self._obj, ua._event_module.id, NULL)
                self._obj = NULL

# callback functions

cdef void _Subscription_cb_state_impl(pjsip_evsub *sub, pjsip_event *event) with gil:
    cdef void *subscription_void
    cdef Subscription subscription
    cdef str state
    cdef int code = 0
    cdef object reason = None
    cdef pjsip_rx_data *rdata = NULL
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        subscription_void = pjsip_evsub_get_mod_data(sub, ua._event_module.id)
        if subscription_void == NULL:
            return
        subscription = <object> subscription_void
        state = pjsip_evsub_get_state_name(sub).decode()
        if (event != NULL and event.type == PJSIP_EVENT_TSX_STATE and
            (event.body.tsx_state.tsx.state == PJSIP_TSX_STATE_COMPLETED or
             event.body.tsx_state.tsx.state == PJSIP_TSX_STATE_TERMINATED)):
            if state == "TERMINATED":
                if event.body.tsx_state.tsx.role == PJSIP_ROLE_UAC:
                    code = event.body.tsx_state.tsx.status_code
                    reason = _pj_str_to_str(event.body.tsx_state.tsx.status_text)
                else:
                    code = 0
                    reason = None

            if event.body.tsx_state.type == PJSIP_EVENT_RX_MSG and _pj_str_to_str(event.body.tsx_state.tsx.method.name) in ("SUBSCRIBE", "NOTIFY"):
                rdata = event.body.tsx_state.src.rdata

        headers_dict = dict()
        if rdata != NULL:
            rdata_dict = dict()
            _pjsip_msg_to_dict(rdata.msg_info.msg, rdata_dict)
            headers_dict = rdata_dict.get('headers', {})
        subscription._cb_state(ua, state, code, reason, headers_dict)
    except:
        ua._handle_exception(1)

cdef void _Subscription_cb_state(pjsip_evsub *sub, pjsip_event *event) noexcept nogil:
    with gil:
        _Subscription_cb_state_impl(sub, event)

cdef void _Subscription_cb_tsx_impl(pjsip_evsub *sub, pjsip_transaction *tsx, pjsip_event *event) with gil:
    cdef void *subscription_void
    cdef Subscription subscription
    cdef pjsip_rx_data *rdata
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        subscription_void = pjsip_evsub_get_mod_data(sub, ua._event_module.id)
        if subscription_void == NULL:
            return
        subscription = <object> subscription_void
        if (event != NULL and event.type == PJSIP_EVENT_TSX_STATE and
            event.body.tsx_state.type == PJSIP_EVENT_RX_MSG and
            event.body.tsx_state.tsx.role == PJSIP_ROLE_UAC and
            event.body.tsx_state.tsx.state == PJSIP_TSX_STATE_COMPLETED and
            _pj_str_to_str(event.body.tsx_state.tsx.method.name) == "SUBSCRIBE" and
            event.body.tsx_state.tsx.status_code / 100 == 2):
            rdata = event.body.tsx_state.src.rdata
            if rdata != NULL:
                if subscription.peer_address is None:
                    subscription.peer_address = EndpointAddress(rdata.pkt_info.src_name, rdata.pkt_info.src_port)
                else:
                    subscription.peer_address.ip = rdata.pkt_info.src_name
                    subscription.peer_address.port = rdata.pkt_info.src_port
            subscription._cb_got_response(ua, rdata)
    except:
        ua._handle_exception(1)

cdef void _Subscription_cb_tsx(pjsip_evsub *sub, pjsip_transaction *tsx, pjsip_event *event) noexcept nogil:
    with gil:
        _Subscription_cb_tsx_impl(sub, tsx, event)

cdef void _Subscription_cb_notify_impl(pjsip_evsub *sub, pjsip_rx_data *rdata, int *p_st_code,
                                    pj_str_t **p_st_text, pjsip_hdr *res_hdr, pjsip_msg_body **p_body) with gil:
    cdef void *subscription_void
    cdef Subscription subscription
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        subscription_void = pjsip_evsub_get_mod_data(sub, ua._event_module.id)
        if subscription_void == NULL:
            return
        subscription = <object> subscription_void
        if rdata != NULL:
            if subscription.peer_address is None:
                subscription.peer_address = EndpointAddress(rdata.pkt_info.src_name, rdata.pkt_info.src_port)
            else:
                subscription.peer_address.ip = rdata.pkt_info.src_name
                subscription.peer_address.port = rdata.pkt_info.src_port
        subscription._cb_notify(ua, rdata)
    except:
        ua._handle_exception(1)

cdef void _Subscription_cb_notify(pjsip_evsub *sub, pjsip_rx_data *rdata, int *p_st_code,
                                    pj_str_t **p_st_text, pjsip_hdr *res_hdr, pjsip_msg_body **p_body) noexcept nogil:
    with gil:
        _Subscription_cb_notify_impl(sub, rdata, p_st_code, p_st_text, res_hdr, p_body)


cdef void _Subscription_cb_refresh_impl(pjsip_evsub *sub) with gil:
    # We want to handle the refresh timer oursevles, ignore the PJSIP provided timer
    pass

cdef void _Subscription_cb_refresh(pjsip_evsub *sub) noexcept nogil:
    with gil:
        _Subscription_cb_refresh_impl(sub)

cdef void _Subscription_cb_timer_impl(pj_timer_heap_t *timer_heap, pj_timer_entry *entry) with gil:
    cdef Subscription subscription
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        if entry.user_data != NULL:
            subscription = <object> entry.user_data
            if subscription._dlg == NULL:
                return
            if entry.id == 1:
                subscription._refresh_timer_active = 0
                subscription._cb_refresh_timer(ua)
            else:
                subscription._timeout_timer_active = 0
                subscription._cb_timeout_timer(ua)
    except:
        ua._handle_exception(1)

cdef void _Subscription_cb_timer(pj_timer_heap_t *timer_heap, pj_timer_entry *entry) noexcept nogil:
    with gil:
        _Subscription_cb_timer_impl(timer_heap, entry)

cdef void _IncomingSubscription_cb_rx_refresh_impl(pjsip_evsub *sub, pjsip_rx_data *rdata,
                                              int *p_st_code, pj_str_t **p_st_text,
                                              pjsip_hdr *res_hdr, pjsip_msg_body **p_body) with gil:
    cdef void *subscription_void
    cdef IncomingSubscription subscription
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        subscription_void = pjsip_evsub_get_mod_data(sub, ua._event_module.id)
        if subscription_void == NULL:
            p_st_code[0] = 481
            return
        subscription = <object> subscription_void
        if rdata != NULL:
            if subscription.peer_address is None:
                subscription.peer_address = EndpointAddress(rdata.pkt_info.src_name, rdata.pkt_info.src_port)
            else:
                subscription.peer_address.ip = rdata.pkt_info.src_name
                subscription.peer_address.port = rdata.pkt_info.src_port
        p_st_code[0] = subscription._cb_rx_refresh(ua, rdata)
    except:
        ua._handle_exception(1)

cdef void _IncomingSubscription_cb_rx_refresh(pjsip_evsub *sub, pjsip_rx_data *rdata,
                                              int *p_st_code, pj_str_t **p_st_text,
                                              pjsip_hdr *res_hdr, pjsip_msg_body **p_body) noexcept nogil:
    with gil:
        _IncomingSubscription_cb_rx_refresh_impl(sub, rdata, p_st_code, p_st_text, res_hdr, p_body)

cdef void _IncomingSubscription_cb_server_timeout_impl(pjsip_evsub *sub) with gil:
    cdef void *subscription_void
    cdef IncomingSubscription subscription
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        subscription_void = pjsip_evsub_get_mod_data(sub, ua._event_module.id)
        if subscription_void == NULL:
            return
        subscription = <object> subscription_void
        subscription._cb_server_timeout(ua)
    except:
        ua._handle_exception(1)

cdef void _IncomingSubscription_cb_server_timeout(pjsip_evsub *sub) noexcept nogil:
    with gil:
        _IncomingSubscription_cb_server_timeout_impl(sub)

cdef void _IncomingSubscription_cb_tsx_impl(pjsip_evsub *sub, pjsip_transaction *tsx, pjsip_event *event) with gil:
    cdef void *subscription_void
    cdef IncomingSubscription subscription
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        subscription_void = pjsip_evsub_get_mod_data(sub, ua._event_module.id)
        if subscription_void == NULL:
            return
        subscription = <object> subscription_void
        subscription._cb_tsx(ua, event)
    except:
        ua._handle_exception(1)

cdef void _IncomingSubscription_cb_tsx(pjsip_evsub *sub, pjsip_transaction *tsx, pjsip_event *event) noexcept nogil:
    with gil:
        _IncomingSubscription_cb_tsx_impl(sub, tsx, event)

# globals

cdef pjsip_evsub_user _subs_cb
_subs_cb.on_evsub_state = _Subscription_cb_state
_subs_cb.on_tsx_state = _Subscription_cb_tsx
_subs_cb.on_rx_notify = _Subscription_cb_notify
_subs_cb.on_client_refresh = _Subscription_cb_refresh
cdef pjsip_evsub_user _incoming_subs_cb
_incoming_subs_cb.on_rx_refresh = _IncomingSubscription_cb_rx_refresh
_incoming_subs_cb.on_server_timeout = _IncomingSubscription_cb_server_timeout
_incoming_subs_cb.on_tsx_state = _IncomingSubscription_cb_tsx
_re_content_type = re.compile("^([a-zA-Z0-9\-.!%*_+`'~]+)\/([a-zA-Z0-9\-.!%*_+`'~]+)$")
