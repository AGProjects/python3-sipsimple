
"""
This module provides classes to parse and generate SDP related to SIP sessions that negotiate Instant Messaging, including CPIM as defined in RFC3862
"""

import binascii
import pickle as pickle
import codecs
import os
import random
import re
from email import charset as _charset
Charset = _charset.Charset

from application.python.descriptor import WriteOnceAttribute
from application.notification import IObserver, NotificationCenter, NotificationData
from application.python import Null
from application.python.types import Singleton
from application.system import openfile
from collections import defaultdict
from email.message import Message as EmailMessage
from email.parser import Parser as EmailParser
from eventlib.coros import queue
from eventlib.proc import spawn, ProcExit
from functools import partial
from msrplib.protocol import FailureReportHeader, SuccessReportHeader, UseNicknameHeader
from msrplib.session import MSRPSession, contains_mime_type
try:
    from otr import OTRSession, OTRTransport, OTRState, SMPStatus
    from otr.cryptography import DSAPrivateKey
    from otr.exceptions import IgnoreMessage, UnencryptedMessage, EncryptedMessageError, OTRError
except ModuleNotFoundError:
    IgnoreMessage = None

from zope.interface import implementer

from sipsimple.core import SIPURI, BaseSIPURI
from sipsimple.payloads import ParserError
from sipsimple.payloads.iscomposing import IsComposingDocument, State, LastActive, Refresh, ContentType
from sipsimple.storage import ISIPSimpleApplicationDataStorage
from sipsimple.streams import InvalidStreamError, UnknownStreamError
from sipsimple.streams.msrp import MSRPStreamError, MSRPStreamBase
from sipsimple.threading import run_in_thread, run_in_twisted_thread
from sipsimple.threading.green import run_in_green_thread
from sipsimple.util import MultilingualText, ISOTimestamp


__all__ = ['ChatStream', 'ChatStreamError', 'ChatIdentity', 'CPIMPayload', 'CPIMHeader', 'CPIMNamespace', 'CPIMParserError', 'OTRState', 'SMPStatus']


class ChatMimeMessage(EmailMessage):
    def set_charset(self, charset):
        # avoid automatic adding of Content-Transfer-Encoding header and conversion to base64
        # TODO: it seems impossible to get rid of the header itself though, is deep inside email.Generator._write

        if charset is None:
            self.del_param('charset')
            self._charset = None
            return

        if not isinstance(charset, Charset):
            charset = Charset(charset)

        self._charset = charset

        if 'MIME-Version' not in self:
            self.add_header('MIME-Version', '1.0')

        if 'Content-Type' not in self:
            self.add_header('Content-Type', 'text/plain', charset=charset.get_output_charset())
        else:
            self.set_param('charset', charset.get_output_charset())
    

class OTRTrustedPeer(object):
    fingerprint = WriteOnceAttribute()  # in order to be hashable this needs to be immutable

    def __init__(self, fingerprint, description='', **kw):
        if not isinstance(fingerprint, str):
            raise TypeError("fingerprint must be a string")
        self.fingerprint = fingerprint
        self.description = description
        self.__dict__.update(kw)

    def __hash__(self):
        return hash(self.fingerprint)

    def __eq__(self, other):
        if isinstance(other, OTRTrustedPeer):
            return self.fingerprint == other.fingerprint
        elif isinstance(other, str):
            return self.fingerprint == other
        else:
            return NotImplemented

    def __ne__(self, other):
        return not (self == other)

    def __repr__(self):
        return "{0.__class__.__name__}({0.fingerprint!r}, description={0.description!r})".format(self)

    def __reduce__(self):
        return self.__class__, (self.fingerprint,), self.__dict__


class OTRTrustedPeerSet(object):
    def __init__(self, iterable=()):
        self.__data__ = {}
        self.update(iterable)

    def __repr__(self):
        return "{}({})".format(self.__class__.__name__, list(self.__data__.values()))

    def __contains__(self, item):
        return item in self.__data__

    def __getitem__(self, item):
        return self.__data__[item]

    def __iter__(self):
        return iter(list(self.__data__.values()))

    def __len__(self):
        return len(self.__data__)

    def get(self, item, default=None):
        return self.__data__.get(item, default)

    def add(self, item):
        if not isinstance(item, OTRTrustedPeer):
            raise TypeError("item should be and instance of OTRTrustedPeer")
        self.__data__[item.fingerprint] = item

    def remove(self, item):
        del self.__data__[item]

    def discard(self, item):
        self.__data__.pop(item, None)

    def update(self, iterable=()):
        for item in iterable:
            self.add(item)


class OTRCache(object, metaclass=Singleton):
    def __init__(self):
        from sipsimple.application import SIPApplication
        if SIPApplication.storage is None:
            raise RuntimeError("Cannot access the OTR cache before SIPApplication.storage is defined")
        if ISIPSimpleApplicationDataStorage.providedBy(SIPApplication.storage):
            self.key_file = os.path.join(SIPApplication.storage.directory, 'otr.key')
            self.trusted_file = os.path.join(SIPApplication.storage.directory, 'otr.trusted')
            try:
                self.private_key = DSAPrivateKey.load(self.key_file)
                if self.private_key.key_size != 1024:
                    raise ValueError
            except NameError:
                return
            except (EnvironmentError, ValueError):
                self.private_key = DSAPrivateKey.generate()
                self.private_key.save(self.key_file)

            try:
                self.trusted_peers = pickle.load(open(self.trusted_file, 'rb'))
                if not isinstance(self.trusted_peers, OTRTrustedPeerSet) or not all(isinstance(item, OTRTrustedPeer) for item in self.trusted_peers):
                    raise ValueError("invalid OTR trusted peers file")
            except Exception:
                self.trusted_peers = OTRTrustedPeerSet()
                self.save()
        else:
            self.key_file = self.trusted_file = None
            try:
                self.private_key = DSAPrivateKey.generate()
            except NameError:
                pass

            self.trusted_peers = OTRTrustedPeerSet()

    # def generate_private_key(self):
    #     self.private_key = DSAPrivateKey.generate()
    #     if self.key_file:
    #         self.private_key.save(self.key_file)

    @run_in_thread('file-io')
    def save(self):
        if self.trusted_file is not None:
            with openfile(self.trusted_file, 'wb', permissions=0o600) as trusted_file:
                pickle.dump(self.trusted_peers, trusted_file)


@implementer(IObserver)
class OTREncryption(object):

    def __init__(self, stream):
        self.stream = stream
        self.otr_cache = OTRCache()

        try:
            self.otr_session = OTRSession(self.otr_cache.private_key, self.stream, supported_versions={3})  # we need at least OTR-v3 for question based SMP
        except NameError:
            self.otr_session = Null
            return


        notification_center = NotificationCenter()
        notification_center.add_observer(self, sender=stream)
        notification_center.add_observer(self, sender=self.otr_session)

    @property
    def active(self):
        try:
            return self.otr_session.encrypted
        except AttributeError:
            return False

    @property
    def cipher(self):
        return 'AES-128-CTR' if self.active else None

    @property
    def key_fingerprint(self):
        try:
            return binascii.hexlify(self.otr_session.local_private_key.public_key.fingerprint).decode()
        except (AttributeError, TypeError):
            return None

    @property
    def peer_fingerprint(self):
        try:
            return binascii.hexlify(self.otr_session.remote_public_key.fingerprint).decode()
        except (AttributeError, TypeError):
            return None

    @property
    def peer_name(self):
        try:
            return self.__dict__['peer_name']
        except KeyError:
            trusted_peer = self.otr_cache.trusted_peers.get(self.peer_fingerprint, None)
            if trusted_peer is None:
                return ''
            else:
                return self.__dict__.setdefault('peer_name', trusted_peer.description)

    @peer_name.setter
    def peer_name(self, name):
        old_name = self.peer_name
        new_name = self.__dict__['peer_name'] = name
        if old_name != new_name:
            trusted_peer = self.otr_cache.trusted_peers.get(self.peer_fingerprint, None)
            if trusted_peer is not None:
                trusted_peer.description = new_name
                self.otr_cache.save()
            notification_center = NotificationCenter()
            notification_center.post_notification("ChatStreamOTRPeerNameChanged", sender=self.stream, data=NotificationData(name=name))

    @property
    def verified(self):
        return self.peer_fingerprint in self.otr_cache.trusted_peers

    @verified.setter
    def verified(self, value):
        peer_fingerprint = self.peer_fingerprint
        old_verified = peer_fingerprint in self.otr_cache.trusted_peers
        new_verified = bool(value)
        if peer_fingerprint is None or new_verified == old_verified:
            return
        if new_verified:
            self.otr_cache.trusted_peers.add(OTRTrustedPeer(peer_fingerprint, description=self.peer_name))
        else:
            self.otr_cache.trusted_peers.remove(peer_fingerprint)
        self.otr_cache.save()
        notification_center = NotificationCenter()
        notification_center.post_notification("ChatStreamOTRVerifiedStateChanged", sender=self.stream, data=NotificationData(verified=new_verified))

    @run_in_twisted_thread
    def start(self):
        try:
            if self.otr_session is not None:
                self.otr_session.start()
        except AttributeError:
            pass

    @run_in_twisted_thread
    def stop(self):
        try:
            if self.otr_session is not None:
                self.otr_session.stop()
        except AttributeError:
            pass

    @run_in_twisted_thread
    def smp_verify(self, secret, question=None):
        self.otr_session.smp_verify(secret, question)

    @run_in_twisted_thread
    def smp_answer(self, secret):
        self.otr_session.smp_answer(secret)

    @run_in_twisted_thread
    def smp_abort(self):
        self.otr_session.smp_abort()

    def handle_notification(self, notification):
        handler = getattr(self, '_NH_%s' % notification.name, Null)
        handler(notification)

    def _NH_MediaStreamDidStart(self, notification):
        if self.stream.start_otr:
            self.otr_session.start()

    def _NH_MediaStreamDidEnd(self, notification):
        notification.center.remove_observer(self, sender=self.stream)
        notification.center.remove_observer(self, sender=self.otr_session)
        self.otr_session.stop()
        self.otr_session = None
        self.stream = None

    _NH_MediaStreamDidNotInitialize = _NH_MediaStreamDidEnd

    def _NH_OTRSessionStateChanged(self, notification):
        notification.center.post_notification('ChatStreamOTREncryptionStateChanged', sender=self.stream, data=notification.data)

    def _NH_OTRSessionSMPVerificationDidStart(self, notification):
        notification.center.post_notification('ChatStreamSMPVerificationDidStart', sender=self.stream, data=notification.data)

    def _NH_OTRSessionSMPVerificationDidNotStart(self, notification):
        notification.center.post_notification('ChatStreamSMPVerificationDidNotStart', sender=self.stream, data=notification.data)

    def _NH_OTRSessionSMPVerificationDidEnd(self, notification):
        notification.center.post_notification('ChatStreamSMPVerificationDidEnd', sender=self.stream, data=notification.data)


class ChatStreamError(MSRPStreamError): pass


class ChatStream(MSRPStreamBase):
    type = 'chat'
    priority = 1
    msrp_session_class = MSRPSession

    media_type = 'message'
    accept_types = ['message/cpim', 'text/*', 'image/*', 'application/im-iscomposing+xml']
    accept_wrapped_types = ['text/*', 'image/*', 'application/im-iscomposing+xml']

    prefer_cpim = True
    start_otr = True

    def __init__(self):
        super(ChatStream, self).__init__(direction='sendrecv')
        self.message_queue = queue()
        self.sent_messages = set()
        self.incoming_queue = defaultdict(list)
        self.message_queue_thread = None
        self.encryption = OTREncryption(self)

    @classmethod
    def new_from_sdp(cls, session, remote_sdp, stream_index):
        remote_stream = remote_sdp.media[stream_index]
        if remote_stream.media != b'message':
            raise UnknownStreamError
        expected_transport = 'TCP/TLS/MSRP' if session.account.msrp.transport=='tls' else 'TCP/MSRP'
        if remote_stream.transport != expected_transport.encode():
            raise InvalidStreamError("expected %s transport in chat stream, got %s" % (expected_transport, remote_stream.transport))
        if remote_stream.formats != [b'*']:
            raise InvalidStreamError("wrong format list specified")
        stream = cls()
        stream.remote_role = remote_stream.attributes.getfirst(b'setup', b'active')
        
        if remote_stream.direction != b'sendrecv':
            raise InvalidStreamError("Unsupported direction for chat stream: %s" % remote_stream.direction)
        remote_accept_types = remote_stream.attributes.getfirst(b'accept-types')
        if remote_accept_types is None:
            raise InvalidStreamError("remote SDP media does not have 'accept-types' attribute")
        if not any(contains_mime_type(cls.accept_types, mime_type) for mime_type in remote_accept_types.decode().split()):
            raise InvalidStreamError("no compatible media types found")
        return stream

    @property
    def local_identity(self):
        try:
            return ChatIdentity(self.session.local_identity.uri, self.session.local_identity.display_name)
        except AttributeError:
            return None

    @property
    def remote_identity(self):
        try:
            return ChatIdentity(self.session.remote_identity.uri, self.session.remote_identity.display_name)
        except AttributeError:
            return None

    @property
    def private_messages_allowed(self):
        return 'private-messages' in self.chatroom_capabilities

    @property
    def nickname_allowed(self):
        return 'nickname' in self.chatroom_capabilities

    @property
    def chatroom_capabilities(self):
        try:
            if self.cpim_enabled and self.session.remote_focus:
                chatroom = self.remote_media.attributes.getfirst(b'chatroom')
                chatroom_caps = chatroom.decode().split() if chatroom else []
                return chatroom_caps
        except AttributeError:
            pass
        return []

    def _NH_MediaStreamDidStart(self, notification):
        self.message_queue_thread = spawn(self._message_queue_handler)

    def _NH_MediaStreamDidNotInitialize(self, notification):
        message_queue, self.message_queue = self.message_queue, queue()
        while message_queue:
            message = message_queue.wait()
            if message.notify_progress:
                data = NotificationData(message_id=message.id, message=None, code=0, reason='Stream was closed')
                notification.center.post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)

    def _NH_MediaStreamDidEnd(self, notification):
        if self.message_queue_thread is not None:
            self.message_queue_thread.kill()
        else:
            message_queue, self.message_queue = self.message_queue, queue()
            while message_queue:
                message = message_queue.wait()
                if message.notify_progress:
                    data = NotificationData(message_id=message.id, message=None, code=0, reason='Stream ended')
                    notification.center.post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)

    def _handle_REPORT(self, chunk):
        # in theory, REPORT can come with Byte-Range which would limit the scope of the REPORT to the part of the message.
        if chunk.message_id in self.sent_messages:
            self.sent_messages.remove(chunk.message_id)
            notification_center = NotificationCenter()
            data = NotificationData(message_id=chunk.message_id, message=chunk, code=chunk.status.code, reason=chunk.status.comment)
            if chunk.status.code == 200:
                notification_center.post_notification('ChatStreamDidDeliverMessage', sender=self, data=data)
            else:
                notification_center.post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)

    def _handle_SEND(self, chunk):
        if chunk.size == 0:  # keep-alive
            self.msrp_session.send_report(chunk, 200, 'OK')
            return
        content_type = chunk.content_type.lower()
        if not contains_mime_type(self.accept_types, content_type):
            self.msrp_session.send_report(chunk, 413, 'Unwanted Message')
            return
        if chunk.contflag == '#':
            self.incoming_queue.pop(chunk.message_id, None)
            self.msrp_session.send_report(chunk, 200, 'OK')
            return
        elif chunk.contflag == '+':
            self.incoming_queue[chunk.message_id].append(chunk.data)
            self.msrp_session.send_report(chunk, 200, 'OK')
            return
        else:
            data = ''.join(self.incoming_queue.pop(chunk.message_id, [])) + chunk.data.decode()
            
        if content_type == 'message/cpim':
            try:
                payload = CPIMPayload.decode(data)
            except CPIMParserError:
                self.msrp_session.send_report(chunk, 400, 'CPIM Parser Error')
                return
            else:
                message = Message(**{name: getattr(payload, name) for name in Message.__slots__})
                if not contains_mime_type(self.accept_wrapped_types, message.content_type):
                    self.msrp_session.send_report(chunk, 413, 'Unwanted Message')
                    return
                if message.timestamp is None:
                    message.timestamp = ISOTimestamp.now()
                if message.sender is None:
                    message.sender = self.remote_identity

                private = self.session.remote_focus and len(message.recipients) == 1 and message.recipients[0] != self.remote_identity
        else:
            payload = SimplePayload.decode(data, content_type)
            message = Message(payload.content, payload.content_type, sender=self.remote_identity, recipients=[self.local_identity], timestamp=ISOTimestamp.now())
            private = False

        if IgnoreMessage:
            try:
                content = message.content if isinstance(message.content, bytes) else message.content.encode()
                message.content = self.encryption.otr_session.handle_input(content, message.content_type)
            except IgnoreMessage:
                self.msrp_session.send_report(chunk, 200, 'OK')
                return
            except UnencryptedMessage:
                encrypted = False
                encryption_active = True
            except EncryptedMessageError as e:
                self.msrp_session.send_report(chunk, 400, str(e))
                notification_center = NotificationCenter()
                notification_center.post_notification('ChatStreamOTRError', sender=self, data=NotificationData(error=str(e)))
                return
            except OTRError as e:
                self.msrp_session.send_report(chunk, 200, 'OK')
                notification_center = NotificationCenter()
                notification_center.post_notification('ChatStreamOTRError', sender=self, data=NotificationData(error=str(e)))
                return
            else:
                encrypted = encryption_active = self.encryption.active

        if payload.charset is not None:
            message.content = message.content.decode(payload.charset)
        elif payload.content_type.startswith('text/'):
            message.content = message.content.decode('utf8')

        notification_center = NotificationCenter()
        if message.content_type.lower() == IsComposingDocument.content_type:
            try:
                document = IsComposingDocument.parse(message.content)
            except (ParserError, OSError) as e:
                self.msrp_session.send_report(chunk, 400, str(e))
                return
            self.msrp_session.send_report(chunk, 200, 'OK')
            data = NotificationData(state=document.state.value,
                                    refresh=document.refresh.value if document.refresh is not None else 120,
                                    content_type=document.content_type.value if document.content_type is not None else None,
                                    last_active=document.last_active.value if document.last_active is not None else None,
                                    sender=message.sender, recipients=message.recipients, private=private,
                                    encrypted=encrypted, encryption_active=encryption_active)
            notification_center.post_notification('ChatStreamGotComposingIndication', sender=self, data=data)
        else:
            self.msrp_session.send_report(chunk, 200, 'OK')
            data = NotificationData(message=message, private=private, encrypted=encrypted, encryption_active=encryption_active)
            notification_center.post_notification('ChatStreamGotMessage', sender=self, data=data)

    def _on_transaction_response(self, message_id, response):
        if message_id in self.sent_messages and response.code != 200:
            self.sent_messages.remove(message_id)
            data = NotificationData(message_id=message_id, message=response, code=response.code, reason=response.comment)
            NotificationCenter().post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)

    def _on_nickname_transaction_response(self, message_id, response):
        notification_center = NotificationCenter()
        if response.code == 200:
            notification_center.post_notification('ChatStreamDidSetNickname', sender=self, data=NotificationData(message_id=message_id, response=response))
        else:
            notification_center.post_notification('ChatStreamDidNotSetNickname', sender=self, data=NotificationData(message_id=message_id, message=response, code=response.code, reason=response.comment))

    def _message_queue_handler(self):
        notification_center = NotificationCenter()
        try:
            while True:
                message = self.message_queue.wait()
                if self.msrp_session is None:
                    if message.notify_progress:
                        data = NotificationData(message_id=message.id, message=None, code=0, reason='Stream ended')
                        notification_center.post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)
                    break

                try:
                    if isinstance(message.content, str):
                        message.content = message.content.encode('utf8')
                        charset = 'utf8'
                    else:
                        charset = None

                    if not isinstance(message, QueuedOTRInternalMessage):
                        try:
                            message.content = self.encryption.otr_session.handle_output(message.content, message.content_type)
                        except OTRError as e:
                            raise ChatStreamError(str(e))

                    message.sender = message.sender or self.local_identity
                    message.recipients = message.recipients or [self.remote_identity]

                    # check if we MUST use CPIM
                    need_cpim = (message.sender != self.local_identity or message.recipients != [self.remote_identity] or
                                 message.courtesy_recipients or message.subject or message.timestamp or message.required or message.additional_headers)

                    if need_cpim or not contains_mime_type(self.remote_accept_types, message.content_type):
                        if not contains_mime_type(self.remote_accept_wrapped_types, message.content_type):
                            raise ChatStreamError('Unsupported content_type for outgoing message: %r' % message.content_type)
                        if not self.cpim_enabled:
                            raise ChatStreamError('Additional message meta-data cannot be sent, because the CPIM wrapper is not used')
                        if not self.private_messages_allowed and message.recipients != [self.remote_identity]:
                            raise ChatStreamError('The remote end does not support private messages')
                        if message.timestamp is None:
                            message.timestamp = ISOTimestamp.now()
                        payload = CPIMPayload(charset=charset, **{name: getattr(message, name) for name in Message.__slots__})
                    elif self.prefer_cpim and self.cpim_enabled and contains_mime_type(self.remote_accept_wrapped_types, message.content_type):
                        if message.timestamp is None:
                            message.timestamp = ISOTimestamp.now()
                        payload = CPIMPayload(charset=charset, **{name: getattr(message, name) for name in Message.__slots__})
                    else:
                        payload = SimplePayload(message.content, message.content_type, charset)
                except ChatStreamError as e:
                    if message.notify_progress:
                        data = NotificationData(message_id=message.id, message=None, code=0, reason=e.args[0])
                        notification_center.post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)
                    continue
                else:
                    content, content_type = payload.encode()

                message_id = message.id
                notify_progress = message.notify_progress
                report = 'yes' if notify_progress else 'no'

                chunk = self.msrp_session.make_message(content, content_type=content_type, message_id=message_id)
                chunk.add_header(FailureReportHeader(report))
                chunk.add_header(SuccessReportHeader(report))

                try:
                    self.msrp_session.send_chunk(chunk, response_cb=partial(self._on_transaction_response, message_id))
                except Exception as e:
                    if notify_progress:
                        data = NotificationData(message_id=message_id, message=None, code=0, reason=str(e))
                        notification_center.post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)
                except ProcExit:
                    if notify_progress:
                        data = NotificationData(message_id=message_id, message=None, code=0, reason='Stream ended')
                        notification_center.post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)
                    raise
                else:
                    if notify_progress:
                        self.sent_messages.add(message_id)
                        notification_center.post_notification('ChatStreamDidSendMessage', sender=self, data=NotificationData(message=chunk))
        finally:
            self.message_queue_thread = None
            while self.sent_messages:
                message_id = self.sent_messages.pop()
                data = NotificationData(message_id=message_id, message=None, code=0, reason='Stream ended')
                notification_center.post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)
            message_queue, self.message_queue = self.message_queue, queue()
            while message_queue:
                message = message_queue.wait()
                if message.notify_progress:
                    data = NotificationData(message_id=message.id, message=None, code=0, reason='Stream ended')
                    notification_center.post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)

    @run_in_twisted_thread
    def _enqueue_message(self, message):
        if self._done:
            if message.notify_progress:
                data = NotificationData(message_id=message.id, message=None, code=0, reason='Stream ended')
                NotificationCenter().post_notification('ChatStreamDidNotDeliverMessage', sender=self, data=data)
        else:
            self.message_queue.send(message)

    @run_in_green_thread
    def _set_local_nickname(self, nickname, message_id):
        if self.msrp_session is None:
            # should we generate ChatStreamDidNotSetNickname here?
            return
        chunk = self.msrp.make_request('NICKNAME')
        chunk.add_header(UseNicknameHeader(nickname or ''))
        try:
            self.msrp_session.send_chunk(chunk, response_cb=partial(self._on_nickname_transaction_response, message_id))
        except Exception as e:
            self._failure_reason = str(e)
            NotificationCenter().post_notification('MediaStreamDidFail', sender=self, data=NotificationData(context='sending', reason=self._failure_reason))

    def inject_otr_message(self, data):
        message = QueuedOTRInternalMessage(data)
        self._enqueue_message(message)

    def send_message(self, content, content_type='text/plain', recipients=None, courtesy_recipients=None, subject=None, timestamp=None, required=None, additional_headers=None):
        message = QueuedMessage(content, content_type, recipients=recipients, courtesy_recipients=courtesy_recipients, subject=subject, timestamp=timestamp, required=required, additional_headers=additional_headers, notify_progress=True)
        self._enqueue_message(message)
        return message.id

    def send_composing_indication(self, state, refresh=None, last_active=None, recipients=None):
        content = IsComposingDocument.create(state=State(state), refresh=Refresh(refresh) if refresh is not None else None, last_active=LastActive(last_active) if last_active is not None else None, content_type=ContentType('text'))
        message = QueuedMessage(content, IsComposingDocument.content_type, recipients=recipients, notify_progress=False)
        self._enqueue_message(message)
        return message.id

    def set_local_nickname(self, nickname):
        if not self.nickname_allowed:
            raise ChatStreamError('Setting nickname is not supported')
        message_id = '%x' % random.getrandbits(64)
        self._set_local_nickname(nickname, message_id)
        return message_id


try:
    OTRTransport.register(ChatStream)
except NameError:
    pass


# Chat related objects, including CPIM support as defined in RFC3862
#

class ChatIdentity(object):
    _format_re = re.compile(r'^(?:"?(?P<display_name>[^<]*[^"\s])"?)?\s*<(?P<uri>sips?:.+)>$')

    def __init__(self, uri, display_name=None):
        self.uri = uri
        self.display_name = display_name

    def __eq__(self, other):
        if isinstance(other, ChatIdentity):
            left_user = self.uri.user.decode() if isinstance(self.uri.user, bytes) else self.uri.user
            right_user = other.uri.user.decode() if isinstance(other.uri.user, bytes) else other.uri.user
            left_host = self.uri.host.decode() if isinstance(self.uri.host, bytes) else self.uri.host
            right_host = other.uri.host.decode() if isinstance(other.uri.host, bytes) else other.uri.host
            return left_user == right_user and left_host == right_host
        elif isinstance(other, BaseSIPURI):
            left_user = self.uri.user.decode() if isinstance(self.uri.user, bytes) else self.uri.user
            right_user = other.user.decode() if isinstance(other.user, bytes) else other.user
            left_host = self.uri.host.decode() if isinstance(self.uri.host, bytes) else self.uri.host
            right_host = other.host.decode() if isinstance(other.host, bytes) else other.host
            return left_user == right_user and left_host == right_host
        elif isinstance(other, str):
            try:
                other_uri = SIPURI.parse(other)
            except Exception:
                return False
            else:
                return self.uri.user == other_uri.user and self.uri.host == other_uri.host
        else:
            return NotImplemented

    def __ne__(self, other):
        return not (self == other)

    def __repr__(self):
        return '{0.__class__.__name__}(uri={0.uri!r}, display_name={0.display_name!r})'.format(self)

    def __str__(self):
        if self.display_name:
            return '{0.display_name} <{0.uri}>'.format(self)
        else:
            return '<{0.uri}>'.format(self)

    @classmethod
    def parse(cls, value):
        value = value.decode() if isinstance(value, bytes) else value
        
        match = cls._format_re.match(value)
        if match is None:
            raise ValueError('Cannot parse identity value: %r' % value)
        return cls(SIPURI.parse(match.group('uri')), match.group('display_name'))


class Message(object):
    __slots__ = 'content', 'content_type', 'sender', 'recipients', 'courtesy_recipients', 'subject', 'timestamp', 'required', 'additional_headers'

    def __init__(self, content, content_type, sender=None, recipients=None, courtesy_recipients=None, subject=None, timestamp=None, required=None, additional_headers=None):
        self.content = content
        self.content_type = content_type
        self.sender = sender
        self.recipients = recipients or []
        self.courtesy_recipients = courtesy_recipients or []
        self.subject = subject
        self.timestamp = ISOTimestamp(timestamp) if timestamp is not None else None
        self.required = required or []
        self.additional_headers = additional_headers or []


class QueuedMessage(Message):
    __slots__ = 'id', 'notify_progress'

    def __init__(self, content, content_type, sender=None, recipients=None, courtesy_recipients=None, subject=None, timestamp=None, required=None, additional_headers=None, id=None, notify_progress=True):
        super(QueuedMessage, self).__init__(content, content_type, sender, recipients, courtesy_recipients, subject, timestamp, required, additional_headers)
        self.id = id or '%x' % random.getrandbits(64)
        self.notify_progress = notify_progress


class QueuedOTRInternalMessage(QueuedMessage):
    def __init__(self, content):
        super(QueuedOTRInternalMessage, self).__init__(content, 'text/plain', notify_progress=False)


class SimplePayload(object):
    def __init__(self, content, content_type, charset=None):
        if not isinstance(content, bytes):
            raise TypeError("content should be an instance of bytes")
        self.content = content
        self.content_type = content_type
        self.charset = charset

    def encode(self):
        if self.charset is not None:
            return self.content, '{0.content_type}; charset="{0.charset}"'.format(self)
        else:
            return self.content, str(self.content_type)

    @classmethod
    def decode(cls, content, content_type):
        if not isinstance(content, bytes) and not isinstance(content, str):
            raise TypeError("content should be an instance of bytes or string")
        type_helper = EmailParser().parsestr('Content-Type: {}'.format(content_type))
        content_type = type_helper.get_content_type()
        charset = type_helper.get_content_charset()
        if isinstance(content, str):
            content = content.encode(charset if charset else "ascii", "replace")
        return cls(content, content_type, charset)


class CPIMPayload(object):
    standard_namespace = 'urn:ietf:params:cpim-headers:'

    headers_re = re.compile(r'(?:([^:]+?)\.)?(.+?):\s*(.+?)(?:\r\n|$)')
    subject_re = re.compile(r'^(?:;lang=([a-z]{1,8}(?:-[a-z0-9]{1,8})*)\s+)?(.*)$')
    namespace_re = re.compile(r'^(?:(\S+) ?)?<(.*)>$')

    def __init__(self, content, content_type, charset=None, sender=None, recipients=None, courtesy_recipients=None, subject=None, timestamp=None, required=None, additional_headers=None):
        self.content = content
        self.content_type = content_type
        self.charset = charset
        self.sender = sender
        self.recipients = recipients or []
        self.courtesy_recipients = courtesy_recipients or []
        self.subject = subject if isinstance(subject, (MultilingualText, type(None))) else MultilingualText(subject)
        self.timestamp = ISOTimestamp(timestamp) if timestamp is not None else None
        self.required = required or []
        self.additional_headers = additional_headers or []

    def encode(self):
        namespaces = {'': CPIMNamespace(self.standard_namespace)}
        header_list = []

        if self.sender is not None:
            header_list.append('From: {}'.format(self.sender))
        header_list.extend('To: {}'.format(recipient) for recipient in self.recipients)
        header_list.extend('cc: {}'.format(recipient) for recipient in self.courtesy_recipients)
        if self.subject is not None:
            header_list.append('Subject: {}'.format(self.subject))
            header_list.extend('Subject:;lang={} {}'.format(language, translation) for language, translation in list(self.subject.translations.items()))
        if self.timestamp is not None:
            header_list.append('DateTime: {}'.format(self.timestamp))
        if self.required:
            header_list.append('Required: {}'.format(','.join(self.required)))

        for header in self.additional_headers:
            if namespaces.get(header.namespace.prefix) != header.namespace:
                if header.namespace.prefix:
                    header_list.append('NS: {0.namespace.prefix} <{0.namespace}>'.format(header))
                else:
                    header_list.append('NS: <{0.namespace}>'.format(header))
                namespaces[header.namespace.prefix] = header.namespace
            if header.namespace.prefix:
                header_list.append('{0.namespace.prefix}.{0.name}: {0.value}'.format(header))
            else:
                header_list.append('{0.name}: {0.value}'.format(header))

        headers = '\r\n'.join(header_list)

        mime_message = ChatMimeMessage()
        mime_message.set_payload(self.content)
        mime_message.set_type(self.content_type)

        if self.charset is not None:
            mime_message.set_param('charset', self.charset)

        return headers + '\r\n\r\n' + mime_message.as_string(), 'message/cpim'

    @classmethod
    def decode(cls, message):
        message = message.decode() if isinstance(message, bytes) else message
        headers, separator, body = message.partition('\r\n\r\n')
        if not separator:
            raise CPIMParserError('Invalid CPIM message')

        sender = None
        recipients = []
        courtesy_recipients = []
        subject = None
        timestamp = None
        required = []
        additional_headers = []

        namespaces = {'': CPIMNamespace(cls.standard_namespace)}
        subjects = {}

        for prefix, name, value in cls.headers_re.findall(headers):
            namespace = namespaces.get(prefix)

            if namespace is None or '.' in name:
                continue

            try:
                #value = value.decode('cpim-header')
                if namespace == cls.standard_namespace:
                    if name == 'From':
                        sender = ChatIdentity.parse(value)
                    elif name == 'To':
                        to = ChatIdentity.parse(value);
                        recipients.append(to)
                    elif name == 'cc':
                        courtesy_recipients.append(ChatIdentity.parse(value))
                    elif name == 'Subject':
                        match = cls.subject_re.match(value)
                        if match is None:
                            raise ValueError('Illegal Subject header: %r' % value)
                        lang, subject = match.groups()
                        # language tags must be ASCII
                        subjects[str(lang) if lang is not None else None] = subject
                    elif name == 'DateTime':
                        timestamp = ISOTimestamp(value)
                    elif name == 'Required':
                        required.extend(re.split(r'\s*,\s*', value))
                    elif name == 'NS':
                        match = cls.namespace_re.match(value)
                        if match is None:
                            raise ValueError('Illegal NS header: %r' % value)
                        prefix, uri = match.groups()
                        namespaces[prefix] = CPIMNamespace(uri, prefix)
                    else:
                        additional_headers.append(CPIMHeader(name, namespace, value))
                else:
                    additional_headers.append(CPIMHeader(name, namespace, value))
            except ValueError:
                pass

        if None in subjects:
            subject = MultilingualText(subjects.pop(None), **subjects)
        elif subjects:
            subject = MultilingualText(**subjects)

        mime_message = EmailParser().parsestr(body)
        content_type = mime_message.get_content_type()
        
        if content_type is None:
            raise CPIMParserError("CPIM message missing Content-Type MIME header")
        content = mime_message.get_payload()
        # If the content_type is 'message/imdn+xml' the parser thinks it is a multipart message, hence the result of get_payload
        # will be a list. Since it is not actually a list we take first item in the list and get the payload again
        # --Tijmen
        if content_type == 'message/imdn+xml':
            content = content[0].get_payload()
        charset = mime_message.get_content_charset()

        return cls(content.encode(), content_type, charset, sender, recipients, courtesy_recipients, subject, timestamp, required, additional_headers)


class CPIMParserError(Exception): pass


class CPIMNamespace(str):
    def __new__(cls, value, prefix=''):
        obj = str.__new__(cls, value)
        obj.prefix = prefix
        return obj


class CPIMHeader(object):
    def __init__(self, name, namespace, value):
        self.name = name
        self.namespace = namespace
        self.value = value


class CPIMCodec(codecs.Codec):
    character_map = {c: '\\u{:04x}'.format(c) for c in list(range(32)) + [127]}
    character_map[ord('\\')] = '\\\\'

    @classmethod
    def encode(cls, input, errors='strict'):
        return input.translate(cls.character_map).encode('utf-8', errors), len(input)

    @classmethod
    def decode(cls, input, errors='strict'):
        return input.decode('utf-8', errors).encode('raw-unicode-escape', errors).decode('unicode-escape', errors), len(input)


def cpim_codec_search(name):
    if name.lower() in ('cpim-header', 'cpim_header'):
        return codecs.CodecInfo(name='CPIM-header',
                                encode=CPIMCodec.encode,
                                decode=CPIMCodec.decode,
                                incrementalencoder=codecs.IncrementalEncoder,
                                incrementaldecoder=codecs.IncrementalDecoder,
                                streamwriter=codecs.StreamWriter,
                                streamreader=codecs.StreamReader)
codecs.register(cpim_codec_search)
del cpim_codec_search


