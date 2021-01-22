
"""Configuration backend for storing settings in memory"""

__all__ = ["MemoryBackend"]

from zope.interface import implementer
from sipsimple.configuration.backend import IConfigurationBackend


@implementer(IConfigurationBackend)
class MemoryBackend(object):
    """Implementation of a configuration backend that stores data in memory."""


    def __init__(self):
        self.data = {}

    def load(self):
        return self.data

    def save(self, data):
        self.data = data


