#!/usr/bin/env python3
"""Install/upgrade/remove a complete release without touching user services."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
binary = pathlib.Path(sys.argv[1]).resolve()
installer = root / 'scripts/audio-rust-backend'
with tempfile.TemporaryDirectory(prefix='audio-packaging-') as temporary:
    stage = pathlib.Path(temporary) / 'home with spaces'
    manager = pathlib.Path(temporary)/'manager'
    manager.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
log=pathlib.Path(os.environ['AUDIO_STAGE_LOG'])
with log.open('a') as stream: stream.write(' '.join(sys.argv[1:])+'\\n')
if sys.argv[1]=='is-active': raise SystemExit(0 if os.environ.get('AUDIO_STAGE_ACTIVE')=='1' else 3)
marker=log.with_suffix('.failed')
if sys.argv[1]=='restart' and os.environ.get('AUDIO_STAGE_FAIL_RESTART')=='1' and not marker.exists():
    marker.touch()
    raise SystemExit(1)
''')
    manager.chmod(0o755)
    env=dict(os.environ,AUDIO_BACKEND_STAGE_SYSTEMCTL=str(manager),AUDIO_STAGE_LOG=temporary+'/manager.log')
    def run(action, *args):
        return subprocess.run([str(installer),action,'--stage',str(stage),*args],check=True,capture_output=True,text=True,env=env)
    run('install','--binary',str(binary))
    libexec = stage / '.local/libexec/omarchy-audio-control'
    first = (libexec / 'current').resolve()
    assert (first/'omarchy-audio-service').read_bytes() == binary.read_bytes()
    assert (first/'helpers/.audio-common').is_file()
    assert (first/'helpers/audio-input-set-default').is_file()
    assert (first/'omarchy-audio-service').stat().st_mode & 0o777 == 0o755
    config = stage / '.config/omarchy/audio-control.json'
    config.write_text('{"version":1,"outputOverdrive":false}')
    env['AUDIO_STAGE_ACTIVE']='1'
    run('install','--binary',str(binary))
    second = (libexec/'current').resolve()
    assert second != first and first.exists(), 'Upgrade did not retain the previous release'
    assert (second/'helpers/.audio-common').read_bytes() == (first/'helpers/.audio-common').read_bytes()
    assert subprocess.check_output([str(second/'omarchy-audio-service'),'--version']).strip()
    assert 'restart omarchy-audio-control.service' in pathlib.Path(env['AUDIO_STAGE_LOG']).read_text()
    unit = stage/'.config/systemd/user/omarchy-audio-control.service'
    original_unit = unit.read_text()+'\n# Prior installed unit preserved during rollback\n'
    unit.write_text(original_unit)
    # Fail the second unit replacement after the first has already changed.
    # The wrapper fails once so the real filesystem remains usable for rollback.
    fault_bin = pathlib.Path(temporary) / 'fault-bin'
    fault_bin.mkdir()
    real_mv = shutil.which('mv')
    assert real_mv
    fake_mv = fault_bin / 'mv'
    fake_mv.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
marker = pathlib.Path(os.environ['AUDIO_STAGE_LOG']).with_suffix('.move-failed')
if sys.argv[-1].endswith('/omarchy-audio-control.socket') and not marker.exists():
    marker.touch()
    raise SystemExit(1)
os.execv(os.environ['AUDIO_STAGE_REAL_MV'], ['mv', *sys.argv[1:]])
''')
    fake_mv.chmod(0o755)
    env['AUDIO_STAGE_REAL_MV'] = real_mv
    env['PATH'] = str(fault_bin) + os.pathsep + os.environ['PATH']
    try:
        run('install', '--binary', str(binary))
        raise AssertionError('A failed unit replacement reported success')
    except subprocess.CalledProcessError as error:
        assert 'previous installation was restored' in error.stderr
    assert (libexec/'current').resolve() == second
    assert unit.read_text() == original_unit
    assert not list(unit.parent.glob('.audio-backend.*'))
    env['PATH'] = os.environ['PATH']
    env['AUDIO_STAGE_FAIL_RESTART']='1'
    try:
        run('install','--binary',str(binary))
        raise AssertionError('A failed activation reported success')
    except subprocess.CalledProcessError:
        pass
    assert (libexec/'current').resolve() == second
    assert unit.read_text() == original_unit
    run('uninstall')
    assert not libexec.exists()
    assert config.read_text() == '{"version":1,"outputOverdrive":false}'
    assert not (stage/'.config/systemd/user/omarchy-audio-control.socket').exists()
print('PASS: staged installation, active upgrade, filesystem/activation rollback, and removal preserve user configuration')
