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


def verify_raster(root=ROOT):
    spec = json.loads((root / 'tools/raster.json').read_text())
    manifest = json.loads((root / 'Artifacts/raster.json').read_text())
    if manifest.get('schemaVersion') != 1 or manifest.get('skiaRevision') != spec['skiaRevision'] or \
            manifest.get('chromiumTag') != spec['chromiumTag'] or \
            manifest.get('pinnedArchiveSha256') != spec['archiveSha256'] or \
            manifest.get('sourceTreeSha256') != spec['sourceTreeSha256'] or \
            manifest.get('gnSha256') != spec['gnSha256'] or \
            manifest.get('licenseSha256') != spec['licenseSha256'] or \
            manifest.get('sourceFileCount') != 12288:
        raise RuntimeError('raster artifact source provenance differs from pin')
    oracle = json.loads((root / 'parity/overlays/oracle.json').read_text())
    lock = json.loads((root / 'parity/reference.json').read_text())
    if oracle.get('authority') != {key: lock[key] for key in
                                   ('repository', 'commit', 'sourceManifestSha256')} or \
            spec['chromiumTag'] not in oracle.get('browser', ''):
        raise RuntimeError('raster overlay oracle authority or browser differs from source lock')
    inputs = {'tools/build-raster.py', 'tools/raster.json',
              'Sources/CNoisemakerRaster/NoisemakerRaster.cpp',
              'Sources/CNoisemakerRaster/include/NoisemakerRaster.h',
              'tools/raster-api-test.cpp', 'tools/raster-smoke.cpp',
              'parity/grade-overlays.py', 'parity/reference.json',
              'parity/overlays/oracle.json'}
    for case in oracle['cases']:
        inputs.update({f"parity/overlays/{case['file']}",
                       f"parity/overlays/{case['segmentFile']}"})
    if set(manifest.get('inputs', {})) != inputs:
        raise RuntimeError('raster build input inventory differs')
    for name, expected in manifest['inputs'].items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'raster build input differs: {name}; rebuild the artifact')
    artifact = root / 'Artifacts/CNoisemakerRaster.xcframework'
    actual = {str(path.relative_to(artifact)) for path in artifact.rglob('*') if path.is_file()}
    if any(path.is_symlink() for path in artifact.rglob('*')):
        raise RuntimeError('raster artifact must not contain symlinks')
    if actual != set(manifest.get('files', {})):
        raise RuntimeError('raster artifact inventory differs')
    for name, expected in manifest['files'].items():
        content = (artifact / name).read_bytes()
        if hashlib.sha256(content).hexdigest() != expected:
            raise RuntimeError(f'raster artifact hash differs: {name}')
        if b'/Users/' in content or b'/private/var/folders/' in content:
            raise RuntimeError(f'raster artifact contains private build paths: {name}')
    license_copy = root / 'tools/raster/LICENSE-skia.txt'
    if hashlib.sha256(license_copy.read_bytes()).hexdigest() != spec['licenseSha256'] or \
            license_copy.read_bytes() != (artifact / 'LICENSE-skia.txt').read_bytes():
        raise RuntimeError('raster license differs from pinned Skia source')
    info = plistlib.loads((artifact / 'Info.plist').read_bytes())
    libraries = info.get('AvailableLibraries', [])
    if len(libraries) != 1 or libraries[0].get('SupportedPlatform') != 'macos' or \
            libraries[0].get('SupportedArchitectures') != ['arm64'] or \
            libraries[0].get('LibraryPath') != 'libCNoisemakerRaster.a':
        raise RuntimeError('unexpected qualified raster platform inventory')
    header = artifact / 'macos-arm64/Headers/NoisemakerRaster.h'
    if header.read_bytes() != (root / 'Sources/CNoisemakerRaster/include/NoisemakerRaster.h').read_bytes():
        raise RuntimeError('raster public ABI header differs from source')
    return {'platform': 'macos-arm64', 'files': len(actual),
            'skia': manifest['skiaRevision'],
            'archiveBytes': (artifact / 'macos-arm64/libCNoisemakerRaster.a').stat().st_size}

if __name__ == '__main__':
    print(json.dumps({'translator': verify(), 'raster': verify_raster()}, sort_keys=True))
