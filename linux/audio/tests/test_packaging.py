import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


DIRECTORY = Path(__file__).resolve().parents[1]


class PackageTests(unittest.TestCase):
    def fixture(self, directory, muted):
        helper_directory = directory / 'old-helper'
        helper_directory.mkdir()
        state_directory = directory / 'state'
        state_directory.mkdir()
        state_path = state_directory / 'state.json'
        state_path.write_text(json.dumps({'muted': muted, 'audio_active': True, 'snap_active': False}))
        helper = helper_directory / 'receiver.py'
        helper.write_text('''#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys
state_path = Path(os.environ['FIXTURE_STATE'])
if state_path.exists():
    state = json.loads(state_path.read_text())
    state['muted'] = True
    state['audio_active'] = False
    state_path.write_text(json.dumps(state))
    if os.environ.get('FAIL_RESTORE'):
        sys.exit(1)
    state_path.unlink()
    state_path.with_name('restored.json').write_text(json.dumps(dict(state, snap_active=True)))
''')
        helper.chmod(0o755)
        binary_directory = directory / 'bin'
        binary_directory.mkdir()
        for command in ('systemctl', 'getent', 'id', 'groupadd', 'useradd'):
            executable = binary_directory / command
            executable.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FIXTURE_COMMANDS"\n')
            executable.chmod(0o755)
        script = directory / 'maintenance'
        script.write_text((DIRECTORY / 'packaging/receiver-maintenance').read_text()
                          .replace('/usr/lib/syren-rtp', str(helper_directory))
                          .replace('/var/lib/syren-rtp', str(state_directory))
                          .replace('/etc/syrensystem', str(directory / 'configuration')))
        environment = dict(os.environ, PATH=str(binary_directory) + ':' + os.environ['PATH'],
                           FIXTURE_STATE=str(state_path), FIXTURE_COMMANDS=str(directory / 'commands'))
        return script, state_path, helper, environment

    def test_upgrade_and_removal_drain_muted_and_audible_sessions(self):
        for muted in (False, True):
            for action in ('preinst', 'prerm'):
                with self.subTest(muted=muted, action=action), tempfile.TemporaryDirectory() as temporary:
                    script, state_path, helper, environment = self.fixture(Path(temporary), muted)
                    subprocess.run(['sh', str(script), action], check=True, env=environment)
                    self.assertTrue(helper.exists())
                    self.assertFalse(state_path.exists())
                    restored = json.loads(state_path.with_name('restored.json').read_text())
                    self.assertTrue(restored['muted'])
                    self.assertFalse(restored['audio_active'])
                    self.assertTrue(restored['snap_active'])

    def test_interrupted_restoration_aborts_package_action_and_retries(self):
        for muted in (False, True):
            with self.subTest(muted=muted), tempfile.TemporaryDirectory() as temporary:
                script, state_path, helper, environment = self.fixture(Path(temporary), muted)
                result = subprocess.run(['sh', str(script), 'prerm'], env=dict(environment, FAIL_RESTORE='1'))
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(helper.exists())
                self.assertTrue(state_path.exists())
                self.assertTrue(json.loads(state_path.read_text())['muted'])
                subprocess.run(['sh', str(script), 'prerm'], env=environment, check=True)
                self.assertFalse(state_path.exists())

    def test_installation_and_postinst_never_start_audio(self):
        with tempfile.TemporaryDirectory() as temporary:
            script, state_path, helper, environment = self.fixture(Path(temporary), True)
            subprocess.run(['sh', str(script), 'preinst'], env=environment, check=True)
            configuration = Path(temporary) / 'configuration'
            configuration.mkdir()
            (configuration / 'receiver.json').write_text('{}')
            subprocess.run(['sh', str(script), 'postinst'], env=environment, check=True)
            commands = Path(environment['FIXTURE_COMMANDS']).read_text()
            self.assertNotIn('start syren-rtp-audio', commands)
            self.assertIn('enable --now syren-rtp-broker.socket', commands)

    def test_receiver_package_contains_only_runtime_helpers(self):
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run(['sh', str(DIRECTORY / 'packaging/build-receiver-deb.sh'), temporary],
                           check=True, stdout=subprocess.DEVNULL)
            package = Path(temporary) / 'syren-rtp-receiver_1.1.2_all.deb'
            listing = subprocess.check_output(['dpkg-deb', '-c', str(package)], text=True)
            for filename in ('receiver.py', 'worker.py', 'shared_graph.py', 'shared-receiver.conf.in', 'pulse.conf', 'ingress.py', 'compatibility.json', 'syren-rtp-broker.socket'):
                self.assertIn(filename, listing)
            for filename in ('capture.py', 'measure.py', 'results/', 'laptop.py', '__pycache__'):
                self.assertNotIn(filename, listing)

    def test_upgrade_preinst_reactivates_socket_for_legacy_drain(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            script, state_path, helper, environment = self.fixture(directory, False)
            configuration = directory / 'configuration'
            configuration.mkdir()
            (configuration / 'receiver.json').write_text('{}')
            socket_path = directory / 'broker.socket'
            socket_path.touch()
            environment['FIXTURE_SOCKET'] = str(socket_path)
            helper.write_text(helper.read_text().replace("state_path = Path(os.environ['FIXTURE_STATE'])",
                "if not Path(os.environ['FIXTURE_SOCKET']).exists(): sys.exit(1)\nstate_path = Path(os.environ['FIXTURE_STATE'])"))
            systemctl = directory / 'bin/systemctl'
            systemctl.write_text('#!/bin/sh\ncase "$1" in\nstart) touch "$FIXTURE_SOCKET" ;;\nstop) rm -f "$FIXTURE_SOCKET" ;;\nesac\n')
            systemctl.chmod(0o755)
            maintenance = helper.parent / 'maintenance'
            maintenance.write_text(script.read_text())
            maintenance.chmod(0o755)
            subprocess.run(['sh', str(script), 'prerm'], env=environment, check=True)
            self.assertFalse(socket_path.exists())
            self.assertNotEqual(subprocess.run([str(maintenance), 'preinst'], env=environment).returncode, 0)
            subprocess.run(['sh', str(DIRECTORY / 'packaging/build-receiver-deb.sh'), temporary],
                           check=True, stdout=subprocess.DEVNULL)
            controls = directory / 'controls'
            subprocess.run(['dpkg-deb', '-e', str(directory / 'syren-rtp-receiver_1.1.2_all.deb'), str(controls)], check=True)
            preinst = controls / 'preinst'
            preinst.write_text(preinst.read_text().replace('/usr/lib/syren-rtp', str(helper.parent))
                               .replace('/etc/syrensystem', str(configuration)))
            subprocess.run(['sh', str(preinst)], env=environment, check=True)
            self.assertFalse(socket_path.exists())
            self.assertFalse(state_path.exists())

    def test_laptop_package_failure_keeps_the_disabled_old_helper(self):
        specification = importlib.util.spec_from_file_location('maintenance', DIRECTORY / 'packaging/laptop-maintenance.py')
        maintenance = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(maintenance)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            helper = directory / 'helper/laptop.py'
            helper.parent.mkdir()
            helper.write_text('old helper')
            journal = directory / 'home/.local/state/syrensystem/rtp/state.json'
            journal.parent.mkdir(parents=True)
            journal.write_text('{}')
            runtime = directory / 'runtime/1000'
            runtime.mkdir(parents=True)
            account = SimpleNamespace(pw_uid=1000, pw_name='listener', pw_dir=str(directory / 'home'))
            def paths(value):
                return {'/usr/lib/syrensystem/rtp/laptop.py': helper,
                        '/run/user': runtime.parent}.get(value, Path(value))
            with patch.object(maintenance, 'Path', side_effect=paths), patch.object(maintenance.pwd, 'getpwall', return_value=[account]), patch.object(maintenance.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'drain')):
                with self.assertRaises(subprocess.CalledProcessError):
                    maintenance.main()
            self.assertTrue(helper.exists())
            self.assertTrue(helper.with_name('disabled').exists())
            self.assertTrue(journal.exists())


if __name__ == '__main__':
    unittest.main()
