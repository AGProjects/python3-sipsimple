
from sipsimple.core._core import *
from sipsimple.core._engine import *
from sipsimple.core._helpers import *
from sipsimple.core._primitives import *

accepted_revisions = (212, 217)
if CORE_REVISION not in accepted_revisions:
    raise ImportError("Wrong SIP core revision %d (expected one of %s)" % (CORE_REVISION, accepted_revisions))
del accepted_revisions


