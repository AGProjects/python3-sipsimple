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

from sipsimple.configuration.settings import SIPSimpleSettings

try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes
    _CRYPTO_AVAILABLE = True
except ImportError:
    _CRYPTO_AVAILABLE = False

# Optional PGP integration for v3 signed-handshake. pgpy is declared in
# python3-sipsimple's python-requirements.txt so it should be present on
# any properly-built deployment. We import it conditionally so the module
# still loads (and behaves like v2) on environments where pgpy is missing.
try:
    import pgpy
    _PGP_AVAILABLE = True
except ImportError:
    _PGP_AVAILABLE = False


# --- Wire constants --------------------------------------------------------

# Highest wire version we speak.
#   v1 — original protocol (no continuity, no signatures).
#   v2 — adds rs_id (SHA-256 prefix of rs1) to probe/accept for RFC 6189-
#        style continuity. HKDF salt is rs1 on continuity-verified calls.
#   v3 — adds detached PGP signatures on probe/accept payloads. Closes
#        the SIP-MitM-swaps-ephemeral-pubkeys attack — a MitM who can
#        rewrite signaling can't forge a signature under the peer's PGP
#        private key.
# Older peers stay interoperable: the negotiated version is min-pinned
# per session, so a v3 peer talking to a v1 peer behaves like v1 (no
# signature, no rs1 mix).
SYLK_ZRTP_VERSION = 3
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


# --- Canonical JSON + PGP sign / verify (v3) -------------------------------
#
# v3 attaches a detached PGP signature over the canonical-JSON encoding
# of the probe / accept payload (every field except `sig` itself). The
# JS side uses an identical canonical-JSON serialiser so the bytes the
# two libraries sign / verify match exactly. Conventions:
#   - JSON with keys sorted lexicographically at every depth.
#   - No whitespace between tokens (',' / ':' separators).
#   - UTF-8 byte encoding.
#   - Non-ASCII characters left as-is (ensure_ascii=False) — irrelevant
#     for our current payloads which are all hex/ASCII anyway, but spec'd
#     so future extensions don't introduce ambiguity.

def _canonical_json_bytes(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'),
                      ensure_ascii=False).encode('utf-8')


def _strip_sig(payload):
    """Return a shallow copy of `payload` without the 'sig' field."""
    return {k: v for k, v in payload.items() if k != 'sig'}


def _pgp_sign_payload(local_priv_key_blob, payload):
    """Detached-sign the canonical JSON of `payload` (sans 'sig') with the
    given armored PGP private key. Returns the armored signature string,
    or None on failure / when PGP isn't available."""
    if not _PGP_AVAILABLE or not local_priv_key_blob:
        return None
    try:
        body = _canonical_json_bytes(_strip_sig(payload))
        key, _ = pgpy.PGPKey.from_blob(local_priv_key_blob)
        # If the private key is passphrase-protected the caller must
        # unlock it before passing it in. We attempt sign directly; if
        # it raises PGPError due to a locked key, log and fail.
        sig = key.sign(body.decode('utf-8'))
        return str(sig)
    except Exception as e:
        log.warning('[sylk-zrtp] PGP sign failed: %s' % e)
        return None


def _pgp_verify_payload(peer_pub_key_blob, payload, sig_armored):
    """Verify the armored detached signature against the canonical JSON
    of `payload` (sans 'sig') using the given armored peer public key.
    Returns True on a verified signature, False otherwise."""
    if not _PGP_AVAILABLE or not peer_pub_key_blob or not sig_armored:
        return False
    try:
        body = _canonical_json_bytes(_strip_sig(payload))
        key, _ = pgpy.PGPKey.from_blob(peer_pub_key_blob)
        sig = pgpy.PGPSignature.from_blob(sig_armored)
        verification = key.verify(body.decode('utf-8'), sig)
        return bool(verification)
    except Exception as e:
        log.warning('[sylk-zrtp] PGP verify failed: %s' % e)
        return False


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

    def list_for_aor(self, peer_aor):
        """Return every (peer_device_id, rs1) tuple stored for peer_aor.

        Iterates rows whose key matches `peer_aor` exactly (legacy single-
        slot) OR `peer_aor#<device_id>` (per-device composite slots).
        Used by start_probe to build the rs_id_hex_candidates array so
        the callee can pick the entry matching its OWN local_device_id
        — solving the multi-device case where the caller can't know
        which of the peer's devices will pick up this call at probe-send
        time. The legacy slot maps to device_id=None in the returned
        list so the caller still ships it under the top-level rs_id_hex
        field (handled separately in start_probe).

        Returns a list of (device_id_or_None, rs1_bytes). Empty if no
        entries or on store-open failure.
        """
        if not peer_aor:
            return []
        out = []
        with self._lock:
            conn = self._ensure_open()
            if conn is None:
                return out
            try:
                # peer_aor + '#%' matches every composite key for this AOR
                # AND the exact peer_aor row (legacy slot) is fetched
                # separately so wildcard escaping isn't needed.
                exact = conn.execute(
                    "SELECT rs1 FROM sylk_zrtp_secrets WHERE peer_aor = ?",
                    (peer_aor,)).fetchone()
                rows = conn.execute(
                    "SELECT peer_aor, rs1 FROM sylk_zrtp_secrets WHERE peer_aor LIKE ?",
                    (peer_aor + '#%',)).fetchall()
            except Exception as e:
                log.warning('[sylk-zrtp] secret store list_for_aor(%s) failed: %s'
                            % (peer_aor, e))
                return out
        if exact is not None:
            rs1 = exact[0]
            if isinstance(rs1, (bytes, bytearray)) and len(rs1) == _RS_LEN:
                out.append((None, bytes(rs1)))
        for key, rs1 in rows:
            if not isinstance(rs1, (bytes, bytearray)) or len(rs1) != _RS_LEN:
                continue
            # key looks like 'peer_aor#device_id'; split on the FIRST '#'.
            # device_ids in this codebase are hex-only so '#' is safe as
            # a delimiter, but we still split with maxsplit=1 to be
            # robust against any AOR shape change later.
            parts = key.split('#', 1)
            dev = parts[1] if len(parts) == 2 and parts[1] else None
            out.append((dev, bytes(rs1)))
        return out


_secret_store = SylkZrtpSecretStore()


# ----- v3 signing-keys auto-plumbing hook -------------------------------
#
# Problem: SylkZRTPSession.set_signing_keys() lives on the instance and
# the consuming application (sip-session3, sylk-server, …) is the only
# place that knows where local PGP private keys + cached peer public
# keys are stored. session.py creates SylkZRTPSession and immediately
# calls start_probe() (caller) or handle_incoming() (callee), giving the
# consumer no synchronous opportunity to inject keys between
# construction and the first signed payload going on the wire.
#
# Solution: a module-level provider callback that the consumer
# registers ONCE at startup. The SylkZRTPSession constructor calls it
# (best-effort) to pull (local_priv_blob, peer_pub_blob) for the
# session being built, sets them on the instance, and then proceeds as
# usual. The result is automatic v3 sign + verify on every call without
# a /zrtp_pgp_keys slash command for each one.
#
# Callback shape:
#     def provider(session, role) -> (local_priv_blob, peer_pub_blob)
#
# Either tuple element may be None; the provider may return None
# wholesale to mean "no keys this time" (e.g. peer hasn't sent us their
# pubkey yet). Exceptions inside the provider are caught and logged —
# they MUST NOT take down a call. Setting the provider to None disables
# auto-plumbing without touching the manual set_signing_keys() path.
_signing_keys_provider = None


def register_signing_keys_provider(fn):
    """Register a callback invoked on every SylkZRTPSession construction
    to auto-populate (local_priv_blob, peer_pub_blob). See module
    docstring above for the contract. Pass None to disable."""
    global _signing_keys_provider
    if fn is not None and not callable(fn):
        raise TypeError('signing_keys_provider must be callable or None')
    _signing_keys_provider = fn


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
        # Set to True when _install_aead_keys_on_streams returns with
        # every failure tagged 'transport-not-ready' — meaning the SDK
        # MESSAGE handshake completed before the RTP transport finished
        # initializing. Session._NH_MediaStreamDidStart will then call
        # retry_install() once the transport is up. Idempotent under
        # repeated MediaStreamDidStart fires.
        self._install_deferred = False
        # ---- v2 continuity ---------------------------------------------
        # Negotiated wire version (1 or 2). Pinned to peer's version at
        # the moment we see their first payload. v1 means no rs1 mix.
        self.negotiated_version = SYLK_ZRTP_VERSION
        # The peer AOR string used to key the rs1 store.
        self.peer_aor = _peer_aor_from_session(session)
        # Initial rs1 lookup is AOR-only (legacy / single-device slot)
        # because peer_device_id isn't known until the first inbound
        # payload arrives. _resolve_local_rs1_for_peer_device() re-runs
        # the lookup using composite key (peer_aor, peer_device_id) once
        # we learn the device.
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
        # ---- v3 PGP signed handshake -----------------------------------
        # Armored PGP keys plumbed in by the application via
        # set_signing_keys(). When local_priv_key is set, we sign outgoing
        # probe / accept; when peer_pub_key is set, we verify incoming
        # probe / accept and fail the session on bad signatures. Without
        # both, v3 degrades to v2 semantics for this pairing (no sig
        # sent, no sig required to accept). The hook design lets each
        # consuming app (sip-session3, sylk-server, ...) wire keys from
        # wherever it stores them.
        self.local_priv_key = None
        self.peer_pub_key = None
        # ---- v3 device-id keying ---------------------------------------
        # Our local SIP +sip.instance / settings.instance_id, used to
        # identify THIS install to the peer and (via the peer's own
        # device_id) to key rs1 storage. With per-device keying,
        # different physical devices behind the same SIP AOR no longer
        # collide on the rs1 slot — fixes the multi-device collapse
        # problem where A↔B verification gets overwritten by an A↔C call.
        #
        # IMPORTANT — instance_id lives on SIPSimpleSettings (the
        # process-wide singleton), NOT on Account.sip. The +sip.instance
        # Contact-header parameter is also built from settings.instance_id
        # (see account/registration.py), so reading it here ensures
        # whatever we tell our ZRTP peer matches what the peer's SIP
        # stack sees in the REGISTER / INVITE. The previous attempt at
        # `session.account.sip.instance_id` always returned None, so the
        # python-sipsimple side shipped probes without `device_id`, the
        # peer (sylk-mobile) couldn't establish per-device rs1 keying,
        # and it fell back to its legacy single-device slot whose
        # contents diverged from our composite slot — the cascading
        # "SAS changed" / continuity=mismatch every other call.
        #
        # settings.instance_id is stored as a URN ("urn:uuid:<UUID>");
        # we normalise to the bare UUID string so the wire format
        # matches sylk-mobile's react-native-device-info getUniqueId()
        # output (a hex blob) on length / shape and the on-the-wire
        # value stays stable across restarts.
        try:
            settings = SIPSimpleSettings()
            inst = getattr(settings, 'instance_id', None)
            if isinstance(inst, bytes):
                inst = inst.decode('ascii', errors='replace')
            if inst:
                # Strip a "urn:uuid:" prefix if present; pass the rest
                # through uuid.UUID for canonical lowercase formatting.
                # On any parse error fall back to the raw string so a
                # legacy non-URN value still gets used.
                try:
                    inst = str(uuid.UUID(inst))
                except (ValueError, AttributeError):
                    pass
            self.local_device_id = inst or None
        except Exception:
            self.local_device_id = None
        self.peer_device_id = None

        # ---- v3 signing-keys auto-plumbing -----------------------------
        # If the application registered a provider via
        # register_signing_keys_provider(), call it now to populate
        # local_priv_key / peer_pub_key. Done BEFORE the "session
        # created" log line below so the peer_pgp / local_priv flags it
        # prints reflect reality. Provider exceptions are demoted to
        # warnings — a misbehaving provider must not abort a call (the
        # session falls back to "no keys plumbed" which degrades to v2
        # semantics for this pairing, same as if the provider returned
        # (None, None)). Done AFTER the manual fields above so a later
        # explicit set_signing_keys() call still wins as documented.
        if _signing_keys_provider is not None:
            try:
                result = _signing_keys_provider(session, role)
            except Exception as e:
                log.warning('[sylk-zrtp] signing-keys provider raised: %s' % e)
                result = None
            if result is not None:
                try:
                    local_priv_blob, peer_pub_blob = result
                except (TypeError, ValueError) as e:
                    log.warning('[sylk-zrtp] signing-keys provider returned '
                                'non-2-tuple: %s' % e)
                    local_priv_blob = peer_pub_blob = None
                if local_priv_blob is not None:
                    self.local_priv_key = local_priv_blob
                if peer_pub_blob is not None:
                    self.peer_pub_key = peer_pub_blob

        # Session-creation breadcrumb — symmetric with sylk-mobile's
        # "created —" line in CallZrtp.js. Surfaces the things that
        # silently being None used to mask: local_device_id (which the
        # previous Account.sip lookup always read as None, breaking
        # per-device rs1 keying), whether we have a continuity rs1
        # stocked for this peer, and whether v3 signing keys were
        # plumbed in. Logged once at __init__; a grep for the call_id
        # then pairs this against the peer's "created —" line on the
        # mobile side.
        log.info('[sylk-zrtp] %s call %s: session created — '
                 'local_device_id=%s local_rs_id_hex=%s peer_aor=%s '
                 'peer_pgp=%s local_priv=%s'
                 % (self.role, self.call_id,
                    self.local_device_id or '<none>',
                    self.local_rs_id_hex or '<none>',
                    self.peer_aor or '<none>',
                    'yes' if self.peer_pub_key else 'no',
                    'yes' if self.local_priv_key else 'no'))

    def _store_key(self):
        """Composite SQLite key. Uses peer_aor + '#' + peer_device_id
        when we know the peer's device, AOR alone otherwise. Different
        devices behind the same SIP account get separate rs1 slots."""
        if self.peer_aor and self.peer_device_id:
            return '%s#%s' % (self.peer_aor, self.peer_device_id)
        return self.peer_aor

    def _resolve_local_rs1_for_peer_device(self):
        """Re-resolve local_rs1 from the composite (peer_aor,
        peer_device_id) slot once peer_device_id is known. Called from
        handle_incoming on the first probe/accept payload that carries
        device_id. When the composite slot is empty, drops the legacy
        AOR-only fallback we loaded at __init__ — that slot belongs to a
        different peer device and would produce a spurious 'mismatch'
        continuity state."""
        if not self.peer_aor or not self.peer_device_id:
            return
        composite = self._store_key()
        rs1 = _secret_store.get(composite)
        if rs1:
            self.local_rs1 = rs1
            self.local_rs_id_hex = _rs_id_hex(rs1)
            return
        # No per-device slot stored for this exact peer device. Drop the
        # legacy AOR-only rs1 to avoid the multi-device collapse where
        # rs1 from a DIFFERENT peer device gets compared against THIS
        # peer's lookup.
        self.local_rs1 = None
        self.local_rs_id_hex = None

    def set_signing_keys(self, local_priv_blob=None, peer_pub_blob=None):
        """Plumb armored PGP keys into the session for v3 signed handshake.
        Either arg may be None. Should be called before start_probe()
        (caller path) or before the first incoming payload is dispatched
        (callee path); typically immediately after the SylkZRTPSession is
        created by the consuming application."""
        if local_priv_blob is not None:
            self.local_priv_key = local_priv_blob
        if peer_pub_blob is not None:
            self.peer_pub_key = peer_pub_blob
        log.info('[sylk-zrtp] %s call %s: signing keys set '
                 '(local_priv=%s, peer_pub=%s)'
                 % (self.role, self.call_id,
                    'yes' if self.local_priv_key else 'no',
                    'yes' if self.peer_pub_key else 'no'))

    def _maybe_sign(self, payload):
        """Sign the payload in-place when v3 is negotiated and we hold a
        local PGP private key. No-op otherwise. The payload becomes
        ineligible for further mutation after this — the canonical-JSON
        body is committed at sign time."""
        if self.negotiated_version < 3 or not self.local_priv_key:
            return
        sig = _pgp_sign_payload(self.local_priv_key, payload)
        if sig:
            payload['sig'] = sig

    def _verify_or_reject(self, payload):
        """Returns True iff the incoming payload is acceptable.

        - On v < 3 negotiation: always True (signatures are not part of
          the protocol the peer agreed to speak).
        - On v >= 3 with no peer_pub_key configured: True with a warning
          (we can't verify even if peer signed; we degrade rather than
          breaking calls during the v3 rollout phase where one side may
          have keys plumbed in before the other).
        - On v >= 3 with peer_pub_key set and payload missing 'sig':
          True with a warning logged (likely a downgrade-strip attempt
          or a peer that didn't sign for some reason). The call still
          proceeds; tightening this to a hard reject is a config option
          left for the application.
        - On v >= 3 with peer_pub_key set and 'sig' present: verify; on
          failure transition to 'failed' and return False (caller must
          stop processing the payload)."""
        if self.negotiated_version < 3:
            return True
        sig = payload.get('sig') if isinstance(payload, dict) else None
        if not self.peer_pub_key:
            if sig:
                log.warning('[sylk-zrtp] %s call %s: peer sent v3 sig but '
                            'no peer_pub_key plumbed in — cannot verify, '
                            'accepting anyway' % (self.role, self.call_id))
            return True
        if not sig:
            log.warning('[sylk-zrtp] %s call %s: v3 negotiated and we hold '
                        'peer_pub_key but payload has no sig — possible '
                        'downgrade-strip; accepting this call but the '
                        'channel is NOT signed-handshake protected'
                        % (self.role, self.call_id))
            return True
        if _pgp_verify_payload(self.peer_pub_key, payload, sig):
            log.info('[sylk-zrtp] %s call %s: v3 signature verified'
                     % (self.role, self.call_id))
            return True
        log.warning('[sylk-zrtp] %s call %s: v3 signature verification '
                    'FAILED — rejecting payload' % (self.role, self.call_id))
        self.state = 'failed'
        self._post(state='failed',
                   error='PGP signature verification failed on incoming '
                         + str(payload.get('type', '?')))
        return False

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
        if self.local_device_id:
            payload['device_id'] = self.local_device_id
        # Per-device rs_id candidates. The caller can't know which of
        # the peer's devices will pick up this call at probe-send time
        # (multiple devices may be registered behind the same AOR), so
        # we ship the rs_id_hex computed from every per-device rs1 we
        # have stored for this peer_aor. The callee picks the entry
        # whose device_id matches its own local_device_id — see
        # handle_incoming(). This fixes the "caller stored rs1 only in
        # the per-device slot, so the legacy rs_id_hex field is empty
        # and the callee sees us as having no continuity" failure mode
        # that caused asymmetric continuity classification (one side
        # 'verified', the other 'one-sided-local') and the cascading
        # mismatch problem described in CallZrtp.js's drawer fix.
        candidates = []
        for dev, rs1 in _secret_store.list_for_aor(self.peer_aor):
            if not dev:
                continue  # legacy slot already travels in rs_id_hex
            candidates.append({
                'device_id': dev,
                'rs_id_hex': _rs_id_hex(rs1),
            })
        if candidates:
            payload['rs_id_hex_candidates'] = candidates
        self._maybe_sign(payload)
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
        # Stash peer's device_id BEFORE we touch rs1 — per-device storage
        # keying needs to happen before the rs_id comparison in _derive.
        if ty in ('probe', 'accept'):
            dev = payload.get('device_id')
            if isinstance(dev, str) and dev:
                self.peer_device_id = dev
                self._resolve_local_rs1_for_peer_device()
        # Stash the peer's rs_id (if any) before _derive runs. Only meaningful
        # on probe and accept; recv_ready/sender_ready don't carry it.
        #
        # Resolution order (first match wins):
        #   1. rs_id_hex_candidates — list of {device_id, rs_id_hex}.
        #      If our local_device_id appears, use that entry. This is
        #      the "drawer fix" half of CallZrtp.js's mobile change:
        #      lets the caller advertise every per-device rs_id it has
        #      stored for this peer AOR so the callee can pick the one
        #      keyed to its own device, avoiding the asymmetric-
        #      classification problem where caller has per-device rs1
        #      but ships nothing in the legacy slot.
        #   2. rs_id_hex — the single legacy field. Used when the peer
        #      didn't send candidates, or none matched our local_device_id.
        if ty in ('probe', 'accept') and self.negotiated_version >= 2:
            resolved = None
            cands = payload.get('rs_id_hex_candidates')
            if isinstance(cands, list) and self.local_device_id:
                for c in cands:
                    if not isinstance(c, dict):
                        continue
                    if c.get('device_id') != self.local_device_id:
                        continue
                    rid = c.get('rs_id_hex')
                    if isinstance(rid, str) and len(rid) == SYLK_ZRTP_RS_ID_HEX_LEN \
                            and all(ch in '0123456789abcdefABCDEF' for ch in rid):
                        resolved = rid.lower()
                        break
            if resolved is None:
                rs_id = payload.get('rs_id_hex')
                if isinstance(rs_id, str) and len(rs_id) == SYLK_ZRTP_RS_ID_HEX_LEN \
                        and all(c in '0123456789abcdefABCDEF' for c in rs_id):
                    resolved = rs_id.lower()
            self.peer_rs_id_hex = resolved
        # v3 PGP signature verification on probe/accept. Failures mark
        # the session 'failed' and return False; we stop processing the
        # payload. recv_ready / sender_ready are not signed by design
        # (they carry no ephemeral key material — see _on_accept and
        # _on_recv_ready, which intentionally do NOT call _maybe_sign on
        # those replies). For those types we ONLY call _verify_or_reject
        # when a sig is actually present (peer added one for belt-and-
        # braces; we'll still reject a bad sig). Without this gate the
        # "downgrade-strip" warning at _verify_or_reject would fire on
        # every v3 call, since the design's own unsigned messages would
        # look like stripped sigs — drowning real downgrade detection
        # in false positives.
        if ty in ('probe', 'accept'):
            if not self._verify_or_reject(payload):
                return
        elif ty in ('recv_ready', 'sender_ready'):
            if isinstance(payload, dict) and payload.get('sig'):
                if not self._verify_or_reject(payload):
                    return
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
        if self.local_device_id:
            reply['device_id'] = self.local_device_id
        self._maybe_sign(reply)
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
                    if _secret_store.put(self._store_key(), next_rs1):
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
            # No stream actually accepted the keys. Two sub-cases:
            #
            # (a) All failures are 'transport-not-ready' — the SDK's
            #     MESSAGE handshake won the race against SDP/RTP setup.
            #     This is recoverable: MediaStreamDidStart will fire as
            #     the streams finish wiring, and Session._NH_MediaStreamDidStart
            #     will call retry_install() to re-attempt. Stay at
            #     'key-agreed' so the pill remains off (correctly — we
            #     don't have AEAD on the wire yet) but the session is
            #     NOT marked failed and a later install can promote us
            #     to 'key-active'.
            #
            # (b) Permanent failures (no set_aead_keys on stream, codec-
            #     skipped, other exceptions). Drop to 'failed' so the
            #     application surfaces it.
            retryable = [t for t in failed if t[2] == 'transport-not-ready']
            permanent = [t for t in failed if t[2] != 'transport-not-ready']
            if retryable and not permanent:
                self._install_deferred = True
                deferred_summary = ', '.join(
                    '%s(codec=%s)' % (typ, codec)
                    for (typ, codec, _r) in retryable)
                log.info('[sylk-zrtp] %s call %s: AEAD install deferred — '
                         'awaiting MediaStreamDidStart for [%s]; staying '
                         'at key-agreed (pill stays off until retry succeeds)'
                         % (self.role, self.call_id, deferred_summary))
                # Keep state == 'key-agreed'; do not _post a 'failed'
                # state. The retry path posts 'key-active' on success.
                return
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
        """next_rs1 = HKDF(ss, salt=zeros, info='sylk-zrtp/v2/next-rs1', 32).

        Both sides MUST compute identical bytes from identical inputs so
        the rs_id_hex one side sends on the next call matches what the
        other side computes locally.

        Earlier versions mixed the existing rs1 into the HKDF salt when
        continuity_state == 'verified', as a forward-secrecy chain. That
        turned out to be the root cause of a cascading 'SAS changed'
        problem: the two sides decide continuity_state independently from
        local visibility (whose probe carried rs_id_hex, whose didn't),
        so when one side computed 'verified' and the other computed
        'one-sided-local' on the SAME call, they took different salt
        branches and persisted DIFFERENT next_rs1 values. Every
        subsequent call between those endpoints then showed mismatch on
        whichever side received an rs_id_hex first, forever.

        Salt=zeros makes the derivation symmetric by construction. Both
        sides see the same shared_secret and use the same salt, so they
        ALWAYS produce the same next_rs1. The cost is a shallower
        forward-secrecy chain — an attacker who recovered ONE call's
        shared_secret could compute the next rs_id. We accept that
        trade because the continuity indicator misfiring on legitimate
        calls is the actual observed problem; chain-deep forward secrecy
        on rs1 isn't.

        This change is the python3-sipsimple half of the mobile-side fix
        in CallZrtp.js (_deriveNextRs1). Both stacks must change together
        — mobile alone produces a cross-stack mismatch from the 3rd call
        between a mobile and a sipsimple endpoint that achieved verified
        continuity.
        """
        if self.shared_secret is None:
            return None
        salt = b'\x00' * 32
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
        ok = _secret_store.put(self._store_key(), next_rs1)
        if ok:
            self.local_rs1 = next_rs1
            self.local_rs_id_hex = _rs_id_hex(next_rs1)
            self.continuity_state = 'verified'
            log.info('[sylk-zrtp] %s call %s: rs1 seeded for peer=%s device=%s via SAS Confirm'
                     % (self.role, self.call_id, self.peer_aor,
                        self.peer_device_id or '<none>'))
        return ok

    def clear_rs1(self):
        """Forget the stored rs1 for this peer (e.g. user chose Continue
        past a mismatch alarm, or explicitly cleared the binding from the
        contact UI)."""
        if self.peer_aor is None:
            return False
        ok = _secret_store.delete(self._store_key())
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
                # Race detection: stream.set_aead_keys raises RuntimeError
                # when the SDK's MESSAGE handshake completes before the
                # RTP transport finishes initializing. This is recoverable
                # — once MediaStreamDidStart fires the transport will be
                # present. Tag it so _finalize_after_install can defer the
                # 'failed' transition and retry_install() can find it.
                is_transport_race = (
                    isinstance(e, RuntimeError)
                    and 'no RTP transport' in str(e))
                if is_transport_race:
                    log.info('[sylk-zrtp] %s call %s: %s stream install '
                             'deferred (RTP transport not ready yet; '
                             'will retry on MediaStreamDidStart)'
                             % (self.role, self.call_id, stream.type))
                    failed.append((stream.type, codec or '?',
                                   'transport-not-ready'))
                else:
                    log.warning('[sylk-zrtp] %s call %s: %s stream install rejected (codec=%s, prefix=%d): %s'
                                % (self.role, self.call_id, stream.type, codec or '?', vp, reason))
                    failed.append((stream.type, codec or '?', reason))
                continue
            log.info('[sylk-zrtp] %s call %s: %s stream install OK (codec=%s, video_prefix=%d, role=%s)'
                     % (self.role, self.call_id, stream.type, codec or '?', vp, self.role))
            installed.append((stream.type, codec or '?', vp))

        return installed, failed

    # ---- deferred-install retry -------------------------------------

    def retry_install(self):
        """Re-attempt AEAD install after a MediaStreamDidStart notification.

        Called by Session._NH_MediaStreamDidStart when the
        Sylk-ZRTP-over-MESSAGE handshake completed faster than the SDP /
        RTP transport setup and the initial install attempt got
        'transport-not-ready' for every stream. By the time
        MediaStreamDidStart fires the transport is wired, so re-running
        _finalize_after_install should now succeed and promote us to
        'key-active'.

        Idempotent and tolerant of being called when there is nothing
        to do (e.g. when state is already 'key-active' from an earlier
        retry, or 'failed' from a different cause, or 'key-agreed'
        without a prior deferral). MediaStreamDidStart fires once per
        stream per call so this typically runs twice on audio+video
        calls; the first run usually does the work, the second is a
        no-op.
        """
        if self._destroyed:
            return
        if not self._install_deferred:
            return
        if self.state != 'key-agreed':
            return
        if not self.derived:
            return
        log.info('[sylk-zrtp] %s call %s: retry_install — '
                 'RTP transport ready, re-attempting AEAD install'
                 % (self.role, self.call_id))
        # Clear the flag before the call so a re-deferral inside
        # _finalize_after_install (theoretically possible if the retry
        # ALSO races, e.g. on a multi-stream call where one stream
        # started and another hasn't) can re-arm it. The flag is the
        # only signal _finalize_after_install uses; clearing it is safe.
        self._install_deferred = False
        self._finalize_after_install()

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
