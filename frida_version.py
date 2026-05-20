# Compatibility shim — all internal build scripts import from here.
# The actual implementation lives in yszint_version.py.
from releng.yszint_version import *  # noqa: F401,F403
from releng.yszint_version import detect, YszintVersion as FridaVersion  # noqa: F401
