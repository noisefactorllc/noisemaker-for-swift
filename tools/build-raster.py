#!/usr/bin/env python3
"""Build and verify the pinned CPU Skia raster XCFramework for macOS arm64."""

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / 'tools/raster.json').read_text())
WORK = ROOT / '.build/skia'
SOURCE = WORK / 'source'
ARTIFACT = ROOT / 'Artifacts/CNoisemakerRaster.xcframework'
PROVENANCE = ROOT / 'Artifacts/raster.json'
ARGS = '''is_debug = false
is_official_build = true
target_cpu = "arm64"
skia_use_partition_alloc = false
skia_enable_ganesh = false
skia_enable_graphite = false
skia_use_gl = false
skia_use_metal = false
skia_use_harfbuzz = false
skia_use_icu = false
skia_use_expat = false
skia_use_libjpeg_turbo_decode = false
skia_use_libjpeg_turbo_encode = false
skia_use_libpng_decode = false
skia_use_libpng_encode = false
skia_use_libwebp_decode = false
skia_use_libwebp_encode = false
skia_use_wuffs = false
skia_use_zlib = false
skia_use_piex = false
skia_use_perfetto = false
extra_cflags = ["-ffile-prefix-map={SOURCE}=."]
'''


def digest(path):
    with Path(path).open('rb') as file:
        checksum = hashlib.sha256()
        for block in iter(lambda: file.read(1024 * 1024), b''):
            checksum.update(block)
        return checksum.hexdigest()


def run(*args, cwd=None, env=None):
    print('+', *map(str, args), flush=True)
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def source_inventory(archive):
    """Return canonical content and reject paths or links outside the declared tree."""
    files = {}
    entries = []
    link = SPEC['excludedArchiveSymlink']
    with tarfile.open(archive, 'r:gz') as tar:
        for member in tar:
            name = member.name
            path = PurePosixPath(name)
            if not name or path.is_absolute() or '..' in path.parts or str(path) != name:
                raise RuntimeError(f'unsafe archive path: {name}')
            if member.isdir():
                continue
            if member.issym() and name == link:
                entries.append((name, 'symlink', member.linkname))
            elif member.isfile():
                if name in files:
                    raise RuntimeError(f'duplicate archive member: {name}')
                checksum = hashlib.sha256(tar.extractfile(member).read()).hexdigest()
                files[name] = (member.mode, checksum)
                entries.append((name, member.mode, checksum))
            else:
                raise RuntimeError(f'unsupported archive member: {name}')
    if sum(item[1] == 'symlink' for item in entries) != 1:
        raise RuntimeError('declared Skia archive symlink is absent or duplicated')
    checksum = hashlib.sha256()
    for name, mode, value in sorted(entries):
        checksum.update(f'{name}\0{mode}\0{value}\n'.encode())
    tree = checksum.hexdigest()
    if tree != SPEC['sourceTreeSha256']:
        raise RuntimeError(f'Skia source content tree {tree} differs from pin')
    if files.get('LICENSE', (None, None))[1] != SPEC['licenseSha256']:
        raise RuntimeError('Skia source license differs from pin')
    return files, tree


def obtain_archive(explicit):
    cached = WORK / 'archive.tar.gz'
    if explicit:
        archive = Path(explicit).resolve()
    elif cached.is_file():
        archive = cached
    else:
        cached.parent.mkdir(parents=True, exist_ok=True)
        temporary = cached.with_suffix('.download')
        url = f"{SPEC['skiaRepository']}/+archive/{SPEC['skiaRevision']}.tar.gz"
        print('+ download', url, flush=True)
        with urllib.request.urlopen(url, timeout=120) as response, temporary.open('wb') as file:
            shutil.copyfileobj(response, file)
        temporary.replace(cached)
        archive = cached
    archive_hash = digest(archive)
    files, tree = source_inventory(archive)
    if archive_hash != SPEC['archiveSha256']:
        print('Skia archive gzip differs from the pinned original; verified identical '
              'canonical source tree instead.', flush=True)
    if archive != cached:
        cached.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(archive, cached)
    return cached, archive_hash, files, tree


def verify_source(archive, files):
    if not SOURCE.exists():
        SOURCE.mkdir(parents=True)
        with tarfile.open(archive, 'r:gz') as tar:
            for member in tar:
                if member.isdir() or member.name == SPEC['excludedArchiveSymlink']:
                    continue
                target = SOURCE / member.name
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as input_file, target.open('wb') as output_file:
                    shutil.copyfileobj(input_file, output_file)
                target.chmod(member.mode & 0o777)
    for name, (_, expected) in files.items():
        path = SOURCE / name
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise RuntimeError(f'Skia source file differs from pinned content: {name}')
    excluded = SOURCE / SPEC['excludedArchiveSymlink']
    if excluded.exists() or excluded.is_symlink():
        raise RuntimeError(f'excluded Skia symlink exists: {excluded}')
    # Only the GN bootstrap binary and output build directory may be generated.
    actual = {str(path.relative_to(SOURCE)) for path in SOURCE.rglob('*') if path.is_file()}
    extra = actual - set(files) - {'bin/gn', 'third_party/gn/gn'}
    extra = {name for name in extra if not name.startswith('out/')}
    if extra:
        raise RuntimeError(f'unverified Skia source files: {sorted(extra)[:5]}')
    links = [str(path.relative_to(SOURCE)) for path in SOURCE.rglob('*') if path.is_symlink()]
    if links:
        raise RuntimeError(f'unverified Skia symlinks: {links[:5]}')


def verify_gn():
    gn = SOURCE / 'bin/gn'
    if not gn.exists():
        run(sys.executable, SOURCE / 'bin/fetch-gn', cwd=SOURCE)
    if digest(gn) != SPEC['gnSha256']:
        raise RuntimeError('Skia GN bootstrap binary differs from pin')
    downloaded = SOURCE / 'third_party/gn/gn'
    if downloaded.exists() and digest(downloaded) != SPEC['gnSha256']:
        raise RuntimeError('Skia GN downloaded binary differs from pin')
    return gn


def input_hashes():
    names = ['tools/build-raster.py', 'tools/raster.json',
             'Sources/CNoisemakerRaster/NoisemakerRaster.cpp',
             'Sources/CNoisemakerRaster/include/NoisemakerRaster.h',
             'tools/raster-api-test.cpp', 'tools/raster-smoke.cpp',
             'parity/grade-overlays.py', 'parity/reference.json',
             'parity/overlays/oracle.json']
    oracle = json.loads((ROOT / 'parity/overlays/oracle.json').read_text())
    lock = json.loads((ROOT / 'parity/reference.json').read_text())
    if oracle['authority'] != {key: lock[key] for key in
                              ('repository', 'commit', 'sourceManifestSha256')} or \
            SPEC['chromiumTag'] not in oracle['browser']:
        raise RuntimeError('overlay oracle authority or browser differs from raster pin')
    for case in oracle['cases']:
        names.extend([f"parity/overlays/{case['segmentFile']}",
                      f"parity/overlays/{case['file']}"])
    return {name: digest(ROOT / name) for name in names}


def expected_files():
    return [ARTIFACT / name for name in [
        'Info.plist', 'LICENSE-skia.txt',
        'macos-arm64/libCNoisemakerRaster.a',
        'macos-arm64/Headers/NoisemakerRaster.h',
        'macos-arm64/Headers/module.modulemap']]


def verify_artifact(record, inputs, fingerprint):
    if record.get('buildFingerprint') != fingerprint or record.get('inputs') != inputs:
        raise RuntimeError('raster artifact provenance does not match build inputs')
    if record.get('schemaVersion') != 1 or \
            record.get('pinnedArchiveSha256') != SPEC['archiveSha256'] or \
            record.get('sourceTreeSha256') != SPEC['sourceTreeSha256'] or \
            record.get('gnSha256') != SPEC['gnSha256'] or \
            record.get('licenseSha256') != SPEC['licenseSha256']:
        raise RuntimeError('raster artifact source pin differs from specification')
    for path in expected_files():
        relative = str(path.relative_to(ARTIFACT))
        if not path.is_file() or path.is_symlink() or \
                digest(path) != record.get('files', {}).get(relative):
            raise RuntimeError(f'raster artifact file differs from provenance: {relative}')
        content = path.read_bytes()
        if b'/Users/' in content or b'/private/var/folders/' in content:
            raise RuntimeError(f'raster artifact contains private build paths: {relative}')
    license_copy = ROOT / 'tools/raster/LICENSE-skia.txt'
    if not license_copy.is_file() or digest(license_copy) != SPEC['licenseSha256'] or \
            license_copy.read_bytes() != (ARTIFACT / 'LICENSE-skia.txt').read_bytes():
        raise RuntimeError('raster license copy differs from artifact provenance')


def test_artifact(compiler, sdk_path):
    headers = ARTIFACT / 'macos-arm64/Headers'
    library = ARTIFACT / 'macos-arm64/libCNoisemakerRaster.a'
    flags = ['-std=c++17', '-O2', '-mmacosx-version-min=14.0',
             '-isysroot', sdk_path, '-I', headers]
    frameworks = ['-framework', 'CoreFoundation', '-framework', 'CoreGraphics',
                  '-framework', 'CoreText']
    with tempfile.TemporaryDirectory(prefix='nm-raster-verification-') as temporary:
        verification = Path(temporary)
        test_binary = verification / 'raster-api-test'
        run(compiler, *flags, ROOT / 'tools/raster-api-test.cpp', library,
            *frameworks, '-o', test_binary)
        run(test_binary)
        smoke = verification / 'raster-smoke'
        run(compiler, *flags, ROOT / 'tools/raster-smoke.cpp', library,
            *frameworks, '-o', smoke)
        oracle = json.loads((ROOT / 'parity/overlays/oracle.json').read_text())
        candidates = verification / 'candidates'
        candidates.mkdir()
        for case in oracle['cases']:
            segment = ROOT / 'parity/overlays' / case['segmentFile']
            expected = ROOT / 'parity/overlays' / case['file']
            if digest(segment) != case['segmentsSha256'] or digest(expected) != case['sha256']:
                raise RuntimeError(f"overlay oracle fixture differs from its pin: {case['id']}")
            run(smoke, case['width'], case['height'], segment,
                candidates / case['file'])
        run(sys.executable, ROOT / 'parity/grade-overlays.py', candidates)


def build(archive_arg, verify_only):
    if sys.platform != 'darwin' or output('uname', '-m') != 'arm64':
        raise RuntimeError('raster artifact requires macOS arm64')
    if (SPEC['platform'], SPEC['architecture'], SPEC['deploymentTarget']) != ('macos', 'arm64', '14.0'):
        raise RuntimeError('unexpected raster platform specification')
    archive, archive_hash, files, tree = obtain_archive(archive_arg)
    verify_source(archive, files)
    gn = verify_gn()
    compiler = output('xcrun', '--find', 'clang++')
    compiler_version = output('xcrun', 'clang++', '--version').splitlines()[0]
    sdk_path = output('xcrun', '--sdk', 'macosx', '--show-sdk-path')
    sdk_version = output('xcrun', '--sdk', 'macosx', '--show-sdk-version')
    inputs = input_hashes()
    fingerprint = hashlib.sha256(json.dumps({
        'inputs': inputs, 'sourceTreeSha256': tree, 'gnSha256': SPEC['gnSha256'],
        'gnArgs': ARGS, 'compiler': compiler, 'compilerVersion': compiler_version,
        'sdkPath': sdk_path, 'sdkVersion': sdk_version,
    }, sort_keys=True).encode()).hexdigest()
    if PROVENANCE.exists():
        record = json.loads(PROVENANCE.read_text())
        try:
            verify_artifact(record, inputs, fingerprint)
        except RuntimeError:
            if verify_only:
                raise
        else:
            test_artifact(compiler, sdk_path)
            print(f'Verified cached {ARTIFACT}')
            return
    if verify_only:
        raise RuntimeError('raster artifact or provenance is missing')
    build_dir = SOURCE / 'out/raster'
    build_dir.mkdir(parents=True, exist_ok=True)
    args_file = build_dir / 'args.gn'
    runtime_args = ARGS.replace('{SOURCE}', str(SOURCE))
    old_args = ARGS.split('extra_cflags =')[0]
    if args_file.exists() and args_file.read_text() not in (runtime_args, old_args):
        raise RuntimeError('existing Skia GN arguments differ from the pinned raster configuration')
    args_file.write_text(runtime_args)
    run(gn, 'gen', 'out/raster', cwd=SOURCE)
    run('ninja', '-C', build_dir, 'skia', 'skcms')
    shim = WORK / 'NoisemakerRaster.o'
    run(compiler, '-std=c++17', '-O2', '-fvisibility=hidden', '-mmacosx-version-min=14.0',
        '-isysroot', sdk_path,
        f'-ffile-prefix-map={ROOT}=.', '-I', SOURCE,
        '-I', ROOT / 'Sources/CNoisemakerRaster/include', '-c',
        ROOT / 'Sources/CNoisemakerRaster/NoisemakerRaster.cpp', '-o', shim)
    slice_dir = ARTIFACT / 'macos-arm64'
    slice_dir.mkdir(parents=True, exist_ok=True)
    library = slice_dir / 'libCNoisemakerRaster.a'
    pending = slice_dir / 'libCNoisemakerRaster.pending.a'
    env = dict(os.environ, ZERO_AR_DATE='1')
    # Skia's archive already contains skcms objects in this pinned GN build.
    run('libtool', '-static', '-no_warning_for_no_symbols', '-o', pending,
        shim, build_dir / 'libskia.a', env=env)
    pending.replace(library)
    headers = slice_dir / 'Headers'
    headers.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'Sources/CNoisemakerRaster/include/NoisemakerRaster.h',
                 headers / 'NoisemakerRaster.h')
    (headers / 'module.modulemap').write_text('module CNoisemakerRaster {\n'
        '  header "NoisemakerRaster.h"\n  export *\n}\n')
    info = {'XCFrameworkFormatVersion': '1.0', 'CFBundlePackageType': 'XFWK',
            'AvailableLibraries': [{'LibraryIdentifier': 'macos-arm64',
                                    'LibraryPath': library.name, 'HeadersPath': 'Headers',
                                    'SupportedArchitectures': ['arm64'],
                                    'SupportedPlatform': 'macos'}]}
    with (ARTIFACT / 'Info.plist').open('wb') as file:
        plistlib.dump(info, file)
    license = SOURCE / 'LICENSE'
    if digest(license) != SPEC['licenseSha256']:
        raise RuntimeError('Skia source license differs from pin')
    shutil.copy2(license, ARTIFACT / 'LICENSE-skia.txt')
    license_copy = ROOT / 'tools/raster/LICENSE-skia.txt'
    license_copy.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(license, license_copy)
    test_artifact(compiler, sdk_path)
    record = {'schemaVersion': 1, 'skiaRevision': SPEC['skiaRevision'],
              'chromiumTag': SPEC['chromiumTag'],
              'pinnedArchiveSha256': SPEC['archiveSha256'],
              'observedArchiveSha256': archive_hash,
              'sourceTreeSha256': tree, 'sourceFileCount': len(files),
              'gnSha256': SPEC['gnSha256'], 'gnArgs': ARGS,
              'compiler': compiler_version, 'sdkVersion': sdk_version,
              'buildFingerprint': fingerprint, 'inputs': inputs,
              'files': {str(path.relative_to(ARTIFACT)): digest(path)
                        for path in expected_files()},
              'licenseSha256': digest(license_copy)}
    PROVENANCE.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    verify_artifact(record, inputs, fingerprint)
    print(f'Built and verified {ARTIFACT} ({library.stat().st_size} bytes)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-archive', help='verified local Skia source archive')
    parser.add_argument('--verify-only', action='store_true')
    options = parser.parse_args()
    build(options.source_archive, options.verify_only)
