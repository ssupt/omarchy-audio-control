#!/usr/bin/env python3
"""Prepare a backend for this CPU without changing the installed plugin."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

TARGETS = {
    'x86_64': ('x86_64-unknown-linux-gnu', 62),
    'aarch64': ('aarch64-unknown-linux-gnu', 183),
}


def release_tools(root):
    spec = importlib.util.spec_from_file_location('audio_release', root/'packaging/build-release.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def matches(binary, target, machine, build_id, tools, cached=False):
    try:
        descriptor = os.open(binary, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                return False
            if cached and (metadata.st_uid != os.getuid() or metadata.st_nlink != 1
                           or metadata.st_mode & 0o022):
                return False
            header = stream.read(20)
        # Never execute a foreign ELF (including via binfmt/QEMU).
        if (len(header) != 20 or header[:6] != b'\x7fELF\x02\x01'
                or struct.unpack_from('<H', header, 18)[0] != machine
                or not os.access(binary, os.X_OK)):
            return False
        info = tools.inspect(binary)
        return (isinstance(info, dict) and info.get('buildId') == build_id and info.get('target') == target
                and info.get('protocolVersion') == 1)
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def cache_directory(path, parents=False):
    path.mkdir(parents=parents, exist_ok=True, mode=0o700)
    metadata = path.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o022):
        raise ValueError('Native audio cache directory must be owned by this user '
                         'and not writable by other users')


def prepare(root, machine=None, cache_home=None):
    machine = platform.machine() if machine is None else machine
    if platform.system() != 'Linux' or machine not in TARGETS:
        raise ValueError(f'Unsupported audio backend platform: {platform.system()} {machine}')
    target, elf_machine = TARGETS[machine]
    tools = release_tools(root)
    build_id = tools.source_id(root)
    bundled = root/'bin/omarchy-audio-service'
    if matches(bundled, target, elf_machine, build_id, tools):
        return bundled
    base = Path(cache_home or os.environ.get('XDG_CACHE_HOME') or Path.home()/'.cache')
    if not base.is_absolute():
        raise ValueError('XDG_CACHE_HOME must be an absolute path')
    # Resolve the configured cache home for dotfiles setups, then keep every
    # plugin-owned directory on a trusted, non-redirected path before execution.
    base = base.resolve()
    cache_directory(base, parents=True)
    plugin_cache = base/'omarchy-audio-control'
    cache_directory(plugin_cache)
    cache = plugin_cache/target
    cache_directory(cache)
    cached = cache/build_id/'omarchy-audio-service'
    cache_directory(cached.parent)
    if matches(cached, target, elf_machine, build_id, tools, cached=True):
        return cached
    # A shared Cargo target directory reuses dependencies across UI updates.
    # Serialize preparations and recheck after locking for concurrent panels.
    lock_fd = os.open(cache/'.build.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(lock_fd, 'w') as lock:
        info = os.fstat(lock.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o022):
            raise ValueError('Native audio build lock is not a private regular file')
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if matches(cached, target, elf_machine, build_id, tools, cached=True):
            return cached
        if not shutil.which('cargo'):
            raise ValueError('This CPU needs a native audio backend. Install Rust/Cargo 1.85+, '
                             'libclang, pkg-config, and PipeWire/libpulse development headers, '
                             'then reload the plugin (see README).')
        cache_directory(cache/'target')
        print(f'Building native audio backend for {target}; later launches use the cached build', file=sys.stderr)
        result = subprocess.run([
            'cargo', 'build', '--locked', '--release', '--manifest-path', str(root/'backend/Cargo.toml'),
            '--target', target, '--target-dir', str(cache/'target'),
            '--message-format=json-render-diagnostics',
        ], check=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True)
        artifacts = [Path(item['executable']) for line in result.stdout.splitlines()
                     if (item := json.loads(line)).get('reason') == 'compiler-artifact'
                     and item.get('executable') and item.get('target', {}).get('name') == 'omarchy-audio-service']
        if len(artifacts) != 1 or not matches(artifacts[0], target, elf_machine, build_id, tools):
            raise ValueError('Native backend does not match this plugin release; reload and retry')
        # Do not publish a build if the plugin changed while Cargo was running.
        if tools.source_id(root) != build_id:
            raise ValueError('Plugin updated while building the audio backend; reload and retry')
        with tempfile.NamedTemporaryFile(dir=cached.parent, prefix='.backend-', delete=False) as stage:
            temporary = Path(stage.name)
        try:
            shutil.copyfile(artifacts[0], temporary)
            temporary.chmod(0o755)
            temporary.replace(cached)
        finally:
            temporary.unlink(missing_ok=True)
        return cached


if __name__ == '__main__':
    try:
        root = Path(sys.argv[1]).resolve()
        arguments = sys.argv[2:]
        binary = prepare(root)
        if arguments == ['--prepare']:
            print(binary)
        else:
            os.execv(binary, [str(binary), *arguments])
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'Audio backend preparation failed: {error}', file=sys.stderr)
        raise SystemExit(1)
