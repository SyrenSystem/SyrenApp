#!/usr/bin/env python3
"""Run the audio regression gate and retain each command's evidence."""

import argparse
import datetime
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scope', choices=['app', 'all', 'signal'], default='all')
    parser.add_argument('--server', type=Path)
    arguments = parser.parse_args()
    application = Path(__file__).resolve().parents[1]
    server = arguments.server or application.parent / 'SyrenServer'
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    output = application / 'build/audio-gate' / timestamp
    output.mkdir(parents=True)
    commands = []
    if arguments.scope in ('app', 'all'):
        commands.extend([
            ('flutter', application, ['flutter', 'test', '--reporter', 'expanded']),
            ('analysis', application, ['flutter', 'analyze', '--no-pub']),
            ('receiver', application, ['python3', '-m', 'unittest', 'discover', '-s', 'linux/audio/tests', '-v']),
            ('measurement', application, ['python3', '-m', 'unittest', 'discover', '-s', 'linux/experiments/rtp/tests', '-v']),
            ('routing', application, ['sh', 'linux/packaging/tests/test-audio-control.sh']),
        ])
    if arguments.scope == 'all':
        command = ['dotnet', 'test', '--configuration', 'Release']
        if not shutil.which('dotnet') and shutil.which('podman'):
            command = ['podman', 'run', '--rm', '--userns=keep-id', '-v', f'{server.resolve()}:/workspace',
                       '-w', '/workspace', 'mcr.microsoft.com/dotnet/sdk:10.0', *command]
        commands.append(('server', server, command))
    if arguments.scope in ('signal', 'all'):
        commands.append(('signal', application, ['python3', 'linux/audio/tests/smoke_shared.py']))
    results = []
    for name, directory, command in commands:
        print(f'Running {name} gate', flush=True)
        started = time.monotonic()
        log = output / f'{name}.log'
        with log.open('w') as stream:
            try:
                result = subprocess.run(command, cwd=directory, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=600)
                exit_code = result.returncode
            except (OSError, subprocess.TimeoutExpired) as error:
                stream.write(str(error) + '\n')
                exit_code = 1
        results.append({'check': name, 'command': command, 'exit_code': exit_code,
                        'seconds': round(time.monotonic() - started, 2), 'log': str(log)})
        print(f'{name}: {"PASS" if exit_code == 0 else "FAIL"} ({log})', flush=True)
    revisions = {}
    for name, directory in [('app', application), ('server', server)]:
        if not directory.is_dir():
            continue
        revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=directory,
                                  capture_output=True, text=True)
        changes = subprocess.run(['git', 'status', '--porcelain'], cwd=directory,
                                 capture_output=True, text=True)
        revisions[name] = {'commit': revision.stdout.strip(), 'changes': changes.stdout.splitlines()}
    passed = all(result['exit_code'] == 0 for result in results)
    report = output / 'report.json'
    report.write_text(json.dumps({'passed': passed, 'scope': arguments.scope,
                                 'revisions': revisions, 'checks': results}, indent=2) + '\n')
    print(f'Audio gate {"PASS" if passed else "FAIL"}: {report}')
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
