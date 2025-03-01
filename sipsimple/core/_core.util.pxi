
import platform
import re
import sys

from application.version import Version


cdef class PJSTR:
    def __cinit__(self, str):
        self.str = str
        _str_to_pj_str(str, &self.pj_str)

    def __str__(self):
        return self.str

cdef class SIPStatusMessages:
    cdef object _default_status

    def __cinit__(self, *args, **kwargs):
        self._default_status = _pj_str_to_str(pjsip_get_status_text(0)[0])

    def __getitem__(self, int val):
        cdef object _status
        _status = _pj_str_to_str(pjsip_get_status_text(val)[0])
        if _status == self._default_status:
            raise IndexError("Unknown SIP response code: %d" % val)
        return _status


cdef class frozenlist:
    def __cinit__(self, *args, **kw):
        self.list = list()
        self.initialized = 0
        self.hash = 0
    def __init__(self, *args, **kw):
        if not self.initialized:
            self.list = list(*args, **kw)
            self.initialized = 1
            self.hash = hash(tuple(self.list))
    def __reduce__(self):
        return (self.__class__, (self.list,), None)
    def __repr__(self):
        return "frozenlist(%r)" % self.list
    def __len__(self):
        return self.list.__len__()
    def __hash__(self):
        return self.hash
    def __iter__(self):
        return self.list.__iter__()
    def __cmp__(self, frozenlist other):
        return self.list.__cmp__(other.list)
    def __richcmp__(frozenlist self, other, op):
        if isinstance(other, frozenlist):
            other = (<frozenlist>other).list
        if op == 0:
            return self.list.__cmp__(other) < 0
        elif op == 1:
            return self.list.__cmp__(other) <= 0
        elif op == 2:
            return self.list.__eq__(other)
        elif op == 3:
            return self.list.__ne__(other)
        elif op == 4:
            return self.list.__cmp__(other) > 0
        elif op == 5:
            return self.list.__cmp__(other) >= 0
        else:
            return NotImplemented
    def __contains__(self, item):
        return self.list.__contains__(item)
    def __getitem__(self, key):
        return self.list.__getitem__(key)
    def __add__(first, second):
        if isinstance(first, frozenlist):
            first = (<frozenlist>first).list
        if isinstance(second, frozenlist):
            second = (<frozenlist>second).list
        return frozenlist(first+second)
    def __mul__(first, second):
        if isinstance(first, frozenlist):
            first = (<frozenlist>first).list
        if isinstance(second, frozenlist):
            second = (<frozenlist>second).list
        return frozenlist(first*second)
    def __reversed__(self):
        return self.list.__reversed__()
    def count(self, elem):
        return self.list.count(elem)
    def index(self, elem):
        return self.list.index(elem)


cdef class frozendict:
    def __cinit__(self, *args, **kw):
        self.dict = dict()
        self.initialized = 0
    def __init__(self, *args, **kw):
        if not self.initialized:
            self.dict = dict(*args, **kw)
            self.initialized = 1
            self.hash = hash(tuple(self.dict.iteritems()))
    def __reduce__(self):
        return (self.__class__, (self.dict,), None)
    def __repr__(self):
        return "frozendict(%r)" % self.dict
    def __len__(self):
        return self.dict.__len__()
    def __hash__(self):
        return self.hash
    def __iter__(self):
        return self.dict.__iter__()
    def __cmp__(self, frozendict other):
        return self.dict.__cmp__(other.dict)
    def __richcmp__(frozendict self, other, op):
        if isinstance(other, frozendict):
            other = (<frozendict>other).dict
        if op == 0:
            return self.dict.__cmp__(other) < 0
        elif op == 1:
            return self.dict.__cmp__(other) <= 0
        elif op == 2:
            return self.dict.__eq__(other)
        elif op == 3:
            return self.dict.__ne__(other)
        elif op == 4:
            return self.dict.__cmp__(other) > 0
        elif op == 5:
            return self.dict.__cmp__(other) >= 0
        else:
            return NotImplemented
    def __contains__(self, item):
        return self.dict.__contains__(item)
    def __getitem__(self, key):
        return self.dict.__getitem__(key)
    def copy(self):
        return self
    def get(self, *args):
        return self.dict.get(*args)
    def has_key(self, key):
        return self.dict.has_key(key)
    def items(self):
        return list(self.dict.items())
    def iteritems(self):
        return list(self.dict.items())
    def iterkeys(self):
        return list(self.dict.keys())
    def itervalues(self):
        return list(self.dict.values())
    def keys(self):
        return list(self.dict.keys())
    def values(self):
        return list(self.dict.values())


# functions

cdef int _str_to_pj_str(object string, pj_str_t *pj_str) except -1:
    if type(string) != bytes:
        pj_str.ptr = PyBytes_AsString(string.encode())
    else:
        pj_str.ptr = PyBytes_AsString(string)
    pj_str.slen = len(string)

cdef object _pj_str_to_bytes(pj_str_t pj_str):
    return PyBytes_FromStringAndSize(pj_str.ptr, pj_str.slen)

cdef object _pj_str_to_str(pj_str_t pj_str):
    return PyBytes_FromStringAndSize(pj_str.ptr, pj_str.slen).decode()

cdef object _pj_buf_len_to_str(object buf, int buf_len):
    return PyBytes_FromStringAndSize(buf, buf_len)

cdef object _buf_to_str(object buf):
    return PyBytes_FromString(buf).decode()

cdef object _str_as_str(object string):
    if type(string) != bytes:
        return PyBytes_AsString(string.encode())
    else:
        return PyBytes_AsString(string)

cdef object _str_as_size(object string):
    if type(string) != bytes:
        return PyBytes_Size(string.encode())
    else:
        return PyBytes_Size(string)

cdef object _pj_status_to_str(int status):
    cdef char buf[PJ_ERR_MSG_SIZE]
    return _pj_str_to_str(pj_strerror(status, buf, PJ_ERR_MSG_SIZE))

cdef object _pj_status_to_def(int status):
    return _re_pj_status_str_def.match(_pj_status_to_str(status)).group(1)

cdef dict _pjsip_param_to_dict(pjsip_param *param_list):
    cdef pjsip_param *param
    cdef dict retval = dict()
    param = <pjsip_param *> (<pj_list *> param_list).next
    while param != param_list:
        if param.value.slen == 0:
            retval[_pj_str_to_str(param.name)] = None
        else:
            retval[_pj_str_to_str(param.name)] = _pj_str_to_str(param.value)
        param = <pjsip_param *> (<pj_list *> param).next
    return retval

cdef int _dict_to_pjsip_param(object params, pjsip_param *param_list, pj_pool_t *pool):
    cdef pjsip_param *param = NULL
    for name, value in params.iteritems():
        param = <pjsip_param *> pj_pool_alloc(pool, sizeof(pjsip_param))
        if param == NULL:
            return -1
        name = name if isinstance(name, bytes) else name.encode()
        _str_to_pj_str(name, &param.name)
        if value is None:
            param.value.slen = 0
        else:
            value = value if isinstance(value, bytes) else value.encode()
            _str_to_pj_str(value, &param.value)
        pj_list_insert_after(<pj_list *> param_list, <pj_list *> param)
    return 0

cdef int _pjsip_msg_to_dict(pjsip_msg *msg, dict info_dict) except -1:
    cdef pjsip_msg_body *body
    cdef pjsip_hdr *header
    cdef pjsip_generic_array_hdr *array_header
    cdef pjsip_ctype_hdr *ctype_header
    cdef pjsip_cseq_hdr *cseq_header
    cdef char *buf
    cdef int buf_len, status
    headers = {}
    header = <pjsip_hdr *> (<pj_list *> &msg.hdr).next

    try:
        skip_replaces = info_dict['skip_replaces']
    except KeyError:
        skip_replaces = False

    while header != &msg.hdr:
        header_name = _pj_str_to_str(header.name)
        header_data = None
        multi_header = False
        if header_name in ("Accept", "Allow", "Require", "Supported", "Unsupported", "Allow-Events"):
            array_header = <pjsip_generic_array_hdr *> header
            header_data = []
            if array_header.count < 128:
                for i from 0 <= i < array_header.count:
                    header_data.append(_pj_str_to_bytes(array_header.values[i]))
        elif header_name == "Contact":
            multi_header = True
            header_data = FrozenContactHeader_create(<pjsip_contact_hdr *> header)
        elif header_name == "Content-Length":
            header_data = (<pjsip_clen_hdr *> header).len
        elif header_name == "Content-Type":
            header_data = FrozenContentTypeHeader_create(<pjsip_ctype_hdr *> header)
        elif header_name == "CSeq":
            cseq_header = <pjsip_cseq_hdr *> header
            hvalue = _pj_str_to_str(cseq_header.method.name)
            header_data = (cseq_header.cseq, hvalue)
        elif header_name in ("Expires", "Max-Forwards", "Min-Expires"):
            header_data = (<pjsip_generic_int_hdr *> header).ivalue
        elif header_name == "From":
            header_data = FrozenFromHeader_create(<pjsip_fromto_hdr *> header)
        elif header_name == "To":
            header_data = FrozenToHeader_create(<pjsip_fromto_hdr *> header)
        elif header_name == "Route":
            multi_header = True
            header_data = FrozenRouteHeader_create(<pjsip_routing_hdr *> header)
        elif header_name == "Reason":
            value = _pj_str_to_str((<pjsip_generic_string_hdr *>header).hvalue)
            protocol, sep, params_str = value.partition(';')
            params = frozendict([(name, value or None) for name, sep, value in [param.partition('=') for param in params_str.split(';')]])
            header_data = FrozenReasonHeader(protocol, params)
        elif header_name == "Record-Route":
            multi_header = True
            header_data = FrozenRecordRouteHeader_create(<pjsip_routing_hdr *> header)
        elif header_name == "Retry-After":
            header_data = FrozenRetryAfterHeader_create(<pjsip_retry_after_hdr *> header)
        elif header_name == "Via":
            multi_header = True
            header_data = FrozenViaHeader_create(<pjsip_via_hdr *> header)
        elif header_name == "Warning":
            match = _re_warning_hdr.match(_pj_str_to_str((<pjsip_generic_string_hdr *>header).hvalue))
            if match is not None:
                warning_params = match.groupdict()
                warning_params['code'] = int(warning_params['code'])
                header_data = FrozenWarningHeader(**warning_params)
        elif header_name == "Event":
            header_data = FrozenEventHeader_create(<pjsip_event_hdr *> header)
        elif header_name == "Subscription-State":
            header_data = FrozenSubscriptionStateHeader_create(<pjsip_sub_state_hdr *> header)
        elif header_name == "Refer-To":
            header_data = FrozenReferToHeader_create(<pjsip_generic_string_hdr *> header)
        elif header_name == "Subject":
            header_data = FrozenSubjectHeader_create(<pjsip_generic_string_hdr *> header)
        elif header_name == "Replaces" and not skip_replaces:
            header_data = FrozenReplacesHeader_create(<pjsip_replaces_hdr *> header)
        # skip the following headers:
        elif header_name not in ("Authorization", "Proxy-Authenticate", "Proxy-Authorization", "WWW-Authenticate"):
            hvalue = (<pjsip_generic_string_hdr *> header).hvalue
            header_value = _pj_str_to_str(hvalue)
            header_data = FrozenHeader(header_name, header_value)

        if header_data is not None:
            if multi_header:
                headers.setdefault(header_name, []).append(header_data)
            else:
                if header_name not in headers:
                    headers[header_name] = header_data
        header = <pjsip_hdr *> (<pj_list *> header).next
    info_dict["headers"] = headers
    body = msg.body

    if body == NULL:
        info_dict["body"] = None
    else:
        status = pjsip_print_body(body, &buf, &buf_len)
        if status != 0:
            info_dict["body"] = None
        else:
            info_dict["body"] = _pj_buf_len_to_str(buf, buf_len)

    if msg.type == PJSIP_REQUEST_MSG:
        info_dict["method"] = _pj_str_to_str(msg.line.req.method.name)
        # You need to call pjsip_uri_get_uri on the request URI if the message is for transmitting,
        # but it isn't required if message is one received. Otherwise, a seg fault occurs. Don't ask.
        info_dict["request_uri"] = FrozenSIPURI_create(<pjsip_sip_uri*>pjsip_uri_get_uri(msg.line.req.uri))
    else:
        info_dict["code"] = msg.line.status.code
        info_dict["reason"] = _pj_str_to_str(msg.line.status.reason)
    return 0

cdef int _is_valid_ip(int af, object ip) except -1:
    cdef char buf[16]
    cdef pj_str_t src
    cdef int status
    _str_to_pj_str(ip, &src)
    status = pj_inet_pton(af, &src, buf)
    if status == 0:
        return 1
    else:
        return 0

cdef int _get_ip_version(object ip) except -1:
    if _is_valid_ip(pj_AF_INET(), ip):
        return pj_AF_INET()
    elif _is_valid_ip(pj_AF_INET6(), ip):
        return pj_AF_INET()
    else:
        return 0

cdef int _add_headers_to_tdata(pjsip_tx_data *tdata, object headers) except -1:
    cdef pj_str_t name_pj, value_pj
    cdef pjsip_hdr *hdr
    for header in headers:
        hb = header.name if isinstance(header.name, bytes) else header.name.encode()
        bb = header.body if isinstance(header.body, bytes) else header.body.encode()
        _str_to_pj_str(hb, &name_pj)
        _str_to_pj_str(bb, &value_pj)
        hdr = <pjsip_hdr *> pjsip_generic_string_hdr_create(tdata.pool, &name_pj, &value_pj)
        pjsip_msg_add_hdr(tdata.msg, hdr)

cdef int _remove_headers_from_tdata(pjsip_tx_data *tdata, object headers) except -1:
    cdef pj_str_t header_name_pj
    cdef pjsip_hdr *hdr
    for header in headers:
        _str_to_pj_str(header, &header_name_pj)
        hdr = <pjsip_hdr *> pjsip_msg_find_remove_hdr_by_name(tdata.msg, &header_name_pj, NULL)

cdef int _BaseRouteHeader_to_pjsip_route_hdr(BaseIdentityHeader header, pjsip_route_hdr *pj_header, pj_pool_t *pool) except -1:
    cdef pjsip_param *param
    cdef pjsip_sip_uri *sip_uri
    pjsip_route_hdr_init(NULL, <void *> pj_header)
    sip_uri = <pjsip_sip_uri *> pj_pool_alloc(pool, sizeof(pjsip_sip_uri))
    _BaseSIPURI_to_pjsip_sip_uri(header.uri, sip_uri, pool)
    
    pj_header.name_addr.uri = <pjsip_uri *> sip_uri
    if header.display_name:
        _str_to_pj_str(header.display_name, &pj_header.name_addr.display)
    _dict_to_pjsip_param(header.parameters, &pj_header.other_param, pool)
    return 0

cdef int _BaseSIPURI_to_pjsip_sip_uri(BaseSIPURI uri, pjsip_sip_uri *pj_uri, pj_pool_t *pool) except -1:
    cdef pjsip_param *param
    pjsip_sip_uri_init(pj_uri, uri.secure)
    if uri.user:
        _str_to_pj_str(uri.user, &pj_uri.user)
    if uri.password:
        _str_to_pj_str(uri.password, &pj_uri.passwd)
    if uri.host:
        _str_to_pj_str(uri.host, &pj_uri.host)
    if uri.port:
        pj_uri.port = uri.port

    for name, value in uri.parameters.iteritems():
        if name == "lr":
            pj_uri.lr_param = 1
        elif name == "maddr":
            _str_to_pj_str(value, &pj_uri.maddr_param)
        elif name == "method":
            _str_to_pj_str(value, &pj_uri.method_param)
        elif name == "transport":
            _str_to_pj_str(value, &pj_uri.transport_param)
        elif name == "ttl":
            pj_uri.ttl_param = int(value)
        elif name == "user":
            _str_to_pj_str(value, &pj_uri.user_param)
        else:
            param = <pjsip_param *> pj_pool_alloc(pool, sizeof(pjsip_param))
            if name == 'hide':
                name = b'hide'
            elif name == 'tls_name':
                name = b'tls_name'
            _str_to_pj_str(name, &param.name)
            if value is None:
                param.value.slen = 0
            else:
                _str_to_pj_str(value, &param.value)
            pj_list_insert_after(<pj_list *> &pj_uri.other_param, <pj_list *> param)
    _dict_to_pjsip_param(uri.headers, &pj_uri.header_param, pool)
    return 0


def _get_device_name_encoding():
    if sys.platform == 'win32':
        encoding = 'mbcs'
    elif sys.platform.startswith('linux2') and Version.parse(platform.release()) < Version(2,6,31):
        encoding = 'latin1'
    else:
        encoding = 'utf-8'
    return encoding
_device_name_encoding = _get_device_name_encoding()

def decode_device_name(device_name):
    # ignore decoding errors, some systems (I'm looking at you, OSX), seem to misbehave
    return device_name.decode(_device_name_encoding, 'ignore')


# globals

cdef object _re_pj_status_str_def = re.compile("^.*\((.*)\)$")
cdef object _re_warning_hdr = re.compile('(?P<code>[0-9]{3}) (?P<agent>.*?) "(?P<text>.*?)"')
sip_status_messages = SIPStatusMessages()

