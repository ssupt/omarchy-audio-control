"""Observe replacement endpoint mute state during incomplete profile changes."""
import os, shlex, subprocess, sys, tempfile, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
from client import Client
BINARY=Path(sys.argv[1]).resolve()

def until(predicate):
    end=time.monotonic()+10
    while time.monotonic()<end:
        if result:=predicate():return result
        time.sleep(.02)
    raise AssertionError('fixture startup timeout')

for mode in ['source-first', 'sink-first', 'loopback']:
  with tempfile.TemporaryDirectory(prefix='audio-audit-profile-') as temporary:
    work=Path(temporary)
    flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','libpipewire-0.3'],text=True))
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    str(ROOT/'test/fixtures/routed-device.c'),'-o',str(work/'fixture'),*flags],check=True)
    env=dict(os.environ,XDG_RUNTIME_DIR=temporary,PIPEWIRE_RUNTIME_DIR=temporary,PIPEWIRE_REMOTE='audio-test',
             XDG_CONFIG_HOME=str(work/'config'),XDG_STATE_HOME=str(work/'state'),XDG_CACHE_HOME=str(work/'cache'),
             AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary,PULSE_SERVER='unix:'+str(work/'pulse'))
    for key in list(env):
        if key.startswith('OMARCHY_AUDIO_'):env.pop(key)
    procs=[]; client=None
    with (work/'log').open('w+') as log:
      def start(cmd):
        p=subprocess.Popen(cmd,env=env,stdout=log,stderr=log);procs.append(p);return p
      try:
        start(['pipewire','-c',str(ROOT/'test/fixtures/pipewire.conf')]);until(lambda:(work/'audio-test').exists())
        (work/'control').write_text('normal')
        fixture_mode = {'source-first':'--missing-headset-sink',
                        'sink-first':'--missing-headset-source',
                        'loopback':'--loopback'}[mode]
        start([str(work/'fixture'),str(work/'control'),'--profiles','--bluetooth',fixture_mode])
        start([str(BINARY)]);until(lambda:(work/'omarchy-audio-control/backend.sock').exists())
        client=Client(work/'omarchy-audio-control/backend.sock');client.socket.settimeout(15)
        client.request('state.subscribe')
        state=client.wait_state(lambda s:s.get('catalogReady') and len(s.get('ports',[]))==2)
        card=state['profiles'][0]['identity']
        if mode=='loopback':
            assert client.request('profile.set',dict(identity=card,profile='headset'))['outcome']=='applied'
            request=client.send('profile.set',dict(identity=card,profile='HiFi'))
            reply=client.response(request)
            assert reply['result']['outcome']=='applied', reply
            assert any(n['properties'].get('bluez5.loopback')=='true'
                       for n in client.state['nodes'] if n['name']=='audio_test_routed_input')
        else:
            endpoint='audio_test_routed_input' if mode=='source-first' else 'audio_test_routed_output'
            node=next(n for n in state['nodes'] if n['name']==endpoint)
            original_serial=node['serial']
            client.request('node.audio',dict(identity=dict(generation=state['generation'],id=node['id'],serial=node['serial']),patch=dict(muted=True)))
            request=client.send('profile.set',dict(identity=card,profile='headset'))
            started=time.monotonic();last=None;exposure=None;end_exposure=None
            while request not in client.replies:
                client.receive()
                node=next((n for n in client.state['nodes'] if n['name']==endpoint),None)
                value=(node['serial'],node['audio']['muted']) if node else None
                elapsed=time.monotonic()-started
                last=value
                if value and value[0] != original_serial and value[1] is False and exposure is None: exposure=elapsed
                if exposure is not None and value and value[1] is True and end_exposure is None:end_exposure=elapsed
            reply=client.replies[request]
            assert reply['error']['code']=='not_applied', reply
            assert elapsed >= 3, elapsed
            if exposure is not None:
                assert end_exposure is not None and end_exposure-exposure < 1, (mode, exposure, end_exposure)
            assert any(n['name']==endpoint and n['audio']['muted'] is True
                       for n in client.state['nodes']), client.state['nodes']
        print('PASS: profile '+mode)
      finally:
        if client:client.close()
        for p in reversed(procs):
            if p.poll() is None:p.terminate()
            try:p.wait(timeout=8)
            except subprocess.TimeoutExpired:p.kill();p.wait()
