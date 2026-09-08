#!/usr/bin/python3
"""Finish each user's restoration before replacing laptop helpers."""

import os
import json
from pathlib import Path
import pwd
import subprocess
import sys


def main():
    helper = Path('/usr/lib/syrensystem/rtp/laptop.py')
    if not helper.exists():
        return
    disabled = helper.with_name('disabled')
    disabled.touch(mode=0o644)
    for account in pwd.getpwall():
        if account.pw_uid < 1000 or account.pw_uid == 65534:
            continue
        location = Path(account.pw_dir) / '.local/state/syrensystem/rtp-location.json'
        saved = json.loads(location.read_text()) if location.exists() else {}
        runtime = Path(saved['runtime']) if 'runtime' in saved else Path('/run/user') / str(account.pw_uid)
        state_home = Path(saved.get('state_home', str(Path(account.pw_dir) / '.local/state')))
        config_home = Path(saved.get('config_home', str(Path(account.pw_dir) / '.config')))
        journal = state_home / 'syrensystem/rtp/state.json'
        if not journal.exists() and not (runtime / 'syren-rtp-controller/control.sock').exists():
            continue
        if not runtime.is_dir():
            raise RuntimeError(f'Package action aborted: log in as {account.pw_name} and reconcile pending RTP recovery first')
        subprocess.run(['runuser', '-u', account.pw_name, '--', 'env',
                        'XDG_RUNTIME_DIR=' + str(runtime),
                        'XDG_STATE_HOME=' + str(state_home), 'XDG_CONFIG_HOME=' + str(config_home),
                        '/usr/bin/python3', str(helper), '{"version":1,"action":"drain"}'],
                       check=True, timeout=65)


if __name__ == '__main__':
    main()
