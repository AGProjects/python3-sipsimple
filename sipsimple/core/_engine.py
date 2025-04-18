
"""
Implements a mechanism for starting the SIP core engine based on PJSIP
(http://pjsip.org) stack.
"""

__all__ = ["Engine"]

import sys
import traceback
import atexit

from application.notification import NotificationCenter, NotificationData
from application.python.types import Singleton
from threading import Thread, RLock

from sipsimple import log, __version__
from sipsimple.core._core import PJSIPUA, PJ_VERSION, PJ_SVN_REVISION, SIPCoreError


class Engine(Thread, metaclass=Singleton):
    default_start_options = {"ip_address": None,
                             "udp_port": 0,
                             "tcp_port": None,
                             "tls_port": None,
                             "tls_verify_server": False,
                             "tls_ca_file": None,
                             "tls_cert_file": None,
                             "tls_privkey_file": None,
                             "tls_timeout": 3000,
                             "user_agent":  "sipsimple-%s-pjsip-%s-r%s" % (__version__, PJ_VERSION, PJ_SVN_REVISION),
                             "log_level": 0,
                             "trace_sip": False,
                             "detect_sip_loops": True,
                             "rtp_port_range": (50000, 50500),
                             "zrtp_cache": None,
                             "codecs": ["G722", "speex", "PCMU", "PCMA"],
                             "video_codecs": ["H264", "H263-1998", "VP8"],
                             "enable_colorbar_device": False,
                             "events": {"conference":      ["application/conference-info+xml"],
                                        "message-summary": ["application/simple-message-summary"],
                                        "presence":        ["multipart/related", "application/rlmi+xml", "application/pidf+xml"],
                                        "presence.winfo":  ["application/watcherinfo+xml"],
#                                        "dialog":          ["multipart/related", "application/rlmi+xml", "application/dialog-info+xml"],
#                                        "dialog.winfo":    ["application/watcherinfo+xml"],
                                        "refer":           ["message/sipfrag;version=2.0"],
                                        "xcap-diff":       ["application/xcap-diff+xml"]},
                             "incoming_events": set(),
                             "incoming_requests": set()}

    def __init__(self):
        self.notification_center = NotificationCenter()
        self._thread_started = False
        self._thread_stopping = False
        self._lock = RLock()
        self._options = None
        atexit.register(self.stop)
        super(Engine, self).__init__()
        self.daemon = True

    @property
    def is_running(self):
        return (hasattr(self, "_ua") and hasattr(self, "_thread_started")
                and self._thread_started and not self._thread_stopping)

    def __dir__(self):
        if hasattr(self, '_ua'):
            ua_attributes = [attr for attr in dir(self._ua) if not attr.startswith('__') and attr != 'poll']
        else:
            ua_attributes = []
        return sorted(set(dir(self.__class__) + list(self.__dict__.keys()) + ua_attributes))

    def __getattr__(self, attr):
        if attr not in ["_ua", "poll"] and hasattr(self, "_ua") and attr in dir(self._ua):
            return getattr(self._ua, attr)
        raise AttributeError("'%s' object has no attribute '%s'" % (self.__class__.__name__, attr))

    def __setattr__(self, attr, value):
        if attr not in ["_ua", "poll"] and hasattr(self, "_ua") and attr in dir(self._ua):
            setattr(self._ua, attr, value)
            return
        object.__setattr__(self, attr, value)

    def start(self, **kwargs):
        with self._lock:
            if self._thread_started:
                raise SIPCoreError("Worker thread was already started once")
            self._options = kwargs
            self._thread_started = True
            super(Engine, self).start()

    def stop(self):
        with self._lock:
            if self._thread_stopping:
                return
            if self._thread_started:
                self._thread_stopping = True

    # worker thread
    def run(self):
        self.notification_center.post_notification('SIPEngineWillStart', sender=self)
        init_options = Engine.default_start_options.copy()
        init_options.update(self._options)
        for k in list(init_options['events'].keys()):
            if isinstance(k, str):
                init_options['events'][k.encode()] = init_options['events'][k]
                del(init_options['events'][k])

        for k in list(init_options['events'].keys()):
            init_options['events'][k] = list(v.encode() if isinstance(v, str) else v for v in init_options['events'][k])

        try:
            self._ua = PJSIPUA(self._handle_event, **init_options)
        except Exception:
            log.exception('Exception occurred while starting the Engine')
            exc_type, exc_val, exc_tb = sys.exc_info()
            exc_tb = "".join(traceback.format_exception(exc_type, exc_val, exc_tb))
            self.notification_center.post_notification('SIPEngineGotException', sender=self, data=NotificationData(type=exc_type, value=exc_val, traceback=exc_tb))
            self.notification_center.post_notification('SIPEngineDidFail', sender=self)
            return
        else:
            self.notification_center.post_notification('SIPEngineDidStart', sender=self)
        failed = False
        while not self._thread_stopping:
            try:
                failed = self._ua.poll()
            except Exception as e:
                log.exception('Exception occurred while running the Engine')
                traceback.print_exc()
                exc_type, exc_val, exc_tb = sys.exc_info()
                self.notification_center.post_notification('SIPEngineGotException', sender=self, data=NotificationData(type=exc_type, value=exc_val, traceback="".join(traceback.format_exception(exc_type, exc_val, exc_tb))))
                failed = True
            if failed:
                self.notification_center.post_notification('SIPEngineDidFail', sender=self)
                break
        if not failed:
            self.notification_center.post_notification('SIPEngineWillEnd', sender=self)
        self._ua.dealloc()
        del self._ua
        self.notification_center.post_notification('SIPEngineDidEnd', sender=self)

    def _handle_event(self, event_name, **kwargs):
        sender = kwargs.pop("obj", None)
        if sender is None:
            sender = self
        self.notification_center.post_notification(event_name, sender, NotificationData(**kwargs))

