#!/usr/bin/env python3
"""Render hostile labels in the real QML components without fetching their images."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
from threading import Thread

ROOT = Path(__file__).resolve().parents[2]
SHELL = Path(os.environ.get('AUDIO_TEST_OMARCHY_SHELL', '/usr/share/omarchy/shell'))
IMAGE = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM8sAAAAASUVORK5CYII=')


class Requests(BaseHTTPRequestHandler):
    paths = []

    def do_GET(self):
        self.paths.append(self.path)
        self.send_response(200)
        self.send_header('Content-Type', 'image/png')
        self.end_headers()
        self.wfile.write(IMAGE)

    def log_message(self, *_args):
        pass


assert all((SHELL/name).is_dir() for name in ('Ui', 'Commons')), 'Set AUDIO_TEST_OMARCHY_SHELL to an Omarchy shell checkout'
with ThreadingHTTPServer(('127.0.0.1', 0), Requests) as server:
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='audio-text-rendering-') as temporary:
            work = Path(temporary)
            for name in ('Ui', 'Commons'):
                (work/name).symlink_to(SHELL/name, target_is_directory=True)
            source = (ROOT/'test/fixtures/TextRenderingHarness.qml').read_text()
            source = source.replace('ROOT_URL', json.dumps(ROOT.as_uri()+'/'))
            source = source.replace('SERVER_URL', json.dumps(f'http://127.0.0.1:{server.server_port}'))
            fixture = work/'shell.qml'
            fixture.write_text(source)
            env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software',
                       XDG_RUNTIME_DIR=temporary, XDG_CONFIG_HOME=str(work/'config'),
                       XDG_STATE_HOME=str(work/'state'), XDG_CACHE_HOME=str(work/'cache'),
                       DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(work/'absent-bus'))
            for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'QT_QPA_PLATFORMTHEME'):
                env.pop(name, None)
            result = subprocess.run(['quickshell', '--no-color', '-p', str(fixture)],
                                    env=env, capture_output=True, text=True, timeout=10)
            output = result.stdout+result.stderr
            assert result.returncode == 0 and 'TEXT_RENDERING_READY' in output, output
            assert not any(error in output for error in ('TypeError:', 'ReferenceError:')), output
            assert '/control' in Requests.paths, 'The AutoText network control did not fetch its image: '+output
            unexpected = [path for path in Requests.paths if path != '/control']
            assert not unexpected, f'Label markup triggered image requests: {unexpected}'
    finally:
        server.shutdown()
        thread.join()
print('PASS: hostile labels remain literal and make no image requests')
