#!/usr/bin/env python3
"""Compare two plugin checkouts on private dummy audio; never use live devices.

Requires the current Omarchy UI contract, Weston, PipeWire/Pulse, WirePlumber
and a systemd user manager with readable cgroup v2 accounting. This is an
observational benchmark, not a CI performance threshold or hardware validation.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid

from pipewire_observer import VolumeObserver

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('legacy', type=Path)
parser.add_argument('candidate', type=Path)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--seconds', type=float, default=20)
parser.add_argument('--rounds', type=int, default=2)
parser.add_argument('--samples', type=int, default=40,
                    help='independently observed volume commands per run')
parser.add_argument('--latency-only', action='store_true',
                    help='skip CPU/memory windows and measure server observations only')
args = parser.parse_args()
assert args.seconds >= 1 and args.rounds >= 1 and args.samples >= 2
SHELL = Path(os.environ.get('AUDIO_TEST_OMARCHY_SHELL', '/usr/share/omarchy/shell'))
WESTON = os.environ.get('AUDIO_TEST_WESTON') or shutil.which('weston')
assert SHELL.is_dir() and WESTON


def until(predicate, timeout=12):
    deadline = time.monotonic()+timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError('Benchmark condition timed out')


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def run(plugin, label, iteration):
    with tempfile.TemporaryDirectory(prefix='audio-benchmark-') as temporary:
        work = Path(temporary)
        env = {key: os.environ[key] for key in ('PATH', 'HOME', 'LANG', 'XDG_DATA_DIRS') if key in os.environ}
        env.update(XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary, PIPEWIRE_REMOTE='audio-test',
                   XDG_CONFIG_HOME=str(work/'config'), XDG_STATE_HOME=str(work/'state'),
                   XDG_CACHE_HOME=str(work/'cache'), AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary,
                   PULSE_RUNTIME_PATH=str(work/'pulse'), PULSE_SERVER='unix:'+str(work/'pulse/native'),
                   QT_QPA_PLATFORM='wayland', QT_QUICK_BACKEND='software', WAYLAND_DISPLAY='benchmark-wayland',
                   DBUS_SESSION_BUS_ADDRESS='unix:path='+str(work/'bus'), NO_AT_BRIDGE='1',
                   QT_NO_XDG_DESKTOP_PORTAL='1')
        (work/'pulse').mkdir()
        config = work/'config/omarchy'
        config.mkdir(parents=True)
        (config/'audio-preferences.json').write_text('{"version":1,"bluetoothProfilePreference":"quality"}\n')
        # Use the installed policy profile, which has no ALSA/BlueZ/video monitor
        # features. Restrict configuration lookup to packaged files, not the user.
        env['WIREPLUMBER_CONFIG_DIR'] = '/usr/share/wireplumber'
        log = (work/'run.log').open('w+')
        processes = []
        observer = None
        unit = 'audio-benchmark-'+uuid.uuid4().hex+'.scope'
        helper_log = work/'helper-launches'
        helper_log.touch()
        bash_env = work/'bash-env'
        bash_env.write_text('case "$0" in */scripts/*|*/omarchy-audio-adapters*/*) '
                            'printf "%s\\n" "${0##*/}" >>"$AUDIO_BENCH_HELPER_LOG";; esac\n')
        env['BASH_ENV'] = str(bash_env)
        env['AUDIO_BENCH_HELPER_LOG'] = str(helper_log)
        if os.environ.get('AUDIO_BENCH_DEBUG'):
            env['QT_LOGGING_RULES'] = 'quickshell.service.pipewire.defaults.debug=true;quickshell.service.pipewire.metadata.debug=true'
        bus_config = work/'bus.conf'
        bus_config.write_text('<busconfig><type>session</type><listen>unix:path='+str(work/'bus')+'</listen>'
                              '<auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/>'
                              '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        for name in ('Ui', 'Commons'):
            (work/name).symlink_to(SHELL/name, target_is_directory=True)
        manifest = json.loads((plugin/'manifest.json').read_text())
        qml = work/'shell.qml'
        qml.write_text((ROOT/'test/fixtures/benchmark.qml').read_text()
                       .replace('MANIFEST', json.dumps(manifest)).replace('PLUGIN_URL', json.dumps(plugin.as_uri()+'/')))
        # WirePlumber owns the default metadata here. The native-only fixture
        # supplies its own object, which would otherwise create two objects with
        # the same name and make Pulse and Quickshell select different defaults.
        pipewire_config = work/'pipewire.conf'
        pipewire_config.write_text((ROOT/'test/fixtures/pipewire.conf').read_text().replace(
            '    { factory = metadata args = { metadata.name = default } }\n', ''))

        def launch(command):
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
            processes.append(process)
            return process

        def ipc(method, *arguments):
            result = subprocess.run(['quickshell', 'ipc', '-p', str(qml), 'call', 'benchmark', method,
                                     *map(str, arguments)],
                                    env=env, capture_output=True, text=True, timeout=3)
            if result.returncode:
                return None
            if method not in ('status', 'volume', 'volumeMarker'):
                return True
            try:
                status = json.loads(result.stdout)
            except ValueError:
                return None
            assert not status.get('error'), status
            return status

        def server_latency(node_id):
            nonlocal observer
            observer = VolumeObserver(env, node_id, log)
            baseline = observer.wait(lambda event: len(event['channelVolumes']) == 2)
            target = .3 if abs(baseline['channelVolumes'][0] - .3 ** 3) > .00001 else .5
            # A timestamp/optimistic UI result alone must never pass the probe.
            start = time.monotonic_ns()
            assert ipc('volumeMarker', target)
            try:
                observer.level(target, start, timeout=.2)
            except TimeoutError:
                pass
            else:
                raise AssertionError('Observer accepted a command that was never dispatched')
            samples = []
            for _ in range(args.samples):
                start = time.monotonic_ns()
                request = ipc('volume', target)
                assert request and request['nodeId'] == node_id, request
                observed = observer.level(target, start)
                elapsed = observed['observedAtMs'] - request['sentAtMs']
                assert 0 <= elapsed <= 3000, (request, observed)
                samples.append(dict(request, **observed, latencyMs=elapsed))
                target = .5 if target == .3 else .3
                # Allow the UI's subscription to catch up before another request.
                time.sleep(.05)
            observer.close()
            observer = None
            values = sorted(sample['latencyMs'] for sample in samples)
            summary = {'samples': len(values), 'medianMs': statistics.median(values),
                       'p95Ms': values[(95 * len(values) + 99) // 100 - 1], 'maxMs': max(values)}
            print(label, iteration, 'server-observed volume', json.dumps(summary), flush=True)
            return {'summary': summary, 'samples': samples, 'undispatchedCommandRejected': True}

        def accounting(cgroup):
            cpu = dict(line.split() for line in (cgroup/'cpu.stat').read_text().splitlines())
            pss = 0
            for pid in (cgroup/'cgroup.procs').read_text().splitlines():
                try:
                    lines = (Path('/proc')/pid/'smaps_rollup').read_text().splitlines()
                    pss += int(next(line.split()[1] for line in lines if line.startswith('Pss:')))
                except (OSError, StopIteration):
                    pass
            return int(cpu['usage_usec']), pss

        def measure(cgroup, scenario):
            first_line = len(helper_log.read_text().splitlines())
            cpu_start, _ = accounting(cgroup)
            start = time.monotonic()
            memory = []
            while time.monotonic()-start < args.seconds:
                time.sleep(max(0, min(1, args.seconds-(time.monotonic()-start))))
                memory.append(accounting(cgroup)[1])
            cpu_end, _ = accounting(cgroup)
            elapsed = time.monotonic()-start
            launches = Counter(helper_log.read_text().splitlines()[first_line:])
            result = {'scenario': scenario, 'durationSeconds': round(elapsed, 3),
                      'cpuPercentOneCore': round(100*(cpu_end-cpu_start)/(elapsed*1000000), 3),
                      'medianPssKiB': statistics.median(memory),
                      'helperLaunches': sum(launches.values()), 'helpers': dict(launches)}
            print(label, iteration, json.dumps(result), flush=True)
            return result

        try:
            launch(['dbus-daemon', '--nofork', '--config-file='+str(bus_config)])
            until(lambda: (work/'bus').exists())
            launch(['pipewire', '-c', str(pipewire_config)])
            until(lambda: (work/'audio-test').exists())
            launch(['wireplumber', '--profile', 'policy'])
            launch(['pipewire-pulse'])
            until(lambda: (work/'pulse/native').exists())
            # Explicitly choose only named dummy nodes; failure stops the run.
            for direction, name in (('sink', 'audio_test_output'), ('source', 'audio_test_input')):
                result = subprocess.run(['pactl', 'set-default-'+direction, name], env=env,
                                        capture_output=True, text=True, timeout=5)
                assert result.returncode == 0, result.stderr
                # Dummy nodes have no hardware session item; publish the live
                # default metadata explicitly as well as the configured choice.
                result = subprocess.run(['pw-metadata', '-n', 'default', '0',
                    'default.audio.'+direction, json.dumps({'name': name}), 'Spa:String:JSON'],
                    env=env, capture_output=True, text=True, timeout=5)
                assert result.returncode == 0, result.stderr
            graph = json.loads(subprocess.check_output(['pw-dump'], env=env, text=True, timeout=5))
            nodes = [item['info']['props'].get('node.name', '') for item in graph
                     if item.get('type') == 'PipeWire:Interface:Node']
            assert nodes and all(name.startswith(('audio_test_', 'Audio-Test-')) for name in nodes), nodes
            sink_id = next(item['id'] for item in graph
                           if item.get('info', {}).get('props', {}).get('node.name') == 'audio_test_output')
            launch([WESTON, '--backend=headless', '--renderer=pixman', '--shell=kiosk-shell.so',
                    '--socket=benchmark-wayland', '--idle-time=0', '--no-config'])
            until(lambda: (work/'benchmark-wayland').exists())
            # systemd-run talks to the real user manager; only its scoped child
            # receives the private test environment. Detached daemons retain
            # this cgroup, so CPU includes reaped helpers and the Rust daemon.
            command = ['systemd-run', '--user', '--scope', '--quiet', '--collect', '--unit='+unit,
                       '/usr/bin/env', '-i']+[key+'='+value for key, value in env.items()]
            scoped = subprocess.Popen(command+['quickshell', '--no-color', '-p', str(qml)],
                                      stdout=log, stderr=log)
            processes.append(scoped)
            until(lambda: (status := ipc('status')) and status['pipewireReady'])
            # Publish after all clients have completed their registry barrier.
            # The dummy graph's defaults metadata predates its nodes.
            for direction, name in (('sink', 'audio_test_output'), ('source', 'audio_test_input')):
                subprocess.run(['pw-metadata', '-n', 'default', '0', 'default.audio.'+direction,
                                json.dumps({'name': name}), 'Spa:String:JSON'],
                               env=env, check=True, stdout=subprocess.DEVNULL, timeout=5)
            until(lambda: (status := ipc('status')) and status['ready'])
            group = subprocess.check_output(['systemctl', '--user', 'show', unit, '-p', 'ControlGroup', '--value'], text=True).strip()
            assert group.startswith('/user.slice/'), group
            cgroup = Path('/sys/fs/cgroup')/group.lstrip('/')
            time.sleep(5)
            measurements = [] if args.latency_only else [measure(cgroup, 'idle')]
            assert ipc('open')
            until(lambda: (status := ipc('status')) and status['opened'])
            time.sleep(5)
            latency = []
            if not args.latency_only:
                measurements.append(measure(cgroup, 'advanced-open'))
                assert ipc('latency')
                status = until(lambda: (state := ipc('status')) and state['remaining'] == 0 and len(state['latencies']) == 40 and state)
                latency = status['latencies']
            confirmation = server_latency(sink_id)
            assert ipc('close')
            until(lambda: (status := ipc('status')) and not status['opened'])
            time.sleep(3)
            if not args.latency_only:
                measurements.append(measure(cgroup, 'closed-after-open'))
            assert ipc('quit')
            scoped.wait(timeout=5)
            log.flush(); log.seek(0)
            output = log.read()
            assert not any(error in output for error in ('ReferenceError:', 'TypeError:', 'Binding loop')), output[-10000:]
            return {'label': label, 'round': iteration, 'version': manifest['version'],
                    'buildId': json.loads((plugin/'backend-release.json').read_text())['buildId'] if (plugin/'backend-release.json').exists() else None,
                    'measurements': measurements, 'helpersAcrossRun': dict(Counter(helper_log.read_text().splitlines())),
                    'volumeObservationLatencyMs': latency,
                    'serverObservedVolumeLatency': confirmation}
        except Exception:
            print('Final UI status:', ipc('status'), flush=True)
            graph = json.loads(subprocess.check_output(['pw-dump'], env=env, text=True, timeout=5))
            print('Default metadata:', [item.get('metadata') for item in graph if item.get('props', {}).get('metadata.name') == 'default'], flush=True)
            log.flush(); log.seek(0)
            print(log.read()[-14000:], flush=True)
            raise
        finally:
            if observer:
                observer.close()
            subprocess.run(['systemctl', '--user', 'stop', unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
            for process in reversed(processes):
                stop(process)
            log.close()


results = []
args.output.parent.mkdir(parents=True, exist_ok=True)
for iteration in range(1, args.rounds+1):
    order = [('legacy', args.legacy), ('rust', args.candidate)]
    if iteration % 2 == 0:
        order.reverse()
    for label, plugin in order:
        results.append(run(plugin.resolve(), label, iteration))
        args.output.write_text(json.dumps({'secondsPerScenario': None if args.latency_only else args.seconds,
            'latencyMethod': 'QML dispatch timestamp to independent pw-dump channelVolumes observation; '
                             '1 ms clock resolution, includes observer delivery, no physical audio measurement',
            'runs': results}, indent=2)+'\n')
print('Saved benchmark observations to', args.output)
