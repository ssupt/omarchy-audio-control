#!/usr/bin/env python3
"""Exercise CPU selection, update invalidation, and native-build failures."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('native_backend', ROOT/'packaging/launch-backend.py')
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class NativeBackendTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='audio-native-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)/'plugin with spaces'
        self.root.mkdir()
        self.cache = Path(self.temporary.name)/'cache with spaces'
        self.source = self.root/'source'
        self.source.write_text('release one')
        self.tools = SimpleNamespace(source_id=self.source_id, inspect=self.inspect)
        self.addCleanup(patch.stopall)
        patch.object(launcher, 'release_tools', return_value=self.tools).start()
        patch.object(launcher.platform, 'system', return_value='Linux').start()
        patch.object(launcher.shutil, 'which', return_value='/cargo').start()
        self.cargo = patch.object(launcher.subprocess, 'run', side_effect=self.compile).start()
        self.inspected = []

    def source_id(self, _root):
        return hashlib.sha256(self.source.read_bytes()).hexdigest()

    def write_binary(self, path, machine, build_id=None):
        target, elf_machine = launcher.TARGETS[machine]
        header = bytearray(20)
        header[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', header, 18, elf_machine)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(header + json.dumps({
            'buildId': build_id or self.source_id(self.root),
            'target': target, 'protocolVersion': 1,
        }).encode())
        path.chmod(0o755)

    def inspect(self, path):
        self.inspected.append(path)
        return json.loads(path.read_bytes()[20:])

    def compile(self, command, **kwargs):
        self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
        target = command[command.index('--target')+1]
        machine = next(key for key, value in launcher.TARGETS.items() if value[0] == target)
        directory = Path(command[command.index('--target-dir')+1])
        binary = directory/target/'release/omarchy-audio-service'
        self.write_binary(binary, machine)
        artifact = {'reason': 'compiler-artifact', 'executable': str(binary),
                    'target': {'name': 'omarchy-audio-service'}}
        return SimpleNamespace(stdout=json.dumps(artifact)+'\n')

    def prepare(self, machine='aarch64'):
        return launcher.prepare(self.root, machine=machine, cache_home=self.cache)

    def test_matching_bundle_needs_no_compiler(self):
        binary = self.root/'bin/omarchy-audio-service'
        for machine in launcher.TARGETS:
            self.write_binary(binary, machine)
            with patch.object(launcher.shutil, 'which', return_value=None):
                self.assertEqual(self.prepare(machine), binary)
        self.cargo.assert_not_called()

    def test_foreign_bundle_is_never_executed_and_native_cache_is_reused(self):
        bundled = self.root/'bin/omarchy-audio-service'
        self.write_binary(bundled, 'x86_64')
        original = bundled.read_bytes()
        binary = self.prepare()
        self.assertEqual(self.cargo.call_count, 1)
        self.assertEqual(self.prepare(), binary)
        self.assertEqual(self.cargo.call_count, 1)
        self.assertNotIn(bundled, self.inspected)
        self.assertEqual(bundled.read_bytes(), original)

    def test_plugin_update_rebuilds_for_the_new_identity(self):
        old = self.prepare()
        self.source.write_text('release two with changed QML')
        new = self.prepare()
        self.assertNotEqual(old, new)
        self.assertTrue(old.exists())
        self.assertEqual(self.cargo.call_count, 2)
        self.assertEqual(self.inspect(new)['buildId'], self.source_id(self.root))

    def test_corrupt_cache_is_rebuilt(self):
        binary = self.prepare()
        binary.write_bytes(b'broken')
        self.assertEqual(self.prepare(), binary)
        self.assertEqual(self.cargo.call_count, 2)

    def test_failed_build_publishes_no_executable(self):
        self.cargo.side_effect = subprocess.CalledProcessError(1, ['cargo'])
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()
        self.assertFalse(list(self.cache.glob('**/'+self.source_id(self.root)+'/omarchy-audio-service')))

    def test_missing_compiler_has_an_actionable_error(self):
        with patch.object(launcher.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(ValueError, 'Install Rust/Cargo'):
                self.prepare()

    def test_update_during_build_is_not_published(self):
        build_id = self.source_id(self.root)
        def update(command, **kwargs):
            result = self.compile(command, **kwargs)
            self.source.write_text('updated during cargo build')
            return result
        self.cargo.side_effect = update
        with self.assertRaisesRegex(ValueError, 'updated while building'):
            self.prepare()
        self.assertFalse(list(self.cache.glob('**/'+build_id+'/omarchy-audio-service')))

    def test_unsupported_cpu_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported audio backend platform'):
            self.prepare('riscv64')
        self.cargo.assert_not_called()


if __name__ == '__main__':
    unittest.main()
