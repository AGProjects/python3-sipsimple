
"""Video support"""



__all__ = ['IVideoProducer', 'VideoDevice', 'VideoError']

import time

from application.notification import IObserver, NotificationCenter, NotificationData
from application.python import Null
from zope.interface import Attribute, Interface, implementer

from sipsimple.core import SIPCoreError, VideoCamera


class IVideoProducer(Interface):
    """
    Interface describing an object which can produce video data.
    All attributes of this interface are read-only.
    """

    producer = Attribute("The core producer object which can be connected to a consumer")


class VideoError(Exception):
    pass


@implementer(IVideoProducer, IObserver)
class VideoDevice(object):

    def __init__(self, device_name, resolution, framerate):
        self._camera = self._open_camera(device_name, resolution, framerate)
        NotificationCenter().add_observer(self, sender=self._camera)
        self._camera.start()

    def _open_camera(self, device_name, resolution, framerate, attempts=1):
        # Reopening a camera right after closing it (a new resolution) can fail while the
        # driver still releases it (uvcvideo/libv4l2): try it again for a moment before
        # falling back to another device, which would also replace the device setting.
        for attempt in range(attempts):
            try:
                return VideoCamera(device_name, resolution, framerate)
            except SIPCoreError:
                if attempt + 1 < attempts:
                    time.sleep(0.25)
        try:
            return VideoCamera('system_default', resolution, framerate)
        except SIPCoreError:
            return VideoCamera(None, resolution, framerate)

    def set_camera(self, device_name, resolution, framerate):
        notification_center = NotificationCenter()
        old_camera = self._camera
        notification_center.discard_observer(self, sender=old_camera)
        old_camera.close()
        new_camera = self._open_camera(device_name, resolution, framerate, attempts=1 if device_name is None else 8)
        notification_center.add_observer(self, sender=new_camera)
        if not self.muted:
            new_camera.start()
        self._camera = new_camera
        notification_center.post_notification('VideoDeviceDidChangeCamera', sender=self, data=NotificationData(old_camera=old_camera, new_camera=new_camera))

    @property
    def producer(self):
        return self._camera

    @property
    def name(self):
        return self._camera.name

    @property
    def real_name(self):
        return self._camera.real_name

    @property
    def muted(self):
        return self.__dict__.get('muted', False)

    @muted.setter
    def muted(self, value):
        if not isinstance(value, bool):
            raise ValueError('illegal value for muted property: %r' % (value,))
        if value == self.muted:
            return
        if value:
            self._camera.stop()
        else:
            self._camera.start()
        self.__dict__['muted'] = value

    def handle_notification(self, notification):
        handler = getattr(self, '_NH_%s' % notification.name, Null)
        handler(notification)

    def _NH_VideoCameraDidStop(self, notification):
        # the capture ended by itself (a screen share stopped from the system's menu bar, a camera
        # gone): no more frames come from this device, the application chooses another one
        if notification.sender is not self._camera:
            return
        NotificationCenter().post_notification('VideoDeviceDidStop', sender=self, data=NotificationData(name=notification.data.name,
                                                                                                           real_name=notification.data.real_name,
                                                                                                           reason=notification.data.reason,
                                                                                                           user_stopped=notification.data.user_stopped))
