"""Shared protocol, durable files, and bounded commands."""

import contextlib
import contextvars
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import time
import uuid


VERSION = 1
LIMIT = 262144
deadline_context = contextvars.ContextVar('deadline', default=None)
cancel_context = contextvars.ContextVar('cancel', default=None)


@contextlib.contextmanager
def deadline(seconds, cancel=None):
    deadline_token = deadline_context.set(time.monotonic() + seconds)
    cancel_token = cancel_context.set(cancel)
    try:
        yield
    finally:
        deadline_context.reset(deadline_token)
        cancel_context.reset(cancel_token)


def remaining(timeout):
    cancel = cancel_context.get()
    if cancel and cancel.is_set():
        raise RuntimeError('Operation cancelled')
    expires = deadline_context.get()
    if expires is not None:
        timeout = min(timeout, expires - time.monotonic())
    if timeout <= 0:
        raise TimeoutError('Operation deadline expired; recovery is required')
    return timeout


def run(arguments, timeout=5, check=True, **options):
    expires = time.monotonic() + remaining(timeout)
    with subprocess.Popen(arguments, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **options) as process:
        try:
            while True:
                remaining(expires - time.monotonic())
                try:
                    output, errors = process.communicate(timeout=min(0.05, expires - time.monotonic()))
                    break
                except subprocess.TimeoutExpired:
                    pass
        except BaseException:
            process.kill()
            process.communicate(timeout=1)
            raise
        result = subprocess.CompletedProcess(arguments, process.returncode, output, errors)
        if check:
            result.check_returncode()
        return result


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, 'w') as output:
            json.dump(value, output, indent=2)
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(path)
        sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def remove_journal(path):
    path.unlink(missing_ok=True)
    sync_directory(path.parent)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def receive(connection):
    data = bytearray()
    while len(data) < LIMIT:
        chunk = connection.recv(1)
        if not chunk:
            raise EOFError('Control connection closed')
        if chunk == b'\n':
            value = json.loads(data)
            if not isinstance(value, dict):
                raise ValueError('A JSON object is required')
            return value
        data.extend(chunk)
    raise ValueError('Control message is too large')


def send(connection, value):
    connection.sendall((json.dumps(value, separators=(',', ':')) + '\n').encode())


def exchange(path, request, timeout=5, check=True):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(remaining(timeout))
        connection.connect(str(path))
        send(connection, request)
        response = receive(connection)
    if check and response.get('error'):
        raise RuntimeError(response['error'])
    return response


def peer_credentials(connection):
    return struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))


def validate_version(request):
    if (type(request.get('version')) is not int or request.get('version') != VERSION) and request.get('action') not in ('stop', 'status', 'close'):
        raise ValueError('Protocol major version mismatch; update both packages')


def process_identity(process_id):
    try:
        content = Path(f'/proc/{int(process_id)}/stat').read_text().rsplit(')', 1)[1].split()
        if content[0] == 'Z':
            return None
        return [int(process_id), content[19], Path('/proc/sys/kernel/random/boot_id').read_text().strip()]
    except (OSError, ValueError):
        return None


def process_alive(identity):
    return bool(identity and process_identity(identity[0]) == identity)
