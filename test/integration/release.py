#!/usr/bin/env python3
"""Verify complete release assembly and reject stale or damaged artifacts."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('audio_release', root/'packaging/build-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
binary = Path(sys.argv[1]).resolve()


def rejected(check, message):
    try:
        check()
    except (ValueError, OSError):
        return
    raise AssertionError(message)


with tempfile.TemporaryDirectory(prefix='audio-release-test-') as temporary:
    candidate = release.build(Path(temporary)/'plugin with spaces', binary)
    assert not (candidate/'docs').exists(), 'Development documentation was included in the package'
    assert not list(candidate.glob('*.qml')) and not list(candidate.glob('*.js')), 'UI files leaked into the package root'
    metadata = release.verify(candidate)
    assert metadata['buildId'] == release.source_id(root)
    nested_source = candidate/'backend/src/service/microphone.rs'
    original_source = nested_source.read_bytes()
    nested_source.write_bytes(original_source + b'\n// Changed microphone supervision\n')
    rejected(lambda: release.verify(candidate), 'Modified nested Rust source was accepted')
    nested_source.write_bytes(original_source)
    nested_extra = candidate/'backend/src/service/unexpected.rs'
    nested_extra.write_text('// Added after the backend was built\n')
    rejected(lambda: release.verify(candidate), 'Added nested Rust source was accepted')
    nested_extra.unlink()
    executable = candidate/'bin/omarchy-audio-service'
    original = executable.read_bytes()
    executable.write_bytes(b'broken executable')
    rejected(lambda: release.verify(candidate), 'Corrupt binary was accepted')
    executable.write_bytes(original)
    source = candidate/'qml/core/Service.qml'
    source.write_text(source.read_text()+'\n// Changed after the backend was built\n')
    rejected(lambda: release.verify(candidate), 'Stale backend was accepted with modified QML')
    source.write_bytes((root/'qml/core/Service.qml').read_bytes())
    for name in ('qml/components/AudioDropdown.qml', 'qml/core/Model.js'):
        nested_qml = candidate/name
        original_qml = nested_qml.read_bytes()
        nested_qml.write_bytes(original_qml + b'\n// Changed nested UI dependency\n')
        rejected(lambda: release.verify(candidate), 'Modified nested QML/JavaScript source was accepted')
        nested_qml.write_bytes(original_qml)
    manifest_path = candidate/'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    bundled_source = candidate/manifest['entryPoints']['service']
    bundled_source.write_text(bundled_source.read_text()+'\n// Modified generated code\n')
    rejected(lambda: release.verify(candidate), 'Modified generated QML was accepted')
    bundled_source.write_bytes((root/'qml/core/Service.qml').read_bytes())
    manifest_path.write_text(json.dumps(dict(manifest, entryPoints={'service': 'qml/core/Service.qml'})))
    rejected(lambda: release.verify(candidate), 'A manifest bypassing the release directory was accepted')
    manifest_path.write_text(json.dumps(manifest))
    extra = bundled_source.parent/'Unexpected.qml'
    extra.write_text('import QtQuick\nItem {}\n')
    rejected(lambda: release.verify(candidate), 'Unexpected generated QML was accepted')
    extra.unlink()
    source_manifest = candidate/'packaging/manifest.json'
    original_manifest = source_manifest.read_text()
    for entry in ('../Service.qml', 'qml/../Service.qml', 'qml//core/Service.qml', '/qml/core/Service.qml'):
        value = json.loads(original_manifest)
        value['entryPoints']['service'] = entry
        source_manifest.write_text(json.dumps(value))
        rejected(lambda: release.release_manifest(candidate, metadata['buildId']), 'Invalid source entry-point path was accepted')
    source_manifest.write_text(original_manifest)
    executable.chmod(0o644)
    rejected(lambda: release.verify(candidate), 'Non-executable backend was accepted')
    executable.chmod(0o755)
    link = candidate/'unexpected-link'
    link.symlink_to(candidate/'README.md')
    rejected(lambda: release.verify(candidate), 'A release symlink was accepted')
    link.unlink()
    release.verify(candidate)
    rejected(lambda: release.build(candidate, binary), 'Release assembly overwrote an existing candidate')
print('PASS: complete release assembly, nested source/binary identity, checksums, executable permissions, and symlink rejection')
