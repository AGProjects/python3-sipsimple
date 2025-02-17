
"""
Handling of MSRP media streams according to RFC4975, RFC4976, RFC5547 and RFC3994.
"""

__all__ = ['MSRPStreamError', 'MSRPStreamBase']

import traceback


from application.notification import NotificationCenter, NotificationData, IObserver
from application.python import Null
from application.system import host
from gnutls.errors import CertificateAuthorityError, CertificateError, CertificateRevokedError

from twisted.internet.error import ConnectionDone
from zope.interface import implementer

from eventlib import api
from msrplib.connect import DirectConnector, DirectAcceptor, RelayConnection, MSRPRelaySettings
from msrplib.protocol import URI
from msrplib.session import contains_mime_type

from sipsimple.account import Account, BonjourAccount
from sipsimple.configuration.settings import SIPSimpleSettings
from sipsimple.core import SDPAttribute, SDPConnection, SDPMediaStream
from sipsimple.streams import IMediaStream, MediaStreamType, StreamError
from sipsimple.threading.green import run_in_green_thread
from gnutls.errors import CertificateError, CertificateAuthorityError, CertificateExpiredError, CertificateSecurityError, CertificateRevokedError


class MSRPStreamError(StreamError):
    pass


@implementer(IMediaStream, IObserver)
class MSRPStreamBase(object, metaclass=MediaStreamType):

    # Attributes that need to be defined by each MSRP stream type
    type = None
    priority = None
    msrp_session_class = None

    media_type = None
    accept_types = None
    accept_wrapped_types = None

    # These attributes are always False for any MSRP stream
    hold_supported = False
    on_hold = False
    on_hold_by_local = False
    on_hold_by_remote = False

    def __new__(cls, *args, **kw):
        if cls is MSRPStreamBase:
            raise TypeError("MSRPStreamBase cannot be instantiated directly")
        return object.__new__(cls)

    def __init__(self, direction='sendrecv'):
        self.direction = direction
        self.greenlet = None
        self.local_media = None
        self.remote_media = None
        self.msrp = None  # Placeholder for the MSRPTransport that will be set when started
        self.msrp_connector = None
        self.cpim_enabled = None  # Boolean value. None means it was not negotiated yet
        self.session = None
        self.msrp_session = None
        self.shutting_down = False
        self.local_role = None
        self.remote_role = None
        self.transport = None
        self.remote_accept_types = None
        self.remote_accept_wrapped_types = None

        self._initialize_done = False
        self._done = False
        self._failure_reason = None

    @property
    def local_uri(self):
        msrp = self.msrp or self.msrp_connector
        return msrp.local_uri if msrp is not None else None

    def _create_local_media(self, uri_path):
        transport = "TCP/TLS/MSRP" if uri_path[-1].use_tls else "TCP/MSRP"
        attributes = []
        path = " ".join(str(uri) for uri in uri_path)

        attributes.append(SDPAttribute(b"path", path.encode()))
        if self.direction not in [None, 'sendrecv']:
            attributes.append(SDPAttribute(self.direction.encode(), b''))
        if self.accept_types is not None:
            a_types = " ".join(self.accept_types)
            attributes.append(SDPAttribute(b"accept-types", a_types.encode()))
        if self.accept_wrapped_types is not None:
            a_w_types = " ".join(self.accept_wrapped_types)
            attributes.append(SDPAttribute(b"accept-wrapped-types", a_w_types.encode()))
        attributes.append(SDPAttribute(b"setup", self.local_role.encode() if self.local_role else None))
        local_ip = uri_path[-1].host
        connection = SDPConnection(local_ip.encode())
        return SDPMediaStream(self.media_type.encode(), uri_path[-1].port or 2855, transport.encode(), connection=connection, formats=[b"*"], attributes=attributes)

    # The public API (the IMediaStream interface)

    # noinspection PyUnusedLocal
    def get_local_media(self, remote_sdp=None, index=0):
        return self.local_media

    def new_from_sdp(self, session, remote_sdp, stream_index):
        raise NotImplementedError

    @run_in_green_thread
    def initialize(self, session, direction):
        self.greenlet = api.getcurrent()
        notification_center = NotificationCenter()
        notification_center.add_observer(self, sender=self)
        settings = SIPSimpleSettings()
        try:
            self.session = session
            self.transport = self.session.account.msrp.transport
            outgoing = direction == 'outgoing'
            logger = NotificationProxyLogger()
            if self.session.account is BonjourAccount():
                if outgoing:
                    self.msrp_connector = DirectConnector(logger=logger)
                    self.local_role = 'active'
                else:
                    if self.transport == 'tls' and settings.tls.certificate is None:
                        raise MSRPStreamError("Cannot accept MSRP connection without a TLS certificate")
                    self.msrp_connector = DirectAcceptor(logger=logger)
                    self.local_role = 'passive'
            else:
                if self.session.account.msrp.connection_model == 'relay':
                    if not outgoing and self.remote_role in ('actpass', 'passive'):
                        # 'passive' not allowed by the RFC but play nice for interoperability. -Saul
                        self.msrp_connector = DirectConnector(logger=logger, use_sessmatch=True)
                        self.local_role = 'active'
                    elif outgoing and not self.session.account.nat_traversal.use_msrp_relay_for_outbound:
                        self.msrp_connector = DirectConnector(logger=logger, use_sessmatch=True)
                        self.local_role = 'active'
                    else:
                        if self.session.account.nat_traversal.msrp_relay is None:
                            relay_host = relay_port = None
                        else:
                            if self.transport != self.session.account.nat_traversal.msrp_relay.transport:
                                raise MSRPStreamError("MSRP relay transport conflicts with MSRP transport setting")
                            relay_host = self.session.account.nat_traversal.msrp_relay.host
                            relay_port = self.session.account.nat_traversal.msrp_relay.port
                        relay = MSRPRelaySettings(domain=self.session.account.uri.host.decode(),
                                                  username=self.session.account.uri.user.decode(),
                                                  password=self.session.account.credentials.password.decode(),
                                                  host=relay_host,
                                                  port=relay_port,
                                                  use_tls=self.transport=='tls')
                        self.msrp_connector = RelayConnection(relay, 'passive', logger=logger, use_sessmatch=True)
                        self.local_role = 'actpass' if outgoing else 'passive'
                else:
                    if not outgoing and self.remote_role in ('actpass', 'passive'):
                        # 'passive' not allowed by the RFC but play nice for interoperability. -Saul
                        self.msrp_connector = DirectConnector(logger=logger, use_sessmatch=True)
                        self.local_role = 'active'
                    else:
                        if not outgoing and self.transport == 'tls' and settings.tls.certificate is None:
                            raise MSRPStreamError("Cannot accept MSRP connection without a TLS certificate")
                        self.msrp_connector = DirectAcceptor(logger=logger, use_sessmatch=True)
                        self.local_role = 'actpass' if outgoing else 'passive'
            full_local_path = self.msrp_connector.prepare(local_uri=URI(host=host.default_ip, port=0, use_tls=self.transport=='tls', credentials=self.session.account.tls_credentials))
            self.local_media = self._create_local_media(full_local_path)
        except (CertificateError, CertificateAuthorityError, CertificateExpiredError, CertificateSecurityError, CertificateRevokedError) as e:
            reason = "%s for CN %s issued by %s" % (e.error, e.certificate.subject.CN, e.certificate.issuer.CN)
            notification_center.post_notification('MediaStreamDidNotInitialize', sender=self, data=NotificationData(reason=reason, transport=self.transport, credentials=self.session.account.tls_credentials))
        except Exception as e:
            notification_center.post_notification('MediaStreamDidNotInitialize', sender=self, data=NotificationData(reason=str(e), transport=self.transport, credentials=self.session.account.tls_credentials))
        else:
            notification_center.post_notification('MediaStreamDidInitialize', sender=self)
        finally:
            self._initialize_done = True
            self.greenlet = None

    # noinspection PyUnusedLocal
    @run_in_green_thread
    def start(self, local_sdp, remote_sdp, stream_index):
        self.greenlet = api.getcurrent()
        notification_center = NotificationCenter()
        context = 'sdp_negotiation'
        try:
            remote_media = remote_sdp.media[stream_index]
            self.remote_media = remote_media
            self.remote_accept_types = remote_media.attributes.getfirst(b'accept-types', b'').decode().split()
            self.remote_accept_wrapped_types = remote_media.attributes.getfirst(b'accept-wrapped-types', b'').decode().split()
            self.cpim_enabled = contains_mime_type(self.accept_types, 'message/cpim') and contains_mime_type(self.remote_accept_types, 'message/cpim')
            remote_uri_path = remote_media.attributes.getfirst(b'path')
            if remote_uri_path is None:
                raise AttributeError("remote SDP media does not have 'path' attribute")
            full_remote_path = [URI.parse(uri) for uri in remote_uri_path.decode().split()]
            remote_transport = 'tls' if full_remote_path[0].use_tls else 'tcp'
            if self.transport != remote_transport:
                raise MSRPStreamError("remote transport ('%s') different from local transport ('%s')" % (remote_transport, self.transport))
            if isinstance(self.session.account, Account) and self.local_role == 'actpass':
                remote_setup = remote_media.attributes.getfirst(b'setup', b'passive').decode()
                if remote_setup == 'passive':
                    # If actpass is offered connectors are always started as passive
                    # We need to switch to active if the remote answers with passive
                    if self.session.account.msrp.connection_model == 'relay':
                        self.msrp_connector.mode = 'active'
                    else:
                        local_uri = self.msrp_connector.local_uri
                        logger = self.msrp_connector.logger
                        self.msrp_connector = DirectConnector(logger=logger, use_sessmatch=True)
                        self.msrp_connector.prepare(local_uri)
            context = 'start'
            self.msrp = self.msrp_connector.complete(full_remote_path)
            if self.msrp_session_class is not None:
                self.msrp_session = self.msrp_session_class(self.msrp, accept_types=self.accept_types, on_incoming_cb=self._handle_incoming, automatic_reports=False)
            self.msrp_connector = None
        except (CertificateAuthorityError, CertificateError, CertificateRevokedError) as e:
            peer = '%s:%s' % (full_remote_path[0].host, full_remote_path[0].port)
            self._failure_reason = "%s - %s" % (peer, e.error)
            notification_center.post_notification('MediaStreamDidFail', sender=self, data=NotificationData(context=context, reason=self._failure_reason, transport=self.transport, credentials=self.session.account.tls_credentials))
        except Exception as e:
            #traceback.print_exc()
            self._failure_reason = str(e)
            notification_center.post_notification('MediaStreamDidFail', sender=self, data=NotificationData(context=context, reason=self._failure_reason, transport=self.transport, credentials=self.session.account.tls_credentials))
        else:
            notification_center.post_notification('MediaStreamDidStart', sender=self)
        finally:
            self.greenlet = None

    def deactivate(self):
        self.shutting_down = True

    @run_in_green_thread
    def end(self):
        if self._done:
            return
        self._done = True
        notification_center = NotificationCenter()
        if not self._initialize_done:
            # we are in the middle of initialize()
            try:
                msrp_connector = self.msrp_connector
                if self.greenlet is not None:
                    api.kill(self.greenlet)
                if msrp_connector is not None:
                    msrp_connector.cleanup()
            finally:
                notification_center.post_notification('MediaStreamDidNotInitialize', sender=self, data=NotificationData(reason='Interrupted'))
                notification_center.discard_observer(self, sender=self)
                self.msrp_connector = None
                self.greenlet = None
        else:
            notification_center.post_notification('MediaStreamWillEnd', sender=self)
            msrp = self.msrp
            msrp_session = self.msrp_session
            msrp_connector = self.msrp_connector
            try:
                if self.greenlet is not None:
                    api.kill(self.greenlet)
                if msrp_session is not None:
                    msrp_session.shutdown()
                elif msrp is not None:
                    msrp.loseConnection(wait=False)
                if msrp_connector is not None:
                    msrp_connector.cleanup()
            finally:
                notification_center.post_notification('MediaStreamDidEnd', sender=self, data=NotificationData(error=self._failure_reason))
                notification_center.remove_observer(self, sender=self)
                self.msrp = None
                self.msrp_session = None
                self.msrp_connector = None
                self.session = None
                self.greenlet = None

    # noinspection PyMethodMayBeStatic,PyUnusedLocal
    def validate_update(self, remote_sdp, stream_index):
        return True  # TODO

    def update(self, local_sdp, remote_sdp, stream_index):
        pass  # TODO

    def hold(self):
        pass

    def unhold(self):
        pass

    def reset(self, stream_index):
        pass

    # Internal IObserver interface

    def handle_notification(self, notification):
        handler = getattr(self, '_NH_%s' % notification.name, Null)
        handler(notification)

    # Internal message handlers

    def _handle_incoming(self, chunk=None, error=None):
        notification_center = NotificationCenter()
        if error is not None:
            if self.shutting_down and isinstance(error.value, ConnectionDone):
                return
            self._failure_reason = error.getErrorMessage()
            notification_center.post_notification('MediaStreamDidFail', sender=self, data=NotificationData(context='reading', reason=self._failure_reason, transport=self.transport, credentials=self.session.account.tls_credentials))
        elif chunk is not None:
            method_handler = getattr(self, '_handle_%s' % chunk.method, None)
            if method_handler is not None:
                method_handler(chunk)

    def _handle_REPORT(self, chunk):
        pass

    def _handle_SEND(self, chunk):
        pass


# temporary solution. to be replaced later by a better logging system in msrplib -Dan
#

class ChunkInfo(object):
    __slots__ = 'content_type', 'header', 'footer', 'data'

    def __init__(self, content_type, header='', footer='', data=''):
        self.content_type = content_type
        self.header = header
        self.footer = footer
        self.data = data

    def __repr__(self):
        return "{0.__class__.__name__}(content_type={0.content_type!r}, header={0.header!r}, footer={0.footer!r}, data={0.data!r})".format(self)

    @property
    def content(self):
        return self.header + self.data + self.footer

    @property
    def normalized_content(self):
        header = self.header.decode() if isinstance(self.header, bytes) else self.header
        footer = self.footer.decode() if isinstance(self.footer, bytes) else self.footer
        try:
            data = self.data.decode() if isinstance(self.data, bytes) else self.data
        except UnicodeDecodeError:
            data = '<<<stripped data>>>'
        
        if not data:
            return header + footer
        elif self.content_type == 'message/cpim':
            headers, sep, body = data.partition('\r\n\r\n')
            if not sep:
                return header + data + footer
            mime_headers, mime_sep, mime_body = body.partition('\n\n')
            if not mime_sep:
                return header + data + footer
            for mime_header in mime_headers.lower().splitlines():
                if mime_header.startswith('content-type:'):
                    wrapped_content_type = mime_header[13:].partition(';')[0].strip()
                    break
            else:
                wrapped_content_type = None
            if wrapped_content_type is None or wrapped_content_type == 'application/im-iscomposing+xml' or wrapped_content_type.startswith(('text/', 'message/')):
                data = data
            else:
                data = headers + sep + mime_headers + mime_sep + '<<<stripped data>>>'
            return header + data + footer
        elif self.content_type is None or self.content_type == 'application/im-iscomposing+xml' or self.content_type.startswith(('text/', 'message/')):
            return header + data + footer
        else:
            return header + '<<<stripped data>>>' + footer


class NotificationProxyLogger(object):
    def __init__(self):
        from application import log
        self.level = log.level
        self.notification_center = NotificationCenter()
        self.log_settings = SIPSimpleSettings().logs

    def received_chunk(self, data, transport):
        if self.log_settings.trace_msrp:
            chunk_info = ChunkInfo(data.content_type, header=data.chunk_header, footer=data.chunk_footer, data=data.data)
            notification_data = NotificationData(direction='incoming', local_address=transport.getHost(), remote_address=transport.getPeer(), data=chunk_info.normalized_content, illegal=False)
            self.notification_center.post_notification('MSRPTransportTrace', sender=transport, data=notification_data)

    def sent_chunk(self, data, transport):
        if self.log_settings.trace_msrp:
            chunk_info = ChunkInfo(data.content_type, header=data.encoded_header, footer=data.encoded_footer, data=data.data)
            notification_data = NotificationData(direction='outgoing', local_address=transport.getHost(), remote_address=transport.getPeer(), data=chunk_info.normalized_content, illegal=False)
            self.notification_center.post_notification('MSRPTransportTrace', sender=transport, data=notification_data)

    def received_illegal_data(self, data, transport):
        if self.log_settings.trace_msrp:
            notification_data = NotificationData(direction='incoming', local_address=transport.getHost(), remote_address=transport.getPeer(), data=data, illegal=True)
            self.notification_center.post_notification('MSRPTransportTrace', sender=transport, data=notification_data)

    def debug(self, message, *args, **kw):
        pass

    def info(self, message, *args, **kw):
        if self.log_settings.trace_msrp:
            self.notification_center.post_notification('MSRPLibraryLog', data=NotificationData(message=message % args if args else message, level=self.level.INFO))

    def warning(self, message, *args, **kw):
        if self.log_settings.trace_msrp:
            self.notification_center.post_notification('MSRPLibraryLog', data=NotificationData(message=message % args if args else message, level=self.level.WARNING))

    warn = warning

    def error(self, message, *args, **kw):
        if self.log_settings.trace_msrp:
            self.notification_center.post_notification('MSRPLibraryLog', data=NotificationData(message=message % args if args else message, level=self.level.ERROR))

    def exception(self, message='', *args, **kw):
        if self.log_settings.trace_msrp:
            message = message % args if args else message
            exception = traceback.format_exc()
            self.notification_center.post_notification('MSRPLibraryLog', data=NotificationData(message=message + '\n' + exception if message else exception, level=self.level.ERROR))

    def critical(self, message, *args, **kw):
        if self.log_settings.trace_msrp:
            self.notification_center.post_notification('MSRPLibraryLog', data=NotificationData(message=message % args if args else message, level=self.level.CRITICAL))

    fatal = critical


from sipsimple.streams.msrp import chat, filetransfer, screensharing
