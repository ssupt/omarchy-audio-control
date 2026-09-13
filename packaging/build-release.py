#!/usr/bin/env python3
"""Prepare a self-contained Omarchy checkout; never install or publish it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def source_id(root):
    names = ['backend/Cargo.toml', 'backend/Cargo.lock', 'backend/build.rs',
             'packaging/manifest.json', 'packaging/build-release.py']
    for directory in ('qml', 'backend/src', 'scripts'):
        paths = ((root / directory).rglob('*') if directory != 'scripts'
                 else (root / directory).iterdir())
        for path in paths:
            if not path.is_file():
                continue
            if (directory in ('qml', 'backend/src')
                    or (directory == 'scripts' and path.name != 'audio-rust-backend')):
                names.append(path.relative_to(root).as_posix())
    digest = hashlib.sha256()
    for name in sorted(names):
        content = (root / name).read_bytes()
        digest.update(name.encode() + b'\0' + str(len(content)).encode() + b'\0' + content)
    return digest.hexdigest()


def inspect(binary):
    return json.loads(subprocess.check_output([str(binary), '--build-info'], text=True, timeout=5))


def runtime_files(root, build_id):
    files = {path.relative_to(root).as_posix(): path.read_bytes()
             for path in (root/'qml').rglob('*') if path.is_file()}
    paths_module = 'qml/core/ReleasePaths.js'
    package_root = os.path.relpath('.', Path('runtime')/build_id/Path(paths_module).parent) + '/'
    files[paths_module] = (f'// Generated release paths; edit the qml sources instead.\n'
                          f'var root = "{package_root}"\nvar buildId = "{build_id}"\n').encode()
    return files


def release_manifest(root, build_id):
    manifest = json.loads((root/'packaging/manifest.json').read_text())
    for kind, name in manifest['entryPoints'].items():
        if (not isinstance(name, str) or not name.startswith('qml/')
                or not name.endswith('.qml') or '\\' in name
                or any(part in ('', '.', '..') for part in name.split('/'))):
            raise ValueError('Source entry points must name a relative QML file under qml/')
        if not (root/name).is_file():
            raise ValueError(f'Missing source entry point: {name}')
        manifest['entryPoints'][kind] = f'runtime/{build_id}/{name}'
    return manifest


def write_runtime(root, build_id):
    bundle = root/'runtime'/build_id
    bundle.mkdir(parents=True)
    for name, content in runtime_files(root, build_id).items():
        destination = bundle/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
    (root/'manifest.json').write_text(json.dumps(release_manifest(root, build_id), indent=2)+'\n')


def verify(root):
    binary = root / 'bin/omarchy-audio-service'
    metadata = json.loads((root / 'backend-release.json').read_text())
    if hashlib.sha256(binary.read_bytes()).hexdigest() != metadata['sha256']:
        raise ValueError('Backend checksum does not match the release metadata')
    info = inspect(binary)
    if info['buildId'] != source_id(root) or metadata['buildId'] != info['buildId']:
        raise ValueError('Backend does not match the plugin sources; rebuild the release')
    if info['target'] != 'x86_64-unknown-linux-gnu' or metadata['target'] != info['target']:
        raise ValueError('This release targets Omarchy on x86_64 Linux')
    if any(metadata.get(key) != info.get(key) for key in ('version', 'protocolVersion')):
        raise ValueError('Backend version metadata does not match the executable')
    if not os.access(binary, os.X_OK):
        raise ValueError('Backend is not executable')
    for path in root.rglob('*'):
        if path.is_symlink():
            raise ValueError(f'Release contains a symlink: {path}')
    build_id = info['buildId']
    if json.loads((root/'manifest.json').read_text()) != release_manifest(root, build_id):
        raise ValueError('Manifest does not point to the matching generated QML release')
    expected = {f'{build_id}/{name}': content for name, content in runtime_files(root, build_id).items()}
    actual = {path.relative_to(root/'runtime').as_posix(): path.read_bytes()
              for path in (root/'runtime').rglob('*') if path.is_file()}
    if actual != expected:
        raise ValueError('Generated QML release differs from its sources; rebuild the release')
    return metadata


def build(output, binary=None):
    output = output.resolve()
    if output.exists():
        raise ValueError('Output already exists; choose a fresh release directory')
    if ROOT == output or ROOT in output.parents:
        raise ValueError('Build outside the source checkout to avoid a partial live plugin update')
    if binary is None:
        command = ['cargo', 'build', '--locked', '--release', '--manifest-path', str(ROOT/'backend/Cargo.toml'),
                   '--message-format=json-render-diagnostics']
        result = subprocess.run(command, check=True, stdout=subprocess.PIPE, text=True)
        artifacts = [item['executable'] for line in result.stdout.splitlines()
                     if (item := json.loads(line)).get('reason') == 'compiler-artifact'
                     and item.get('executable') and item['target']['name'] == 'omarchy-audio-service']
        if len(artifacts) != 1:
            raise ValueError('Cargo did not identify exactly one backend artifact')
        binary = Path(artifacts[0])
    binary = binary.resolve()
    info = inspect(binary)
    if info['buildId'] != source_id(ROOT):
        raise ValueError('Supplied binary was built from different plugin sources')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.audio-release-', dir=output.parent) as temporary:
        stage = Path(temporary) / 'plugin'
        stage.mkdir()
        for path in ROOT.iterdir():
            if path.is_file() and (path.suffix in ('.md', '.json', '.png', '.jpg', '.webp')
                                   or path.name in ('LICENSE', '.gitignore')):
                if path.name != 'backend-release.json':
                    shutil.copy2(path, stage / path.name)
        for name in ('qml', 'backend', 'scripts', 'packaging', 'test', '.github'):
            shutil.copytree(ROOT/name, stage/name,
                            ignore=shutil.ignore_patterns('target', '__pycache__', '*.pyc'))
        (stage/'bin').mkdir()
        shutil.copy2(binary, stage/'bin/omarchy-audio-service')
        (stage/'bin/omarchy-audio-service').chmod(0o755)
        metadata = dict(info, sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
        (stage/'backend-release.json').write_text(json.dumps(metadata, indent=2)+'\n')
        write_runtime(stage, info['buildId'])
        verify(stage)
        stage.rename(output)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--check', type=Path)
    args = parser.parse_args()
    try:
        if args.check and not args.output and not args.binary:
            print(json.dumps(verify(args.check.resolve()), indent=2))
        elif args.output and not args.check:
            print(build(args.output, args.binary))
        else:
            parser.error('Use --output DIRECTORY [--binary EXECUTABLE] or --check DIRECTORY')
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Release preparation failed: {error}\n')
