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
    assert not (first/'helpers').exists()
    assert (first/'omarchy-audio-service').stat().st_mode & 0o777 == 0o755
    config = stage / '.config/omarchy/audio-control.json'
    config.write_text('{"version":1,"outputOverdrive":false}')
    env['AUDIO_STAGE_ACTIVE']='1'
    run('install','--binary',str(binary))
    second = (libexec/'current').resolve()
    assert second != first and first.exists(), 'Upgrade did not retain the previous release'
    assert not (second/'helpers').exists()
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
    # User edits made after installation are retained on uninstall.
    assert unit.read_text() == original_unit

    # Finding 8: preserve 0700 modes on existing config and systemd user directories.
    # Finding 2: preserve a pre-existing custom unit across install, upgrade, and uninstall.
    custom_stage = pathlib.Path(temporary) / 'custom home'
    omarchy_dir = custom_stage / '.config/omarchy'
    systemd_dir = custom_stage / '.config/systemd/user'
    omarchy_dir.mkdir(parents=True)
    systemd_dir.mkdir(parents=True)
    omarchy_dir.chmod(0o700)
    systemd_dir.chmod(0o700)
    custom_service = systemd_dir / 'omarchy-audio-control.service'
    custom_contents = '[Unit]\nDescription=User custom audio backend\n[Service]\nExecStart=/usr/local/bin/custom-audio\n'
    custom_service.write_text(custom_contents)
    custom_service.chmod(0o600)
    env.pop('AUDIO_STAGE_FAIL_RESTART', None)
    env.pop('AUDIO_STAGE_ACTIVE', None)
    def run_custom(action, *args):
        return subprocess.run([str(installer), action, '--stage', str(custom_stage), *args],
                              check=True, capture_output=True, text=True, env=env)
    # Uninstalling before any installation must never touch an unowned user unit.
    run_custom('uninstall')
    assert custom_service.read_text() == custom_contents
    run_custom('install', '--binary', str(binary))
    assert (omarchy_dir.stat().st_mode & 0o777) == 0o700, 'Installer widened ~/.config/omarchy permissions'
    assert (systemd_dir.stat().st_mode & 0o777) == 0o700, 'Installer widened ~/.config/systemd/user permissions'
    assert custom_service.read_text() != custom_contents
    env['AUDIO_STAGE_ACTIVE'] = '1'
    run_custom('install', '--binary', str(binary))
    assert (omarchy_dir.stat().st_mode & 0o777) == 0o700
    assert (systemd_dir.stat().st_mode & 0o777) == 0o700
    run_custom('uninstall')
    assert not (custom_stage / '.local/libexec/omarchy-audio-control').exists()
    assert custom_service.read_text() == custom_contents, 'Uninstall did not restore pre-existing custom service unit'
    assert (custom_service.stat().st_mode & 0o777) == 0o600
    assert not (systemd_dir / 'omarchy-audio-control.socket').exists()

    # Later user edits to an installed unit must be retained across upgrades and uninstall.
    env.pop('AUDIO_STAGE_ACTIVE', None)
    run_custom('install', '--binary', str(binary))
    edited_contents = custom_service.read_text() + '\n# Later user edit\n'
    custom_service.write_text(edited_contents)
    env['AUDIO_STAGE_ACTIVE'] = '1'
    run_custom('install', '--binary', str(binary))
    assert custom_service.read_text() == edited_contents, 'Upgrade overwrote user edits to installed unit'
    run_custom('uninstall')
    assert custom_service.read_text() == edited_contents, 'Uninstall overwrote later user edits'

    # Rollback on a fresh install over a pre-existing active custom service must restore and restart it.
    rollback_stage = pathlib.Path(temporary) / 'active-custom'
    rollback_systemd = rollback_stage / '.config/systemd/user'
    rollback_systemd.mkdir(parents=True)
    rollback_service = rollback_systemd / 'omarchy-audio-control.service'
    rollback_service.write_text(custom_contents)
    rollback_log = pathlib.Path(temporary) / 'rollback-manager.log'
    rollback_env = dict(env, AUDIO_STAGE_LOG=str(rollback_log), AUDIO_STAGE_ACTIVE='1',
                        AUDIO_STAGE_FAIL_RESTART='1')
    try:
        subprocess.run([str(installer), 'install', '--stage', str(rollback_stage) + '///',
                        '--binary', str(binary)], check=True, capture_output=True, text=True, env=rollback_env)
        raise AssertionError('Expected failed activation on pre-existing active custom service')
    except subprocess.CalledProcessError as error:
        assert 'previous installation was restored' in error.stderr
    assert rollback_service.read_text() == custom_contents
    assert not (rollback_systemd / 'omarchy-audio-control.socket').exists()
    assert not (rollback_stage / '.local/libexec/omarchy-audio-control/unit-state').exists()
    assert rollback_log.read_text().splitlines().count('restart omarchy-audio-control.service') == 2

    # Legacy pre-unit-state installations must cleanly remove unmodified shipped units on uninstall,
    # and succeed even if the socket file was manually removed beforehand.
    legacy_stage = pathlib.Path(temporary) / 'legacy-install'
    legacy_systemd = legacy_stage / '.config/systemd/user'
    legacy_rel = legacy_stage / '.local/libexec/omarchy-audio-control/releases/release.legacy'
    legacy_systemd.mkdir(parents=True)
    legacy_rel.mkdir(parents=True)
    (legacy_rel / '.audio-control-release').touch()
    (legacy_stage / '.local/libexec/omarchy-audio-control/current').symlink_to('releases/release.legacy')
    shutil.copy2(root / 'packaging/systemd/omarchy-audio-control.service',
                 legacy_systemd / 'omarchy-audio-control.service')
    shutil.copy2(root / 'packaging/systemd/omarchy-audio-control.socket',
                 legacy_systemd / 'omarchy-audio-control.socket')
    legacy_env = dict(env)
    legacy_env.pop('AUDIO_STAGE_FAIL_RESTART', None)
    legacy_env.pop('AUDIO_STAGE_ACTIVE', None)
    subprocess.run([str(installer), 'uninstall', '--stage', str(legacy_stage)],
                   check=True, capture_output=True, text=True, env=legacy_env)
    assert not (legacy_systemd / 'omarchy-audio-control.service').exists(), 'Legacy uninstall left service unit behind'
    assert not (legacy_systemd / 'omarchy-audio-control.socket').exists(), 'Legacy uninstall left socket unit behind'
    assert not (legacy_stage / '.local/libexec/omarchy-audio-control').exists()

    # Uninstalling after the socket unit was manually removed must still clean up the service and libexec.
    run_custom('install', '--binary', str(binary))
    (systemd_dir / 'omarchy-audio-control.socket').unlink()
    strict_manager = pathlib.Path(temporary) / 'strict-manager'
    strict_manager.write_text('''#!/usr/bin/env python3
import pathlib, sys
if sys.argv[1] == 'disable' and not (pathlib.Path(sys.argv[-1]).is_absolute()):
    raise SystemExit(1)
''')
    strict_manager.chmod(0o755)
    strict_env = dict(env, AUDIO_BACKEND_STAGE_SYSTEMCTL=str(strict_manager))
    strict_env.pop('AUDIO_STAGE_FAIL_RESTART', None)
    strict_env.pop('AUDIO_STAGE_ACTIVE', None)
    subprocess.run([str(installer), 'uninstall', '--stage', str(custom_stage)],
                   check=True, capture_output=True, text=True, env=strict_env)
    assert not (custom_stage / '.local/libexec/omarchy-audio-control').exists()
    assert custom_service.read_text() == edited_contents

    # Early rejection on a symlinked user unit must not leak releases or create unit-state.
    sym_stage = pathlib.Path(temporary) / 'symlink-unit'
    sym_systemd = sym_stage / '.config/systemd/user'
    sym_systemd.mkdir(parents=True)
    (sym_stage / 'real.service').write_text(custom_contents)
    (sym_systemd / 'omarchy-audio-control.service').symlink_to(sym_stage / 'real.service')
    sym_res = subprocess.run([str(installer), 'install', '--stage', str(sym_stage), '--binary', str(binary)],
                             capture_output=True, text=True, env=legacy_env)
    assert sym_res.returncode != 0
    assert not (sym_stage / '.local/libexec/omarchy-audio-control').exists(), 'Early rejection leaked libexec/unit-state'

    # Reject path-traversal --stage values like /..
    bad_stage = subprocess.run([str(installer), 'install', '--stage', '/..', '--binary', str(binary)],
                               capture_output=True, text=True, env=legacy_env)
    assert bad_stage.returncode == 2

    # Fresh install failing during mv before daemon-reload must not invoke disable/stop on unloaded units
    # and must clean up the staged release directory when rollback succeeds.
    fresh_stage = pathlib.Path(temporary) / 'fresh-mv-fail'
    fresh_log = pathlib.Path(temporary) / 'fresh-manager.log'
    strict_fresh = pathlib.Path(temporary) / 'strict-fresh-manager'
    strict_fresh.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
with pathlib.Path(os.environ['AUDIO_STAGE_LOG']).open('a') as stream:
    stream.write(' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1] in ('is-active', 'is-enabled'):
    raise SystemExit(3)
if sys.argv[1] in ('disable', 'stop'):
    raise SystemExit(1)
''')
    strict_fresh.chmod(0o755)
    fresh_marker = fresh_log.with_suffix('.move-failed')
    if fresh_marker.exists():
        fresh_marker.unlink()
    fresh_env = dict(os.environ,
                     AUDIO_BACKEND_STAGE_SYSTEMCTL=str(strict_fresh),
                     AUDIO_STAGE_LOG=str(fresh_log),
                     AUDIO_STAGE_REAL_MV=real_mv,
                     PATH=str(fault_bin) + os.pathsep + os.environ['PATH'])
    fresh_res = subprocess.run([str(installer), 'install', '--stage', str(fresh_stage), '--binary', str(binary)],
                               capture_output=True, text=True, env=fresh_env)
    assert fresh_res.returncode != 0
    assert 'previous installation was restored' in fresh_res.stderr, fresh_res.stderr
    assert not (fresh_stage / '.local/libexec/omarchy-audio-control').exists(), 'Clean fresh rollback leaked release dir'

    # Validate staged unit files with systemd-analyze when available.
    if shutil.which('systemd-analyze'):
        verify_stage = pathlib.Path(temporary) / 'verify home'
        verify_runtime = pathlib.Path(temporary) / 'verify-runtime'
        verify_runtime.mkdir(mode=0o700)
        verify_env = dict(os.environ,
                          HOME=str(verify_stage),
                          XDG_CONFIG_HOME=str(verify_stage / '.config'),
                          XDG_RUNTIME_DIR=str(verify_runtime),
                          AUDIO_BACKEND_STAGE_SYSTEMCTL=str(manager),
                          AUDIO_STAGE_LOG=temporary + '/verify-manager.log')
        subprocess.run([str(installer), 'install', '--stage', str(verify_stage), '--binary', str(binary)],
                       check=True, capture_output=True, text=True, env=verify_env)
        subprocess.run([
            'systemd-analyze', '--user', '--man=no', 'verify',
            str(verify_stage / '.config/systemd/user/omarchy-audio-control.service'),
            str(verify_stage / '.config/systemd/user/omarchy-audio-control.socket'),
        ], check=True, capture_output=True, text=True, env=verify_env)
print('PASS: staged installation, active upgrade, rollback, directory modes, custom unit restoration, legacy uninstall, and user edit retention')
