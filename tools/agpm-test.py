#!/usr/bin/env python3
"""Test the AG Podcast Mixer link (docs/PodcastMixerLink.md) without AG CuteMusic.

    agpm-test.py                 act as AG CuteMusic's mixer: hold mixer.lock, send a stereo tone (440 Hz left,
                                 660 Hz right) into to-call, record what Blink plays (from-call) to a WAV file
    agpm-test.py --list          start the SIP engine and list its sound devices: "AG Podcast Mixer" is there
                                 while another agpm-test.py (or AG CuteMusic) runs

Then, in Blink, choose AG Podcast Mixer as the input and output device and call someone: they hear the tone,
and what they say ends up in the WAV file.
"""

import argparse
import math
import os
import struct
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agpm  # noqa: E402


def tone_quantum(start, frames, level=0.25):
    """frames of 440 Hz left, 660 Hz right, from frame start."""
    amplitude = int(32767 * level)
    samples = []
    for i in range(start, start + frames):
        t = i / agpm.RATE
        samples.append(int(amplitude * math.sin(2 * math.pi * 440 * t)))
        samples.append(int(amplitude * math.sin(2 * math.pi * 660 * t)))
    return struct.pack('<%dh' % len(samples), *samples)


def fake_mixer(record):
    agpm.create_rings()
    lock = agpm.MixerLock()
    if not lock.acquire():
        sys.exit('Another AG CuteMusic mixer (or agpm-test.py) runs: %s is locked' % agpm.path('mixer.lock'))
    to_call = agpm.Ring('to-call.ring')
    from_call = agpm.Ring('from-call.ring')
    to_call.writer_attach()
    from_call.reader_sync()
    output = wave.open(record, 'wb')
    output.setnchannels(agpm.CHANNELS)
    output.setsampwidth(2)
    output.setframerate(agpm.RATE)
    print('AG Podcast Mixer link in %s: sending a tone (440 Hz left, 660 Hz right), recording Blink to %s' % (agpm.link_dir(), record))
    print('Ctrl-C to stop')

    period = agpm.QUANTUM / agpm.RATE
    sent = received = dropped = 0
    started = next_report = time.monotonic()
    try:
        while True:
            # keep two quanta ahead of real time
            due = int((time.monotonic() - started) / period) + 2
            while sent < due * agpm.QUANTUM:
                if not to_call.write(tone_quantum(sent, agpm.QUANTUM)):
                    dropped += agpm.QUANTUM     # Blink is not reading (no call): the ring is full
                sent += agpm.QUANTUM
            data = from_call.read(from_call.capacity)
            if data:
                output.writeframes(data)
                received += len(data) // agpm.FRAME_BYTES
            now = time.monotonic()
            if now >= next_report:
                next_report = now + 1
                # one short line, rewritten in place (a line wider than the terminal wraps instead)
                print('\r%4.0fs sent %6.1fs, untaken %6.1fs, from Blink %6.1fs ' % (
                    now - started, sent / agpm.RATE, dropped / agpm.RATE, received / agpm.RATE), end='', flush=True)
            time.sleep(period / 2)
    except KeyboardInterrupt:
        print()
    finally:
        output.close()
        to_call.close()
        from_call.close()
        lock.release()


def list_devices():
    from sipsimple.core import Engine
    engine = Engine()
    engine.start(codecs=[], video_codecs=[])
    for _ in range(100):
        if engine.is_running:
            break
        time.sleep(0.1)
    try:
        print('Link directory: %s' % engine.podcast_mixer_dir)
        print('AG CuteMusic mixer running: %s' % engine.podcast_mixer_available)
        engine.refresh_sound_devices()
        print('Input devices:  %s' % ', '.join(engine.input_devices))
        print('Output devices: %s' % ', '.join(engine.output_devices))
        print('%s %s' % (engine.podcast_mixer_device, 'is listed' if engine.podcast_mixer_device in engine.input_devices else 'is not listed'))
    finally:
        engine.stop()
        engine.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--list', action='store_true', help='list the SIP engine sound devices')
    parser.add_argument('--record', default='agpm-from-call.wav', help='where to record what Blink plays (default %(default)s)')
    args = parser.parse_args()
    if args.list:
        list_devices()
    else:
        fake_mixer(args.record)


if __name__ == '__main__':
    main()
