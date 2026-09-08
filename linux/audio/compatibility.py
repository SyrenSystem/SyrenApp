"""Keep compatibility evidence separate from device checks."""

import glob
from pathlib import Path
import re
import shutil

from common import read_json, run


DIRECTORY = Path(__file__).resolve().parent


def classify(version, matrix=None):
    matrix = matrix or read_json(DIRECTORY / 'compatibility.json')
    entry = matrix['versions'].get(version, {'class': 'untested', 'evidence': []})
    classification = entry['class']
    if classification == 'tested' and not entry.get('evidence'):
        classification = 'untested'
    return {'version': version, 'class': classification, 'evidence': entry.get('evidence', [])}


def probe(receiver=False):
    commands = ['pipewire', 'snapclient', 'pw-cli', 'pw-dump', 'pw-link'] if receiver else [
        'pipewire', 'pactl', 'pw-dump', 'ssh', 'ssh-keyscan', 'ssh-keygen', 'systemctl']
    missing = [command for command in commands if not shutil.which(command)]
    version_output = run(['pipewire', '--version']).stdout if 'pipewire' not in missing else ''
    match = re.search(r'Linked with libpipewire (\S+)', version_output)
    compatibility = classify(match[1] if match else 'unknown')
    module_names = ['libpipewire-module-rtp-source' if receiver else 'libpipewire-module-rtp-sink',
                    'libpipewire-module-adapter', 'libpipewire-module-protocol-native']
    modules = {name: bool(glob.glob(f'/usr/lib/*/pipewire-0.3/{name}.so') +
                          glob.glob(f'/usr/lib/pipewire-0.3/{name}.so')) for name in module_names}
    if receiver:
        modules['libpipewire-module-protocol-pulse'] = bool(glob.glob('/usr/lib/*/pipewire-0.3/libpipewire-module-protocol-pulse.so'))
    errors = []
    if missing:
        errors.append('Install missing commands: ' + ', '.join(missing))
    if not all(modules.values()):
        errors.append('Install the distribution libpipewire-0.3-modules package')
    if compatibility['class'] != 'tested':
        errors.append(f"PipeWire {compatibility['version']} is {compatibility['class']}; add transport and configuration probe evidence and regression checks to compatibility.json before enabling")
    return {'compatibility': compatibility, 'modules': modules, 'missing_commands': missing,
            'ready': not errors, 'errors': errors}
