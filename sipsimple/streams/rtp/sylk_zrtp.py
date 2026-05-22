"""
Sylk-flavoured ZRTP-over-in-dialog-SIP-MESSAGE end-to-end encryption.

This is NOT RFC 6189 ZRTP. It's an X25519+HKDF DH ladder driven over SIP
MESSAGE bodies tagged with Content-Type: application/sylk-zrtp-negotiation,
producing AES-128-GCM keys that the PJMEDIA AEAD transport adapter
applies on top of SRTP/SDES. The protocol mirrors sylk-mobile's
app/components/CallZrtp.js byte-for-byte.

The SDK runs the negotiation AUTOMATICALLY, with no application-level
plumbing required. An application gets E2E ZRTP just by:

  * configuring account.rtp.encryption.key_negotiation to 'opportunistic'
    or 'zrtp' (this enables the AEAD adapter on every stream's RTP
    transport, in passthrough until keys arrive); and
  * observing the SIPSessionSylkZRTPStateChanged notification if it
    wants to surface the SAS / pill in UI.

**Coexistence with RFC 6189 ZRTP.** The SDK already speaks the standard
SDP-signalled ZRTP (a=zrtp-hash) via pjmedia_transport_zrtp. When BOTH
ends offer real ZRTP (e.g. Blink ↔ Blink, Blink ↔ Zoiper), the SDP
negotiation produces stream.encryption.type == 'ZRTP' and real ZRTP
takes over the media-layer key exchange. In that case Sylk-ZRTP-over-
MESSAGE MUST NOT also run — two parallel ZRTP handshakes is wrong.

The trigger condition in Session._NH_RTPStreamDidEnableEncryption is
therefore:

    stream.encryption.type == 'SRTP/SDES'    # i.e. RFC ZRTP did NOT win

If real ZRTP won, stream.encryption.type is 'ZRTP' and the
SylkZRTPSession is never instantiated, regardless of whether the peer
advertised X-Sylk-ZRTP in headers. The X-Sylk-ZRTP header is therefore
purely an "I'm capable" advertisement; the actual decision to use it
is gated on the SDP-level outcome. This makes the fallback transparent
for the Blink-to-Sylk-Mobile case (Mobile doesn't speak real ZRTP →
SDES wins → Sylk-ZRTP kicks in) while keeping Blink-to-Blink clean
(real ZRTP wins → Sylk-ZRTP stays out of the way).

Behaviour by call direction:

  Outgoing call:
    - Session.connect adds 'X-Sylk-ZRTP: v=1; suites=AES-128-GCM' to
      the INVITE extra_headers when the account is so configured.
    - Session._NH_SIPInvitationChangedState parses the 200 OK headers
      and sets session.remote_sylk_zrtp_capability if the peer also
      advertised it.
    - Session._NH_RTPStreamDidEnableEncryption (when audio's SDES
      becomes active) creates a SylkZRTPSession in caller role and
      calls start_probe() — but ONLY if encryption.type == 'SRTP/SDES'
      (real ZRTP didn't win the SDP negotiation).

  Incoming call:
    - Session.init_incoming parses the INVITE headers, sets
      session.remote_sylk_zrtp_capability if peer advertised support.
    - Session.accept adds the same header to the 200 OK if the local
      account also supports it.
    - Session._NH_SIPInvitationGotMessage intercepts any in-dialog
      MESSAGE with Content-Type application/sylk-zrtp-negotiation:
        - If stream.encryption.type == 'ZRTP' on the audio stream
          (i.e. real RFC ZRTP took over), the message is dropped
          silently — we never engage Sylk-ZRTP under those conditions.
        - Otherwise the first such message creates a SylkZRTPSession
          in callee role and subsequent messages dispatch to it.
      These messages are CONSUMED by the SDK — they are NOT re-posted
      as SIPSessionGotMessage to the application, so apps don't see
      ZRTP-protocol noise on their generic in-dialog-MESSAGE handler.

  Handshake completion:
    - SylkZRTPSession derives per-direction AES-128-GCM keys + an SAS
      via HKDF-SHA256, then installs the keys on each stream's
      RTPTransport via stream.set_aead_keys(...).
    - H.264 video is skipped (STAP-A multi-NAL aggregation is
      incompatible with our fixed-prefix scheme — see comments in
      sip-session3 ZrtpSession). Audio is always installed.
    - A SIPSessionSylkZRTPStateChanged notification is posted on every
      state transition (probing → key-agreed → key-active → failed).

The application sees only:
    NotificationData(state, sas, suite, peer_verified, error)
…and only if it subscribes. Apps that don't care see nothing.
"""

import hashlib
import json
import os
import sqlite3
import threading
import time
import uuid
from collections import namedtuple

from application import log
from application.notification import NotificationCenter, NotificationData

try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes
    _CRYPTO_AVAILABLE = True
except ImportError:
    _CRYPTO_AVAILABLE = False


# --- Wire constants --------------------------------------------------------

# Highest wire version we speak. v1 = original protocol (no continuity).
# v2 adds an rs_id field to probe/accept payloads carrying the SHA-256 prefix
# of a retained per-peer secret (RFC 6189-style continuity). v1 peers stay
# interoperable — when either side advertises v=1 we fall back to the v1
# derivation (no rs1 mix), and we don't try to read or store rs1.
SYLK_ZRTP_VERSION = 2
SYLK_ZRTP_CONTENT_TYPE = 'application/sylk-zrtp-negotiation'
SYLK_ZRTP_SUITES = ('AES-128-GCM',)   # only this for now; comma-list when adding more

# Length of rs_id (the hex-encoded SHA-256 prefix of rs1). 16 hex chars = 8
# bytes. Long enough that random collisions are negligible; short enough to
# keep the on-wire payload compact.
SYLK_ZRTP_RS_ID_HEX_LEN = 16

# SIP header that advertises support. Format documented in the module
# docstring; both Sylk Mobile (CallZrtp.js) and Blink/sip-session3 use
# the same name + value grammar.
SYLK_ZRTP_CAPABILITY_HEADER_NAME = 'X-Sylk-ZRTP'
SYLK_ZRTP_CAPABILITY_HEADER_VALUE = 'v=%d; suites=%s' % (
    SYLK_ZRTP_VERSION, ','.join(SYLK_ZRTP_SUITES))

# 32-symbol SAS alphabets — byte-for-byte identical to sylk-mobile's
# CallZrtp.js so the displayed SAS matches across stacks.
_SAS_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'  # RFC 4648 base32
_SAS_EMOJIS = [
    '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼',
    '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🦄',
    '🐔', '🐧', '🦅', '🦉', '🐺', '🐴', '🦓', '🦒',
    '🐘', '🦏', '🐊', '🐢', '🐳', '🦈', '🐙', '🦋',
]


# --- Capability detection / advertisement helpers --------------------------

Capability = namedtuple('Capability', ('version', 'suites'))


def parse_capability_value(value):
    """Parse 'v=1; suites=AES-128-GCM,…' into Capability or None.

    Tolerant of extra whitespace and unknown params — only 'v' and
    'suites' are read so future params can be added without breaking
    older parsers.
    """
    if not value:
        return None
    version = None
    suites = []
    for part in str(value).split(';'):
        part = part.strip()
        if not part or '=' not in part:
            continue
        name, _, val = part.partition('=')
        name = name.strip().lower()
        val = val.strip()
        if name == 'v':
            try:
                version = int(val)
            except ValueError:
                pass
        elif name == 'suites':
            suites = [s.strip() for s in val.split(',') if s.strip()]
    if version is None or version < 1 or version > SYLK_ZRTP_VERSION:
        return None
    return Capability(version, suites)


def peer_capability_from_headers(headers):
    """Inspect a headers dict (notification.data.headers shape) for
    X-Sylk-ZRTP. Returns Capability or None.
    """
    if not headers:
        return None
    hdr = headers.get(SYLK_ZRTP_CAPABILITY_HEADER_NAME)
    if hdr is None:
        return None
    # Frozen header types expose .body; tuple/str just stringifies.
    value = getattr(hdr, 'body', None) or getattr(hdr, 'value', None) or str(hdr)
    return parse_capability_value(value)


def account_advertises_capability(account):
    """True if the account's RTP encryption is configured for a
    negotiation that Sylk-ZRTP layers on top of (opportunistic / zrtp).
    Used by Session.connect / Session.accept to decide whether to add
    the X-Sylk-ZRTP header to outgoing INVITE / 200 OK.
    """
    if account is None:
        return False
    rtp_enc = getattr(getattr(account, 'rtp', None), 'encryption', None)
    if rtp_enc is None or not getattr(rtp_enc, 'enabled', False):
        return False
    return rtp_enc.key_negotiation in ('opportunistic', 'zrtp')


def capability_header_for_account(account):
    """Returns the Header object to add to extra_headers when the
    account advertises capability, else None. Imports inside the
    function to avoid a circular dependency with sipsimple.core.
    """
    if not account_advertises_capability(account):
        return None
    from sipsimple.core import Header
    return Header(SYLK_ZRTP_CAPABILITY_HEADER_NAME, SYLK_ZRTP_CAPABILITY_HEADER_VALUE)


# --- HKDF helper -----------------------------------------------------------

def _hkdf(ikm, salt, info, length):
    """HKDF-SHA256 wrapper — labels and salt-zero convention are the
    same as sylk-mobile's _hkdf so derived keys match byte-for-byte."""
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt,
                info=info.encode('utf-8')).derive(ikm)


# --- Retained-secret continuity store --------------------------------------
#
# Per-peer 32-byte secret persisted across calls so a MitM on call N who
# completes the X25519 exchange but doesn't hold the stored rs1 produces
# keys that disagree with the legitimate peer's. The HKDF salt becomes
# rs1 (instead of 32 zero bytes) when both ends prove they hold the same
# secret via rs_id (SHA-256(rs1) prefix exchanged in the probe / accept).
#
# Storage lives inside the same SQLite file libzrtpcpp opens for its
# RFC 6189 ZID cache (engine.zrtp_cache). We add a sylk_zrtp_secrets
# table whose name doesn't collide with anything libzrtpcpp creates.
#
# rs1 is seeded only after explicit user SAS verification on the first
# call (app calls confirm_sas_and_seed_rs1 on the session). On subsequent
# continuity-verified calls rs1 is rotated automatically on key-active.

_RS_LEN = 32  # bytes


class SylkZrtpSecretStore(object):
    """SQLite-backed map: peer_aor -> (rs1, rotated_at).

    One module-level instance, lazily opened on first use. Thread-safe via
    a single lock around the connection so the per-call threads can hammer
    it concurrently. The DB file path is taken from
    sipsimple.application.SIPApplication().engine.zrtp_cache — same file
    libzrtpcpp uses for its RFC 6189 ZID cache. Separate table, no schema
    overlap.
    """

    _SCHEMA = (
        "CREATE TABLE IF NOT EXISTS sylk_zrtp_secrets ("
        "  peer_aor TEXT PRIMARY KEY,"
        "  rs1 BLOB NOT NULL,"
        "  rotated_at INTEGER NOT NULL"
        ")"
    )

    def __init__(self):
        self._lock = threading.Lock()
        self._conn = None

    def _ensure_open(self):
        if self._conn is not None:
            return self._conn
        try:
            from sipsimple.application import SIPApplication
            engine = SIPApplication().engine
            path = engine.zrtp_cache
            if isinstance(path, bytes):
                path = path.decode('utf-8', errors='replace')
        except Exception as e:
            log.warning('[sylk-zrtp] secret store: cannot resolve zrtp_cache path: %s' % e)
            return None
        if not path:
            log.warning('[sylk-zrtp] secret store: empty zrtp_cache path')
            return None
        try:
            d = os.path.dirname(path)
            if d and not os.path.exists(d):
                os.makedirs(d)
            self._conn = sqlite3.connect(path, check_same_thread=False)
            self._conn.execute(self._SCHEMA)
            self._conn.commit()
        except Exception as e:
            log.warning('[sylk-zrtp] secret store: cannot open %s: %s' % (path, e))
            self._conn = None
        return self._conn

    def get(self, peer_aor):
        """Return the stored 32-byte rs1 for peer_aor, or None."""
        if not peer_aor:
            return None
        with self._lock:
            conn = self._ensure_open()
            if conn is None:
                return None
            try:
                row = conn.execute(
                    "SELECT rs1 FROM sylk_zrtp_secrets WHERE peer_aor = ?",
                    (peer_aor,)).fetchone()
            except Exception as e:
                log.warning('[sylk-zrtp] secret store get(%s) failed: %s' % (peer_aor, e))
                return None
        if row is None:
            return None
        rs1 = row[0]
        if isinstance(rs1, (bytes, bytearray)) and len(rs1) == _RS_LEN:
            return bytes(rs1)
        return None

    def put(self, peer_aor, rs1):
        """Store/replace rs1 for peer_aor. rs1 must be exactly 32 bytes."""
        if not peer_aor or not isinstance(rs1, (bytes, bytearray)) or len(rs1) != _RS_LEN:
            return False
        with self._lock:
            conn = self._ensure_open()
            if conn is None:
                return False
            try:
                conn.execute(
                    "INSERT OR REPLACE INTO sylk_zrtp_secrets "
                    "(peer_aor, rs1, rotated_at) VALUES (?, ?, ?)",
                    (peer_aor, bytes(rs1), int(time.time())))
                conn.commit()
                return True
            except Exception as e:
                log.warning('[sylk-zrtp] secret store put(%s) failed: %s' % (peer_aor, e))
                return False

    def delete(self, peer_aor):
        """Forget the stored rs1 for peer_aor (e.g. user chose Continue past
        a mismatch alarm, or explicitly cleared the binding)."""
        if not peer_aor:
            return False
        with self._lock:
            conn = self._ensure_open()
            if conn is None:
                return False
            try:
                conn.execute(
                    "DELETE FROM sylk_zrtp_secrets WHERE peer_aor = ?",
                    (peer_aor,))
                conn.commit()
                return True
            except Exception as e:
                log.warning('[sylk-zrtp] secret store delete(%s) failed: %s' % (peer_aor, e))
                return False


_secret_store = SylkZrtpSecretStore()


def _rs_id_hex(rs1):
    """rs_id = first 8 bytes of SHA-256(rs1), hex-encoded. 16 hex chars."""
    if not isinstance(rs1, (bytes, bytearray)) or len(rs1) != _RS_LEN:
        return None
    return hashlib.sha256(bytes(rs1)).digest()[:8].hex()


def _peer_aor_from_session(session):
    """Best-effort canonical 'user@host' string for storage keying."""
    try:
        rid = getattr(session, 'remote_identity', None)
        uri = getattr(rid, 'uri', None) if rid is not None else None
        if uri is None:
            return None
        user = getattr(uri, 'user', None)
        host = getattr(uri, 'host', None)
        if user and host:
            if isinstance(user, bytes):
                user = user.decode('utf-8', errors='replace')
            if isinstance(host, bytes):
                host = host.decode('utf-8', errors='replace')
            return '%s@%s' % (user, host)
        return str(uri)
    except Exception:
        return None


# --- Per-codec unencrypted prefix -----------------------------------------

def _video_prefix_for_codec(codec):
    """Bytes left UNENCRYPTED at the start of each RTP payload —
    mirrors CallZrtp.unencryptedVideoPrefixForCodec on sylk-mobile.
    Audio = 0. Video VP8/VP9 = 3, H264 = 2, AV1 = 1. Conservative
    default for unknown video codecs = 3."""
    if not codec:
        return 0
    c = codec.upper()
    if c in ('VP8', 'VP9'):
        return 3
    if c == 'H264':
        return 2
    if c == 'AV1':
        return 1
    return 3


def _should_skip_video_for_codec(codec):
    """H264's STAP-A multi-NAL packetizer is incompatible with our
    fixed-prefix encryption — skip the video install when H264 is the
    negotiated codec. Audio is unaffected. Same rule as sylk-mobile."""
    return (codec or '').upper() == 'H264'


# --- Notification posting helper ------------------------------------------

def _post_state(session, **kw):
    """Post SIPSessionSylkZRTPStateChanged on the session.

    kw must include 'state' and may include 'sas', 'suite',
    'peer_verified', 'error', 'role'. Suppressed if the session has
    been destroyed.
    """
    if session is None:
        return
    try:
        NotificationCenter().post_notification(
            'SIPSessionSylkZRTPStateChanged',
            sender=session,
            data=NotificationData(**kw))
    except Exception:
        # Don't let a notification failure kill the handshake.
        pass


# --- The state machine ----------------------------------------------------

class SylkZRTPSession(object):
    """One handshake bound to one SIP Session.

    Created automatically by Session when both ends signaled
    X-Sylk-ZRTP capability and the local account is configured for an
    SRTP key negotiation we layer on top of. Application code never
    needs to instantiate this directly.

    State machine (mirrored on both ends):
        idle → probing → key-agreed → key-active
                     ↘ failed
    """

    is_available = _CRYPTO_AVAILABLE   # module flag re-exported per-instance

    def __init__(self, session, role):
        self.session = session
        self.role = role  # 'caller' | 'callee'
        # SIP Call-ID, put in every payload so cross-account
        # account-message forks can filter by call.
        dialog_id = getattr(session, 'dialog_id', None)
        if dialog_id is not None:
            self.call_id = dialog_id.call_id
        else:
            inv = getattr(session, '_invitation', None)
            self.call_id = getattr(inv, 'call_id', None)
        self.ephem_priv = X25519PrivateKey.generate()
        self.ephem_pub_bytes = self.ephem_priv.public_key().public_bytes(
            encoding=Encoding.Raw, format=PublicFormat.Raw)
        self.peer_ephem_pub = None
        self.shared_secret = None
        self.derived = None
        self.sas_chars = None
        self.sas_emojis = None
        self.state = 'idle'
        self._destroyed = False
        # ---- v2 continuity ---------------------------------------------
        # Negotiated wire version (1 or 2). Pinned to peer's version at
        # the moment we see their first payload. v1 means no rs1 mix.
        self.negotiated_version = SYLK_ZRTP_VERSION
        # The peer AOR string used to key the rs1 store.
        self.peer_aor = _peer_aor_from_session(session)
        # rs1 we held for this peer BEFORE the call started. Used to
        # compute our outgoing rs_id_hex, and to mix into HKDF if the
        # peer's rs_id matches its hash.
        self.local_rs1 = _secret_store.get(self.peer_aor) if self.peer_aor else None
        self.local_rs_id_hex = _rs_id_hex(self.local_rs1) if self.local_rs1 else None
        # rs_id seen on the wire from the peer (set in handle_incoming
        # before _derive runs).
        self.peer_rs_id_hex = None
        # One of: 'first-time' (no rs1 stored on either side),
        #         'verified' (both sides held matching rs1 → mixed),
        #         'mismatch' (both sides held rs1 but differed →
        #             current call did NOT mix; app should alarm + ask
        #             user before rotating),
        #         'one-sided-local' (we had rs1, peer didn't — they
        #             reinstalled or lost cache),
        #         'one-sided-peer' (peer had rs1, we didn't).
        self.continuity_state = 'first-time'
        # True iff this call's _derive actually mixed rs1 into HKDF.
        # Drives whether next_rs1 is automatically rotated on key-active
        # vs requiring an explicit SAS-Confirm to seed.
        self._mixed_rs1 = False

    def _post(self, **kw):
        """Wrap _post_state with the per-session metadata every observer
        wants on every state change: the negotiated wire version, the
        continuity decision, and our role. Helps consumer apps log a
        clear "v2, continuity=verified" trail without each one re-deriving
        it from the session."""
        kw.setdefault('protocol_version', self.negotiated_version)
        kw.setdefault('continuity_state', self.continuity_state)
        kw.setdefault('role', self.role)
        _post_state(self.session, **kw)

    @property
    def sas(self):
        """Combined SAS string for user display: 4 chars + space + 4 emojis."""
        if self.sas_chars is None:
            return None
        return self.sas_chars + ' ' + self.sas_emojis

    # ---- outbound ----------------------------------------------------

    def start_probe(self):
        """Caller-side kickoff. Idempotent."""
        if self._destroyed or self.state != 'idle':
            return
        self.state = 'probing'
        self._post(state='probing', role=self.role)
        log.info('[sylk-zrtp] caller call %s: starting probe '
                 'local_version=%d peer_aor=%s rs1_stored=%s'
                 % (self.call_id, SYLK_ZRTP_VERSION,
                    self.peer_aor, 'yes' if self.local_rs1 else 'no'))
        payload = {
            'v': SYLK_ZRTP_VERSION,
            'type': 'probe',
            'call_id': self.call_id,
            'ephem_pub_hex': self.ephem_pub_bytes.hex(),
            'suites': list(SYLK_ZRTP_SUITES),
        }
        if self.local_rs_id_hex:
            payload['rs_id_hex'] = self.local_rs_id_hex
        self._send(payload, label='probe')

    # ---- inbound dispatch -------------------------------------------

    def handle_incoming(self, payload):
        """Drive the state machine from a peer-sent JSON dict."""
        if self._destroyed:
            return
        if not isinstance(payload, dict):
            return
        peer_v = payload.get('v')
        # Accept any version <= ours; pin to the minimum so a v1 peer keeps
        # v1 derivation semantics (no rs1 mix) even if we'd otherwise speak v2.
        if not isinstance(peer_v, int) or peer_v < 1 or peer_v > SYLK_ZRTP_VERSION:
            return
        self.negotiated_version = min(peer_v, SYLK_ZRTP_VERSION)
        pcid = payload.get('call_id')
        if not pcid or pcid != self.call_id:
            return  # missing or wrong call_id — drop (hardening: was 'pcid and ...')
        ty = payload.get('type')
        # Stash the peer's rs_id (if any) before _derive runs. Only meaningful
        # on probe and accept; recv_ready/sender_ready don't carry it.
        if ty in ('probe', 'accept') and self.negotiated_version >= 2:
            rs_id = payload.get('rs_id_hex')
            if isinstance(rs_id, str) and len(rs_id) == SYLK_ZRTP_RS_ID_HEX_LEN \
                    and all(c in '0123456789abcdefABCDEF' for c in rs_id):
                self.peer_rs_id_hex = rs_id.lower()
            else:
                self.peer_rs_id_hex = None
        try:
            if ty == 'probe':
                return self._on_probe(payload)
            if ty == 'accept':
                return self._on_accept(payload)
            if ty == 'recv_ready':
                return self._on_recv_ready(payload)
            if ty == 'sender_ready':
                return self._on_sender_ready(payload)
        except Exception as e:
            self.state = 'failed'
            self._post(state='failed', role=self.role, error=str(e))

    def _on_probe(self, payload):
        if not payload.get('ephem_pub_hex'):
            return
        self.peer_ephem_pub = bytes.fromhex(payload['ephem_pub_hex'])
        if len(self.peer_ephem_pub) != 32:
            self.state = 'failed'
            self._post(state='failed', role=self.role,
                        error='peer ephem_pub_hex decoded to %d bytes' % len(self.peer_ephem_pub))
            return
        self._derive()
        reply = {
            'v': self.negotiated_version,
            'type': 'accept',
            'call_id': self.call_id,
            'ephem_pub_hex': self.ephem_pub_bytes.hex(),
        }
        if self.negotiated_version >= 2 and self.local_rs_id_hex:
            reply['rs_id_hex'] = self.local_rs_id_hex
        self._send(reply, label='accept')

    def _on_accept(self, payload):
        if not payload.get('ephem_pub_hex'):
            return
        self.peer_ephem_pub = bytes.fromhex(payload['ephem_pub_hex'])
        if len(self.peer_ephem_pub) != 32:
            self.state = 'failed'
            self._post(state='failed', role=self.role,
                        error='peer ephem_pub_hex decoded to %d bytes' % len(self.peer_ephem_pub))
            return
        self._derive()
        reply = {'v': self.negotiated_version, 'type': 'recv_ready', 'call_id': self.call_id}
        self._send(reply, label='recv_ready')

    def _on_recv_ready(self, payload):
        # Peer ready to receive. Reply sender_ready and finalize.
        reply = {'v': self.negotiated_version, 'type': 'sender_ready', 'call_id': self.call_id}
        self._send(reply, label='sender_ready')
        self.state = 'key-agreed'
        self._post(state='key-agreed', role=self.role,
                    sas=self.sas, suite='AES-128-GCM',
                    continuity_state=self.continuity_state)
        self._finalize_after_install()

    def _on_sender_ready(self, payload):
        self.state = 'key-agreed'
        self._post(state='key-agreed', role=self.role,
                    sas=self.sas, suite='AES-128-GCM',
                    continuity_state=self.continuity_state)
        self._finalize_after_install()

    def _finalize_after_install(self):
        """Run _install_aead_keys_on_streams and drive the post-install
        state transition: key-active on at least one successful install,
        failed if every stream rejected the keys.

        This is the only place in the state machine that emits 'key-active'.
        Apps that surface a "secure" UI pill (Blink, sip-session3,
        Sylk Mobile) should treat 'key-active' — not 'key-agreed' — as
        the cue that media is actually being AEAD-encrypted. 'key-agreed'
        only means we have the keys; the streams may not be wired yet.
        """
        installed, failed = self._install_aead_keys_on_streams()
        if installed:
            installed_summary = ', '.join(
                '%s(codec=%s,prefix=%d)' % (typ, codec, vp)
                for (typ, codec, vp) in installed)
            log.info('[sylk-zrtp] %s call %s: AEAD keys installed on [%s]; transitioning to key-active'
                     % (self.role, self.call_id, installed_summary))
            self.state = 'key-active'
            # Automatic rs1 rotation on continuity-verified calls. We do
            # NOT auto-rotate on 'mismatch' or 'one-sided-*' or
            # 'first-time' — those require an explicit SAS Confirm from
            # the user (which calls confirm_sas_and_seed_rs1) before any
            # secret is written. This ensures a MitM cannot complete a
            # call without rs1 mix and silently get a rotation that the
            # legitimate peer will mismatch on next time.
            if self._mixed_rs1 and self.peer_aor:
                next_rs1 = self._derive_next_rs1()
                if next_rs1:
                    if _secret_store.put(self.peer_aor, next_rs1):
                        self.local_rs1 = next_rs1
                        self.local_rs_id_hex = _rs_id_hex(next_rs1)
                        log.info('[sylk-zrtp] %s call %s: rs1 rotated for peer=%s'
                                 % (self.role, self.call_id, self.peer_aor))
            self._post(state='key-active', role=self.role,
                        sas=self.sas, suite='AES-128-GCM',
                        continuity_state=self.continuity_state,
                        installed_streams=installed,
                        failed_streams=failed)
        else:
            # Every stream rejected the install. The handshake is "done"
            # (both sides have keys) but media is plain SRTP — the pill
            # must NOT light up. Drop to 'failed' with the per-stream
            # errors visible so apps can surface a meaningful message.
            failed_summary = ', '.join(
                '%s(codec=%s,reason=%s)' % (typ, codec, reason)
                for (typ, codec, reason) in failed) or 'no streams'
            log.warning('[sylk-zrtp] %s call %s: AEAD install failed on every stream: %s'
                        % (self.role, self.call_id, failed_summary))
            self.state = 'failed'
            self._post(state='failed', role=self.role,
                        error='AEAD install rejected on every stream: ' + failed_summary,
                        failed_streams=failed)

    # ---- crypto -----------------------------------------------------

    def _derive(self):
        peer_pub = X25519PublicKey.from_public_bytes(self.peer_ephem_pub)
        self.shared_secret = self.ephem_priv.exchange(peer_pub)
        # Decide the continuity state and pick the HKDF salt accordingly.
        # See SylkZrtpSecretStore docstring for the policy.
        local_id = self.local_rs_id_hex
        peer_id = self.peer_rs_id_hex
        if self.negotiated_version < 2 or self.local_rs1 is None:
            if peer_id and self.local_rs1 is None:
                self.continuity_state = 'one-sided-peer'
            elif local_id and not peer_id:
                self.continuity_state = 'one-sided-local'
            else:
                self.continuity_state = 'first-time'
            salt = b'\x00' * 32
            self._mixed_rs1 = False
        else:
            if peer_id is None:
                self.continuity_state = 'one-sided-local'
                salt = b'\x00' * 32
                self._mixed_rs1 = False
            elif peer_id == local_id:
                self.continuity_state = 'verified'
                salt = self.local_rs1
                self._mixed_rs1 = True
            else:
                # Both sides hold an rs1 but they don't match — could be a
                # legitimate reinstall, could be MitM. _derive completes
                # WITHOUT mixing rs1 so the call proceeds, but the app
                # should surface the alarm and not rotate rs1 unless the
                # user explicitly confirms by re-verifying SAS.
                self.continuity_state = 'mismatch'
                salt = b'\x00' * 32
                self._mixed_rs1 = False
        k_c2e = _hkdf(self.shared_secret, salt, 'sylk-e2ee/v1/audio-caller-to-callee', 16)
        k_e2c = _hkdf(self.shared_secret, salt, 'sylk-e2ee/v1/audio-callee-to-caller', 16)
        s_c2e = _hkdf(self.shared_secret, salt, 'sylk-e2ee/v1/audio-caller-to-callee-salt', 8)
        s_e2c = _hkdf(self.shared_secret, salt, 'sylk-e2ee/v1/audio-callee-to-caller-salt', 8)
        sas_bytes = _hkdf(self.shared_secret, salt, 'sylk-zrtp/v1/sas', 8)
        self.derived = {
            'audio_c2e_key':  k_c2e,
            'audio_e2c_key':  k_e2c,
            'audio_c2e_salt': s_c2e,
            'audio_e2c_salt': s_e2c,
        }
        self.sas_chars = ''.join(_SAS_CHARS[b & 0x1F] for b in sas_bytes[:4])
        self.sas_emojis = ''.join(_SAS_EMOJIS[b & 0x1F] for b in sas_bytes[4:8])
        log.info('[sylk-zrtp] %s call %s: derive done, continuity=%s, mixed_rs1=%s, peer_aor=%s'
                 % (self.role, self.call_id, self.continuity_state, self._mixed_rs1, self.peer_aor))

    def _derive_next_rs1(self):
        """next_rs1 = HKDF(ss, salt=..., info='sylk-zrtp/v2/next-rs1', 32).

        The salt is the current rs1 ONLY when this call's continuity_state
        was 'verified' (both sides proved they held the same rs1). On
        mismatch / first-time / one-sided the two sides held DIFFERENT
        local rs1 (or none) — so salting with our local rs1 would diverge
        next_rs1 from the peer's again, perpetuating the mismatch forever.
        Falling back to zero salt makes both sides converge on the same
        fresh next_rs1 derived purely from the X25519 output. After a SAS
        Confirm on both ends, the next call's rs_id_hex matches and
        continuity engages cleanly.
        """
        if self.shared_secret is None:
            return None
        salt = self.local_rs1 if (self.continuity_state == 'verified'
                                  and self.local_rs1) else (b'\x00' * 32)
        try:
            return _hkdf(self.shared_secret, salt, 'sylk-zrtp/v2/next-rs1', _RS_LEN)
        except Exception as e:
            log.warning('[sylk-zrtp] next_rs1 derivation failed: %s' % e)
            return None

    def confirm_sas_and_seed_rs1(self):
        """Called by the app when the user has compared the SAS verbally
        and tapped Confirm. Seeds the per-peer rs1 in the SQLite store so
        the next call has continuity to compare against. Safe to call
        multiple times; safe to call on any continuity_state.

        Also flips continuity_state to 'verified' so the UI / prompt
        reflects the new trust state immediately — without this the
        protocol-level decision computed in _derive stays frozen at
        'mismatch' / 'first-time' / 'one-sided-*' until the next call,
        and consumer apps keep showing the stale label."""
        if self.peer_aor is None or self.shared_secret is None:
            return False
        next_rs1 = self._derive_next_rs1()
        if next_rs1 is None:
            return False
        ok = _secret_store.put(self.peer_aor, next_rs1)
        if ok:
            self.local_rs1 = next_rs1
            self.local_rs_id_hex = _rs_id_hex(next_rs1)
            self.continuity_state = 'verified'
            log.info('[sylk-zrtp] %s call %s: rs1 seeded for peer=%s via SAS Confirm'
                     % (self.role, self.call_id, self.peer_aor))
        return ok

    def clear_rs1(self):
        """Forget the stored rs1 for this peer (e.g. user chose Continue
        past a mismatch alarm, or explicitly cleared the binding from the
        contact UI)."""
        if self.peer_aor is None:
            return False
        ok = _secret_store.delete(self.peer_aor)
        if ok:
            self.local_rs1 = None
            self.local_rs_id_hex = None
            log.info('[sylk-zrtp] %s call %s: rs1 cleared for peer=%s'
                     % (self.role, self.call_id, self.peer_aor))
        return ok

    # ---- AEAD install (per stream) ----------------------------------

    def _install_aead_keys_on_streams(self):
        """Install the derived AES-128-GCM keys on every eligible stream.

        Returns (installed, failed) where each element is a list of
        (stream_type, codec, video_prefix_or_reason) tuples — installed
        carries the video_prefix actually used, failed carries the
        exception text. The caller uses these lists to drive the
        key-active vs failed state transition AND to log per-stream
        details so a missing AEAD adapter, an unattached stream, or a
        codec mismatch are all visible instead of silently swallowed.
        """
        installed = []
        failed = []
        if not self.derived:
            log.warning('[sylk-zrtp] %s call %s: install requested but no derived keys (state=%s)'
                        % (self.role, self.call_id, self.state))
            return installed, failed
        if self.role == 'caller':
            send_key  = self.derived['audio_c2e_key']
            send_salt = self.derived['audio_c2e_salt']
            recv_key  = self.derived['audio_e2c_key']
            recv_salt = self.derived['audio_e2c_salt']
        else:
            send_key  = self.derived['audio_e2c_key']
            send_salt = self.derived['audio_e2c_salt']
            recv_key  = self.derived['audio_c2e_key']
            recv_salt = self.derived['audio_c2e_salt']

        streams = list(self.session.streams or [])
        if not streams:
            log.warning('[sylk-zrtp] %s call %s: install requested but session has no streams yet'
                        % (self.role, self.call_id))
            return installed, failed

        for stream in streams:
            if stream.type not in ('audio', 'video'):
                continue
            raw_codec = getattr(stream, 'codec', None)
            if isinstance(raw_codec, str):
                codec = raw_codec.upper()
            elif isinstance(raw_codec, (bytes, bytearray)):
                codec = raw_codec.decode('ascii', errors='replace').upper()
            else:
                codec = ''
            if stream.type == 'video' and _should_skip_video_for_codec(codec):
                log.info('[sylk-zrtp] %s call %s: skipping video AEAD install (codec=%s — STAP-A incompatible)'
                         % (self.role, self.call_id, codec or '?'))
                failed.append((stream.type, codec or '?', 'codec-skipped'))
                continue
            vp = _video_prefix_for_codec(codec) if stream.type == 'video' else 0
            install_fn = getattr(stream, 'set_aead_keys', None)
            if install_fn is None:
                reason = 'stream has no set_aead_keys (SDK pre-AEAD?)'
                log.warning('[sylk-zrtp] %s call %s: %s stream install rejected: %s'
                            % (self.role, self.call_id, stream.type, reason))
                failed.append((stream.type, codec or '?', reason))
                continue
            try:
                install_fn(send_key, send_salt, recv_key, recv_salt,
                           key_id=1, video_prefix=vp)
            except Exception as e:
                reason = '%s: %s' % (type(e).__name__, e)
                log.warning('[sylk-zrtp] %s call %s: %s stream install rejected (codec=%s, prefix=%d): %s'
                            % (self.role, self.call_id, stream.type, codec or '?', vp, reason))
                failed.append((stream.type, codec or '?', reason))
                continue
            log.info('[sylk-zrtp] %s call %s: %s stream install OK (codec=%s, video_prefix=%d, role=%s)'
                     % (self.role, self.call_id, stream.type, codec or '?', vp, self.role))
            installed.append((stream.type, codec or '?', vp))

        return installed, failed

    # ---- transport --------------------------------------------------

    def _send(self, payload, label):
        """Serialize and send as an in-dialog SIP MESSAGE via
        Session.send_message. CPIM is built by the caller in older code;
        here we send the JSON body directly with the ZRTP content-type.
        (Sylk-server's webrtcgateway and sylk-mobile both accept either
        bare JSON or CPIM-wrapped JSON for this content-type.)"""
        if self._destroyed:
            return
        body = json.dumps(payload).encode('utf-8')
        try:
            self.session.send_message(SYLK_ZRTP_CONTENT_TYPE, body)
        except Exception as e:
            # Most likely: dialog already torn down. Mark failed.
            self.state = 'failed'
            self._post(state='failed', role=self.role,
                        error='send %s failed: %s' % (label, e))

    # ---- lifecycle --------------------------------------------------

    def destroy(self):
        self._destroyed = True
