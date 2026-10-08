#!/usr/bin/env python3
"""Verify the checked-in native translator and its declared source provenance."""
import hashlib
import json
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[1]
PINNED_LICENSES = {
    'dawn': ('50c9f7b4ee3fef0bdc9166056098271ea85ef9fc',
             '0493f897193af1796d5054659f45ec7d4c5af648fa67a99f01d30e55cc805abc'),
    'abseil-cpp': ('dd67f5ca84f65ebb88ac0ea0fe2c1d58663e519f',
                   'c79a7fea0e3cac04cd43f20e7b648e5a0ff8fa5344e644b0ee09ca1162b62747'),
    'spirv-headers': ('0d25db97cb9b8f725e4c95e4553001710e7fc39d',
                      'ea43b1de38a6f90c488800d66dec1ed671e68cda530266bc96951fb5b6307613'),
}

def verify(root=ROOT):
    manifest = json.loads((root / 'Artifacts/translator.json').read_text())
    spec = json.loads((root / 'tools/tint/dawn.json').read_text())
    if manifest.get('schemaVersion') != 1 or manifest.get('dawnCommit') != spec['dawn']['commit']:
        raise RuntimeError('translator artifact source does not match Dawn specification')
    dependencies = [{'repository': d['repository'], 'commit': d['commit']} for d in spec['dependencies']]
    if manifest.get('dependencies') != dependencies:
        raise RuntimeError('translator artifact dependency provenance differs')
    expected_inputs = {'tools/build-tint.py', 'tools/tint/dawn.json', 'tools/tint/CMakeLists.txt',
                       'Sources/CNoisemakerTint/NoisemakerTint.cpp',
                       'Sources/CNoisemakerTint/include/NoisemakerTint.h'}
    if set(manifest.get('inputs', {})) != expected_inputs:
        raise RuntimeError('translator build input inventory differs')
    for name, digest in manifest['inputs'].items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'translator build input differs: {name}; rebuild the artifact')
    artifact = root / 'Artifacts/CNoisemakerTint.xcframework'
    actual = {str(p.relative_to(artifact)) for p in artifact.rglob('*') if p.is_file()}
    if any(p.is_symlink() for p in artifact.rglob('*')):
        raise RuntimeError('translator artifact must not contain symlinks')
    if actual != set(manifest['files']):
        raise RuntimeError('translator artifact inventory differs')
    for name, digest in manifest['files'].items():
        content = (artifact / name).read_bytes()
        if hashlib.sha256(content).hexdigest() != digest:
            raise RuntimeError(f'translator artifact hash differs: {name}')
        if b'/Users/' in content or b'/private/var/folders/' in content:
            raise RuntimeError(f'translator artifact contains private build paths: {name}')
    info = plistlib.loads((artifact / 'Info.plist').read_bytes())
    libraries = info.get('AvailableLibraries', [])
    if len(libraries) != 1 or libraries[0]['SupportedPlatform'] != 'macos' or libraries[0]['SupportedArchitectures'] != ['arm64']:
        raise RuntimeError('unexpected qualified translator platform inventory')
    header = artifact / 'macos-arm64/Headers/NoisemakerTint.h'
    if header.read_bytes() != (root / 'Sources/CNoisemakerTint/include/NoisemakerTint.h').read_bytes():
        raise RuntimeError('translator public ABI header differs from source')
    if not (root / 'LICENSE').is_file():
        raise RuntimeError('missing package license')
    pinned_commits = {'dawn': spec['dawn']['commit']}
    pinned_commits.update({d['path'].split('/')[1]: d['commit'] for d in spec['dependencies']})
    for name, (commit, digest) in PINNED_LICENSES.items():
        if pinned_commits.get(name) != commit:
            raise RuntimeError(f'dependency license provenance differs: {name}')
        notice = root / f'tools/tint/LICENSE-{name}.txt'
        if not notice.is_file():
            raise RuntimeError(f'missing dependency license: {name}')
        if hashlib.sha256(notice.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'dependency license differs from pinned source: {name}')
    return {'platform': 'macos-arm64', 'files': len(actual), 'dawn': manifest['dawnCommit'],
            'archiveBytes': (artifact / 'macos-arm64/libCNoisemakerTint.a').stat().st_size}

if __name__ == '__main__':
    print(json.dumps(verify(), sort_keys=True))
