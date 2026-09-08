#!/usr/bin/python3
"""Select receiver identity, interface, and the local control group."""

import argparse
import grp
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, '/usr/lib/syren-rtp')
from common import atomic_json, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--address', required=True)
    parser.add_argument('--snapclient-id', required=True)
    parser.add_argument('--control-group', default='syren-audio')
    parser.add_argument('--control-user', required=True)
    parser.add_argument('--snapserver-host')
    parser.add_argument('--snapserver-port', type=int, default=1704)
    arguments = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run sudo in this visible terminal; the app never collects passwords')
    address = str(ipaddress.IPv4Address(arguments.address))
    if address == '0.0.0.0':
        parser.error('Select one receiving interface address')
    if not re.fullmatch('[a-z_][a-z0-9_-]{0,31}', arguments.control_group):
        parser.error('Invalid control group name')
    if not re.fullmatch('[a-z_][a-z0-9_-]{0,31}', arguments.control_user):
        parser.error('Invalid control user name')
    if not 1 <= len(arguments.snapclient_id) <= 256:
        parser.error('Invalid discovered Snapclient identity')
    run(['/usr/bin/python3', '/usr/lib/syren-rtp/receiver.py', 'drain'], timeout=65)
    try:
        grp.getgrnam(arguments.control_group)
    except KeyError:
        run(['groupadd', '--system', arguments.control_group])
    for username in (arguments.control_user, 'syren-rtp'):
        run(['usermod', '-a', '-G', arguments.control_group, username])
    atomic_json(Path('/etc/syrensystem/receiver.json'), {
        'snapserver_host': arguments.snapserver_host, 'snapserver_port': arguments.snapserver_port,
        'control_group': arguments.control_group, 'bind_address': address,
        'snapclient_id': arguments.snapclient_id,
        'device': 'hw:sndrpihifiberry,0',
        'hardware_path': '/proc/asound/sndrpihifiberry/pcm0p/sub0/hw_params',
    })
    override = Path('/etc/systemd/system/syren-rtp-broker.socket.d/group.conf')
    override.parent.mkdir(parents=True, exist_ok=True)
    override.write_text('[Socket]\nSocketGroup=' + arguments.control_group + '\n')
    run(['systemctl', 'stop', 'syren-rtp-broker.service', 'syren-rtp-broker.socket'])
    run(['systemctl', 'daemon-reload'])
    Path('/var/lib/syren-rtp/disabled').unlink(missing_ok=True)
    run(['systemctl', 'enable', '--now', 'syren-rtp-broker.socket'])
    print('Receiver configured. Log in again for control group access. Playback remains stopped.')


if __name__ == '__main__':
    main()
