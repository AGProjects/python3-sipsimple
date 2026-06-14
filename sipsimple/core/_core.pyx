
include "_core.error.pxi"
include "_core.lib.pxi"
include "_core.sound.pxi"
include "_core.video.pxi"
include "_core.util.pxi"

include "_core.ua.pxi"

include "_core.event.pxi"
include "_core.request.pxi"
include "_core.helper.pxi"
include "_core.headers.pxi"
include "_core.subscription.pxi"
include "_core.invitation.pxi"
include "_core.referral.pxi"
include "_core.sdp.pxi"
include "_core.mediatransport.pxi"

import cython

# constants

PJ_VERSION = pj_get_version()
PJ_SVN_REVISION = int(PJ_SVN_REV)
# Track the underlying pjsip build (212 or 217) so the runtime banner
# ("core version 217.N") matches what _core.so actually links against.
# The compatibility gate in sipsimple/core/__init__.py accepts both.
CORE_REVISION = PJ_SVN_REVISION

# Local build counter. Bump CORE_BUILD each time you cut a new _core.so
# so the runtime banner ("core version <rev>.N") proves the new code is
# loaded.
CORE_BUILD = 12

CYTHON_VERSION = cython.__version__

# exports

__all__ = ["PJ_VERSION", "PJ_SVN_REVISION", "CORE_REVISION", "CORE_BUILD", "CYTHON_VERSION",
           "SIPCoreError", "PJSIPError", "PJSIPTLSError", "SIPCoreInvalidStateError",
           "AudioMixer", "ToneGenerator", "RecordingWaveFile", "WaveFile", "MixerPort",
           "VideoCamera", "FrameBufferVideoRenderer",
           "sip_status_messages",
           "BaseCredentials", "Credentials", "FrozenCredentials", "BaseSIPURI", "SIPURI", "FrozenSIPURI",
           "BaseHeader", "Header", "FrozenHeader",
           "BaseContactHeader", "ContactHeader", "FrozenContactHeader",
           "BaseContentTypeHeader", "ContentType", "ContentTypeHeader", "FrozenContentTypeHeader",
           "BaseIdentityHeader", "IdentityHeader", "FrozenIdentityHeader", "FromHeader", "FrozenFromHeader", "ToHeader", "FrozenToHeader",
           "RouteHeader", "FrozenRouteHeader", "RecordRouteHeader", "FrozenRecordRouteHeader", "BaseRetryAfterHeader", "RetryAfterHeader", "FrozenRetryAfterHeader",
           "BaseViaHeader", "ViaHeader", "FrozenViaHeader", "BaseWarningHeader", "WarningHeader", "FrozenWarningHeader",
           "BaseEventHeader", "EventHeader", "FrozenEventHeader", "BaseSubscriptionStateHeader", "SubscriptionStateHeader", "FrozenSubscriptionStateHeader",
           "BaseReasonHeader", "ReasonHeader", "FrozenReasonHeader",
           "BaseReferToHeader", "ReferToHeader", "FrozenReferToHeader",
           "BaseSubjectHeader", "SubjectHeader", "FrozenSubjectHeader",
           "BaseReplacesHeader", "ReplacesHeader", "FrozenReplacesHeader",
           "Request",
           "Referral",
           "sipfrag_re",
           "Subscription",
           "Invitation",
           "DialogID",
           "SDPSession", "FrozenSDPSession", "SDPMediaStream", "FrozenSDPMediaStream", "SDPConnection", "FrozenSDPConnection", "SDPAttribute", "FrozenSDPAttribute", "SDPNegotiator",
           "RTPTransport", "AudioTransport", "VideoTransport"]


