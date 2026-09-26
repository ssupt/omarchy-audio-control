#!/usr/bin/env python3
"""Load a packaged update in one QML engine through Omarchy's real registry.

Pass a previous candidate to test two authentic backend builds, including an
interrupted update. Without it, test a source UI -> packaged UI transition.
All clients, files, audio sockets and the compositor are private to this test.
"""
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
CANDIDATE = Path(sys.argv[1]).resolve()
PREVIOUS = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
SHELL = Path(os.environ.get('AUDIO_TEST_OMARCHY_SHELL', '/usr/share/omarchy/shell'))
WESTON = os.environ.get('AUDIO_TEST_WESTON') or shutil.which('weston')
assert SHELL.is_dir() and WESTON and shutil.which('quickshell'), 'Omarchy and Weston are required'


def until(predicate, timeout=10):
    deadline = time.monotonic()+timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError('Upgrade condition exceeded its deadline')


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


with tempfile.TemporaryDirectory(prefix='audio-upgrade-') as temporary:
    work = Path(temporary)
    plugins = work/'plugins'
    plugin = plugins/'plugin with spaces'
    plugin.mkdir(parents=True)
    candidate_info = json.loads((CANDIDATE/'backend-release.json').read_text())
    legacy = bool(PREVIOUS) and not json.loads((PREVIOUS/'manifest.json').read_text())['entryPoints'].get('service')
    previous_info = None if legacy else json.loads((PREVIOUS/'backend-release.json').read_text()) if PREVIOUS else candidate_info
    if PREVIOUS and not legacy:
        assert previous_info['buildId'] != candidate_info['buildId'], 'Supply two different backend builds'

    def install(source, retain_binary=False):
        # Replace individual files, including a running executable via rename,
        # while keeping the plugin directory and its URLs unchanged.
        names = set()
        for path in source.rglob('*'):
            relative = path.relative_to(source)
            if any(part in ('.git', 'target', '__pycache__', 'artifacts') for part in relative.parts):
                continue
            if not path.is_file():
                continue
            names.add(relative)
            if retain_binary and relative == Path('bin/omarchy-audio-service'):
                continue
            destination = plugin/relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            replacement = destination.with_name('.'+destination.name+'.incoming')
            shutil.copy2(path, replacement)
            replacement.replace(destination)
        for path in list(plugin.rglob('*')):
            if path.is_file() and path.relative_to(plugin) not in names:
                path.unlink()

    install(PREVIOUS or CANDIDATE)
    if not PREVIOUS:
        # Load the source URLs first, so the engine holds cached versions
        # before the manifest begins pointing to build-specific component URLs.
        shutil.copy2(CANDIDATE/'packaging/manifest.json', plugin/'manifest.json')
    config = work/'config/omarchy'
    config.mkdir(parents=True)
    preferences = config/'audio-preferences.json'
    original = '{"version":1,"bluetoothProfilePreference":"quality","externalField":"preserve"}\n'
    preferences.write_text(original)
    for name, value in {
        'audio-control.json': {'outputOverdrive': False, 'captureNotifications': False, 'externalField': 'preserve'},
        'audio-rules.json': {'version': 1, 'appRules': [], 'outputGroups': [],
            'devices': {'aliases': {'missing-output': 'Existing alias'}, 'favorites': ['missing-output'], 'hidden': []},
            'externalField': 'preserve'},
        'audio-scenes.json': {'version': 1, 'scenes': [], 'externalField': 'preserve'},
    }.items():
        (config/name).write_text(json.dumps(value)+'\n')
    original_documents = {path.name: path.read_bytes() for path in config.glob('audio-*.json')}
    env = dict(os.environ, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
               PIPEWIRE_REMOTE='absent-upgrade-server', PULSE_SERVER='unix:'+str(work/'absent-pulse'),
               XDG_CONFIG_HOME=str(work/'config'), XDG_STATE_HOME=str(work/'state'),
               XDG_CACHE_HOME=str(work/'cache'), AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary,
               QT_QPA_PLATFORM='wayland', QT_QUICK_BACKEND='software', WAYLAND_DISPLAY='upgrade-wayland')
    for key in ('OMARCHY_AUDIO_HELPERS_DIR', 'OMARCHY_AUDIO_CONTROL_FILE', 'OMARCHY_AUDIO_PREFERENCES_FILE',
                'OMARCHY_AUDIO_RULES_FILE', 'OMARCHY_AUDIO_SCENES_FILE', 'LISTEN_PID', 'LISTEN_FDS',
                'HYPRLAND_INSTANCE_SIGNATURE'):
        env.pop(key, None)
    env.update(DBUS_SESSION_BUS_ADDRESS='unix:path='+str(work/'bus'), NO_AT_BRIDGE='1', QT_NO_XDG_DESKTOP_PORTAL='1')
    bus_config = work/'bus.conf'
    bus_config.write_text('<busconfig><type>session</type><listen>unix:path='+str(work/'bus')+'</listen>'
        '<auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/>'
        '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    for name in ('services', 'Ui', 'Commons'):
        (work/name).symlink_to(SHELL/name, target_is_directory=True)
    qml = work/'shell.qml'
    qml.write_text((ROOT/'test/fixtures/upgrade.qml').read_text().replace('PLUGINS_DIRECTORY', json.dumps(str(plugins))))
    log = (work/'shell.log').open('w+')
    processes = []
    daemons = {}

    def ipc(method):
        result = subprocess.run(['quickshell', 'ipc', '-p', str(qml), 'call', 'upgrade', method],
                                env=env, capture_output=True, text=True, timeout=3)
        if result.returncode:
            return None
        if method != 'status':
            return True
        try:
            status = json.loads(result.stdout)
        except ValueError:
            return None
        assert not status['error'], status
        info = status.get('info')
        if info and info['pid'] not in daemons:
            daemons[info['pid']] = os.pidfd_open(info['pid'])
        return status

    def ready(build_id):
        status = ipc('status')
        matching = status and (status['info'] and status['info']['buildId'] == build_id if build_id else status['info'] is None)
        return status if status and status['ready'] and status['surfaces'] == 2 and matching else None

    try:
        bus = subprocess.Popen(['dbus-daemon', '--nofork', '--config-file='+str(bus_config)],
                               env=env, stdout=log, stderr=log)
        processes.append(bus)
        until(lambda: (work/'bus').exists())
        compositor = subprocess.Popen([WESTON, '--backend=headless', '--renderer=pixman',
            '--shell=kiosk-shell.so', '--socket=upgrade-wayland', '--idle-time=0', '--no-config'],
            env=env, stdout=log, stderr=log)
        processes.append(compositor)
        until(lambda: (work/'upgrade-wayland').exists())
        shell = subprocess.Popen(['quickshell', '--no-color', '-p', str(qml)],
                                 env=env, stdout=log, stderr=log)
        processes.append(shell)
        previous_build = previous_info['buildId'] if previous_info else None
        old = until(lambda: ready(previous_build))
        install(CANDIDATE, retain_binary=bool(PREVIOUS) and not legacy)
        assert ipc('rescan')
        if PREVIOUS and not legacy:
            def mismatch():
                state = ipc('status')
                return state and state['mismatches'] > 0 and not state['ready']
            until(mismatch)
            assert preferences.read_text() == original
            replacement = plugin/'bin/.next-backend'
            shutil.copy2(CANDIDATE/'bin/omarchy-audio-service', replacement)
            replacement.replace(plugin/'bin/omarchy-audio-service')
        new = until(lambda: ready(candidate_info['buildId']), timeout=12)
        assert new['pid'] == old['pid'], 'Upgrade restarted the QML engine'
        if PREVIOUS and not legacy:
            assert new['info']['pid'] != old['info']['pid'], 'UI attached to the previous backend'
        assert ipc('disable')
        until(lambda: (status := ipc('status')) and not status['ready'])
        assert ipc('enable')
        again = until(lambda: ready(candidate_info['buildId']))
        assert again['info']['epoch'] == new['info']['epoch'], 'Re-enable lost the shared daemon'
        if PREVIOUS:
            assert ipc('disable')
            if legacy:
                # Older direct QML controls must not overlap a draining Rust
                # coordinator during rollback, even in a private fixture.
                fd = daemons[new['info']['pid']]
                until(lambda: select.select([fd], [], [], 0)[0], timeout=36)
            install(PREVIOUS)
            revision = ipc('status')['registryRevision']
            assert ipc('rescan')
            until(lambda: (state := ipc('status')) and not state['scanning'] and state['registryRevision'] > revision)
            assert ipc('enable')
            rolled_back = until(lambda: ready(previous_build))
            assert rolled_back['pid'] == old['pid'], 'Rollback restarted the QML engine'
        assert ipc('disable')
        shutil.rmtree(plugin)
        assert ipc('rescan')
        until(lambda: all(select.select([fd], [], [], 0)[0] for fd in daemons.values()), timeout=36)
        assert not list((work/'omarchy-audio-control').glob('*.sock'))
        assert all((config/name).read_bytes() == content for name, content in original_documents.items())
        assert ipc('quit')
        shell.wait(timeout=5)
        log.flush()
        log.seek(0)
        output = log.read()
        assert not any(error in output for error in ('ReferenceError:', 'TypeError:', 'Binding loop')), output[-10000:]
        print('PASS: one QML engine, real Omarchy registry, packaged update, both surfaces, re-enable, removal and configuration preservation')
        if PREVIOUS and not legacy:
            print('PASS: interrupted two-build update rejects mismatched backend, recovers, and rolls back without restarting the shell')
        if legacy:
            print('PASS: original QML/Bash release upgrades to Rust and rolls back after drain; all four saved documents retain their original bytes')
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-12000:], file=sys.stderr)
        raise
    finally:
        for process in reversed(processes):
            stop(process)
        for fd in daemons.values():
            if not select.select([fd], [], [], 0)[0]:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            os.close(fd)
        log.close()
