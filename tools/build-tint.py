#!/usr/bin/env python3
"""Build the pinned Tint-only C shim as a local macOS SwiftPM binary target."""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / 'tools/tint/dawn.json').read_text())
WORK = ROOT / '.build/tint'
CACHE = WORK / 'source'
LIBRARY = WORK / 'CNoisemakerTint.xcframework'


def run(*args, cwd=None):
    print('+', *map(str, args), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def output(*args, cwd=None):
    return subprocess.check_output(list(map(str, args)), cwd=cwd, text=True).strip()


def safe_extract(archive, destination):
    """Extract only regular files and directories beneath destination."""
    with tarfile.open(archive) as tar:
        for member in tar:
            relative = PurePosixPath(member.name)
            if not relative.parts or relative.is_absolute() or '..' in relative.parts:
                raise RuntimeError(f'unsafe archive path: {member.name}')
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source_file, target.open('wb') as output_file:
                    shutil.copyfileobj(source_file, output_file)
                target.chmod(member.mode & 0o777)
            else:
                raise RuntimeError(f'unsupported archive member: {member.name}')


def archive_manifest(archive):
    entries = {}
    with tarfile.open(archive) as tar:
        for member in tar:
            if member.isfile():
                entries[member.name] = hashlib.sha256(tar.extractfile(member).read()).hexdigest()
    return entries


def verify_source(dest, entries):
    expected = set(entries)
    actual = {str(p.relative_to(dest)) for p in dest.rglob('*') if p.is_file()
              and p.name not in ('.source-commit', '.source-files.json')}
    if actual != expected:
        raise RuntimeError(f'{dest}: source file inventory differs from verified archive')
    for relative, digest in entries.items():
        if hashlib.sha256((dest / relative).read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'{dest / relative}: source hash differs from verified archive')


def source(repo, commit, name, paths=()):
    dest = CACHE / f'{name}-{commit}'
    marker = dest / '.source-commit'
    manifest_path = dest / '.source-files.json'
    if marker.exists() and marker.read_text().strip() != commit:
        raise RuntimeError(f'{dest}: source commit marker differs from pin')
    if marker.exists() and manifest_path.exists():
        verify_source(dest, json.loads(manifest_path.read_text()))
        return dest
    if dest.exists() and not marker.exists():
        raise RuntimeError(f'{dest} exists without the expected commit marker')
    bare = WORK / 'fetch' / f'{name}.git'
    bare.parent.mkdir(parents=True, exist_ok=True)
    if not bare.exists():
        run('git', 'init', '--quiet', '--bare', bare)
    if subprocess.run(['git', '-C', str(bare), 'cat-file', '-e',
                       f'{commit}^{{commit}}'], capture_output=True).returncode != 0:
        run('git', '-C', bare, 'fetch', '--quiet', '--depth', '1', '--no-tags', repo, commit)
    resolved = output('git', '-C', bare, 'rev-parse', '--verify', f'{commit}^{{commit}}')
    if resolved != commit:
        raise RuntimeError(f'{name}: fetched {resolved}, expected {commit}')
    archive = WORK / 'fetch' / f'{name}.tar'
    run('git', '-C', bare, 'archive', '--format=tar', '-o', archive, commit, *paths)
    entries = archive_manifest(archive)
    if not dest.exists():
        dest.mkdir(parents=True)
        safe_extract(archive, dest)
        marker.write_text(commit + '\n')
    verify_source(dest, entries)
    manifest_path.write_text(json.dumps(entries, sort_keys=True) + '\n')
    archive.unlink()
    return dest


def build():
    if sys.platform != 'darwin':
        raise RuntimeError('Tint bootstrap currently supports macOS arm64 only')
    if output('uname', '-m') != 'arm64':
        raise RuntimeError('Tint bootstrap currently supports macOS arm64 only')
    dawn = SPEC['dawn']
    dawn_root = source(dawn['repository'], dawn['commit'], 'dawn', dawn['paths'])
    defs = [f'-DNM_DAWN_SOURCE_DIR={dawn_root}', f'-DNM_DAWN_COMMIT={dawn["commit"]}']
    for dep in SPEC['dependencies']:
        actual = output('git', '-C', WORK / 'fetch/dawn.git', 'ls-tree', dawn['commit'], '--', dep['path']).split()
        if len(actual) < 3 or actual[0] != '160000' or actual[2] != dep['commit']:
            raise RuntimeError(f'Dawn gitlink mismatch: {dep["path"]}')
        path = source(dep['repository'], dep['commit'], dep['path'].replace('/', '_'))
        defs.append(f'-D{dep["cmake_variable"]}={path}')
    fingerprint = hashlib.sha256()
    for input_path in (ROOT / 'tools/tint/dawn.json', ROOT / 'tools/tint/CMakeLists.txt',
                       ROOT / 'Sources/CNoisemakerTint/NoisemakerTint.cpp',
                       ROOT / 'Sources/CNoisemakerTint/include/NoisemakerTint.h',
                       dawn_root / '.source-files.json',
                       *(CACHE / f"{dep['path'].replace('/', '_')}-{dep['commit']}" / '.source-files.json'
                         for dep in SPEC['dependencies'])):
        fingerprint.update(input_path.read_bytes())
    cmake = os.environ.get('CMAKE', 'cmake')
    toolchain = [str(Path(shutil.which(cmake) or cmake).resolve()),
                 output(cmake, '--version').splitlines()[0],
                 output('xcrun', '--find', 'clang'),
                 output('xcrun', 'clang', '--version').splitlines()[0],
                 output('xcrun', '--sdk', 'macosx', '--show-sdk-path'),
                 output('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
                 'macos-arm64;Release;deployment=14.0']
    fingerprint.update('\n'.join(toolchain).encode())
    stamp = WORK / '.binary-fingerprint'
    digests_path = WORK / '.binary-digests.json'
    merged = LIBRARY / 'macos-arm64/libCNoisemakerTint.a'
    digest_files = [merged, LIBRARY / 'macos-arm64/Headers/NoisemakerTint.h',
                    LIBRARY / 'macos-arm64/Headers/module.modulemap', LIBRARY / 'Info.plist']
    if stamp.is_file() and stamp.read_text().strip() == fingerprint.hexdigest() and digests_path.is_file():
        recorded = json.loads(digests_path.read_text())
        if all(file.is_file() and hashlib.sha256(file.read_bytes()).hexdigest() == recorded.get(str(file.relative_to(LIBRARY)))
               for file in digest_files):
            print(f'Using hash-verified cached {LIBRARY}')
            return
    build_dir = WORK / 'build' / fingerprint.hexdigest()[:16]
    run(cmake, '-S', ROOT / 'tools/tint', '-B', build_dir, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0', *defs)
    run(cmake, '--build', build_dir, '--target', 'nm_tint_shim', '--parallel',
        str(os.cpu_count() or 4))
    archives = sorted(build_dir.rglob('*.a'))
    if not any(a.name == 'libnm_tint_shim.a' for a in archives):
        raise RuntimeError('Tint CMake build did not produce libnm_tint_shim.a')
    slice_dir = LIBRARY / 'macos-arm64'
    slice_dir.mkdir(parents=True, exist_ok=True)
    merged = slice_dir / 'libCNoisemakerTint.a'
    if merged.exists():
        merged.unlink()
    run('libtool', '-static', '-no_warning_for_no_symbols', '-o', merged, *archives)
    headers = slice_dir / 'Headers'
    headers.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'Sources/CNoisemakerTint/include/NoisemakerTint.h',
                 headers / 'NoisemakerTint.h')
    (headers / 'module.modulemap').write_text('module CNoisemakerTint {\n'
        '  header "NoisemakerTint.h"\n  export *\n}\n')
    info = {'XCFrameworkFormatVersion': '1.0', 'CFBundlePackageType': 'XFWK',
            'AvailableLibraries': [{'LibraryIdentifier': 'macos-arm64',
                                    'LibraryPath': 'libCNoisemakerTint.a',
                                    'HeadersPath': 'Headers',
                                    'SupportedArchitectures': ['arm64'],
                                    'SupportedPlatform': 'macos'}]}
    with (LIBRARY / 'Info.plist').open('wb') as file:
        plistlib.dump(info, file)
    digests_path.write_text(json.dumps({str(file.relative_to(LIBRARY)): hashlib.sha256(file.read_bytes()).hexdigest()
                                       for file in digest_files}, sort_keys=True) + '\n')
    stamp.write_text(fingerprint.hexdigest() + '\n')
    print(f'Built {LIBRARY}')
    print(f'Archive bytes: {merged.stat().st_size}')


if __name__ == '__main__':
    build()
