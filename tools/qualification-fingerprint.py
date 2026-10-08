#!/usr/bin/env python3
"""Fingerprint the inputs and executable used by a native parity run."""

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    checksum = hashlib.sha256()
    with Path(path).open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            checksum.update(block)
    return checksum.hexdigest()


def tree(root, directory):
    base = root / directory
    if not base.is_dir():
        raise ValueError(f'missing qualification input directory: {directory}')
    paths = sorted(path for path in base.rglob('*')
                   if '__pycache__' not in path.parts and path.suffix != '.pyc')
    if any(path.is_symlink() for path in paths):
        raise ValueError(f'qualification input contains a symlink: {directory}')
    entries = [[path.relative_to(root).as_posix(), sha256(path)] for path in paths if path.is_file()]
    encoded = json.dumps(entries, separators=(',', ':'), ensure_ascii=True).encode()
    return {'files': len(entries), 'sha256': hashlib.sha256(encoded).hexdigest()}


def browser_bundle(executable, headless):
    executable = Path(executable).resolve()
    if not executable.is_file():
        raise ValueError(f'qualified Chromium executable is missing: {executable}')
    # A headed macOS executable is a small stub; the framework and resources
    # sit in the containing chrome-mac-* directory. The headless shell keeps
    # its libraries and data beside the executable.
    bundle = next((parent for parent in executable.parents
                   if parent.name.startswith('chrome-mac-')), executable.parent)
    entries = []
    for path in sorted(bundle.rglob('*')):
        name = path.relative_to(bundle).as_posix()
        if path.is_symlink():
            target = path.resolve()
            if not target.is_relative_to(bundle) or not target.exists():
                raise ValueError(f'Chromium bundle has an escaping or broken symlink: {name}')
            entries.append([name, 'symlink', os.readlink(path)])
        elif path.is_file():
            entries.append([name, 'file', sha256(path)])
    if not entries:
        raise ValueError('qualified Chromium bundle has no files')
    encoded = json.dumps(entries, separators=(',', ':'), ensure_ascii=True).encode()
    return {'executablePath': str(executable), 'executableSha256': sha256(executable),
            'bundlePath': str(bundle), 'bundleSha256': hashlib.sha256(encoded).hexdigest(),
            'files': len(entries), 'headless': headless}


def browser_inputs(reference_root, *, headless=None):
    if headless is None:
        headless = os.environ.get('SHADE_HEADLESS') not in ('0', 'false')
    name = 'chromium-headless-shell' if headless else 'chromium'
    script = '''
const { join } = require('node:path');
const [ref, name] = process.argv.slice(1);
const core = require(join(ref, 'node_modules/playwright-core/lib/coreBundle.js'));
const path = core.registry.registry.findExecutable(name)?.executablePath();
if (!path) throw new Error(`Playwright has no ${name} executable`);
process.stdout.write(path);
'''
    result = subprocess.run(['node', '-e', script, str(Path(reference_root).resolve()), name],
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f'cannot resolve Playwright Chromium executable: {result.stderr.strip()}')
    return browser_bundle(result.stdout, headless)


def authority_inputs(root, reference_root, browser_identity=None):
    root, reference_root = Path(root), Path(reference_root).resolve()
    lock = json.loads((root / 'parity/reference.json').read_text())
    manifest_path = root / '.build/reference/source-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get('repository') != lock.get('repository') or
            manifest.get('commit') != lock.get('commit') or
            not re.fullmatch(r'[0-9a-f]{64}', lock.get('sourceManifestSha256', ''))):
        raise ValueError('reference source manifest differs from authority lock')
    files = manifest.get('files')
    if not isinstance(files, list) or not files:
        raise ValueError('reference source manifest lacks files')
    lines, seen = [], set()
    for entry in files:
        if not isinstance(entry, dict):
            raise ValueError('malformed reference source manifest entry')
        name, expected = entry.get('path'), entry.get('sha256')
        if (not isinstance(name, str) or name in seen or
                not name or Path(name).is_absolute() or
                '\\' in name or
                any(part in ('', '.', '..') for part in name.split('/')) or
                not isinstance(expected, str) or
                not re.fullmatch(r'[0-9a-f]{64}', expected)):
            raise ValueError('malformed reference source manifest entry')
        seen.add(name)
        path = reference_root / name
        if not path.is_file() or path.is_symlink() or sha256(path) != expected:
            raise ValueError(f'reference source differs from manifest: {name}')
        lines.append(f'{name}\0{expected}\n')
    manifest_sha = hashlib.sha256(''.join(lines).encode()).hexdigest()
    if manifest_sha != lock['sourceManifestSha256'] or manifest_sha != manifest.get('contentSha256'):
        raise ValueError('reference source manifest digest differs from authority lock')
    package_lock = reference_root / 'package-lock.json'
    if not package_lock.is_file():
        raise ValueError('reference browser dependency lock is missing')
    return {
        'root': str(reference_root),
        'sourceManifestSha256': manifest_sha,
        'sourceManifestFileSha256': sha256(manifest_path),
        'packageLockSha256': sha256(package_lock),
        'nodeModules': tree(reference_root, 'node_modules'),
        'browser': browser_identity if browser_identity is not None else browser_inputs(reference_root),
    }


def verify_source_identity(root, reference_root):
    # Use the same locked-source admission as the WebGPU golden runner. The
    # Python snapshot above also hashes its exported manifest and browser
    # dependencies, so repeating this check after grading closes that window.
    script = '''
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { sourceIdentity, sourceManifest } from './tools/export-reference.mjs';
import { verifyArchivedSource } from './parity/marker-golden.mjs';
const [ref, lockPath, exportRoot] = process.argv.slice(1);
const lock = JSON.parse(readFileSync(lockPath, 'utf8'));
if (existsSync(join(ref, '.git'))) sourceIdentity(ref, lock);
else verifyArchivedSource(ref, lock, exportRoot);
if (sourceManifest(ref, lock).contentSha256 !== lock.sourceManifestSha256)
  throw new Error('reference source differs from locked manifest');
'''
    result = subprocess.run(
        ['node', '--input-type=module', '-e', script, str(Path(reference_root).resolve()),
         str(Path(root) / 'parity/reference.json'), str(Path(root) / '.build/reference')],
        cwd=root, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f'reference source identity revalidation failed: {result.stderr.strip()}')


def grader_inputs(pillow_directory=None):
    import PIL

    directory = Path(pillow_directory) if pillow_directory else Path(PIL.__file__).resolve().parent
    if directory.name != 'PIL':
        raise ValueError('Pillow package directory is not PIL')
    return {
        'python': platform.python_version(),
        'pillow': PIL.__version__,
        'pillowTree': tree(directory.parent, directory.name),
    }


def snapshot(root=ROOT, binary=None, reference_root=None):
    root = Path(root)
    package = root / 'Package.swift'
    if not package.is_file():
        raise ValueError('missing Package.swift')
    result = {
        'scope': 'Package.swift, Sources/, Artifacts/, tools/, scripts/, parity/, reference authority/browser dependencies and optional executable',
        'packageSha256': sha256(package),
        'sources': tree(root, 'Sources'),
        'artifacts': tree(root, 'Artifacts'),
        'tools': tree(root, 'tools'),
        'scripts': tree(root, 'scripts'),
        'parity': tree(root, 'parity'),
    }
    if reference_root is not None:
        result['referenceAuthority'] = authority_inputs(root, reference_root)
    if binary is not None:
        binary = Path(binary)
        if not binary.is_file():
            raise ValueError(f'missing qualified native executable: {binary}')
        result['binarySha256'] = sha256(binary)
    return result


def reject_software_webgpu():
    # Match the pinned Shade harness's exact SwiftShader enable values.
    if os.environ.get('SHADE_SWIFTSHADER') in ('1', 'true'):
        raise ValueError('software WebGPU is not qualified (SHADE_SWIFTSHADER is enabled)')


def main():
    reject_software_webgpu()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    arguments = parser.parse_args()
    reference_root = os.environ.get('NM_REFERENCE_ROOT')
    if reference_root:
        verify_source_identity(ROOT, reference_root)
    result = snapshot(binary=arguments.binary, reference_root=reference_root)
    result['buildEnvironment'] = {
        'os': platform.platform(), 'architecture': platform.machine(),
        'swift': subprocess.check_output(['xcrun', 'swift', '--version'], text=True).strip(),
        'sdk': subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip(),
        'node': subprocess.check_output(['node', '--version'], text=True).strip(),
        'shadeHeadless': os.environ.get('SHADE_HEADLESS', '1'),
        'shadeSwiftshader': os.environ.get('SHADE_SWIFTSHADER', ''),
        'playwrightBrowsersPath': os.environ.get('PLAYWRIGHT_BROWSERS_PATH', ''),
        'nodeOptions': os.environ.get('NODE_OPTIONS', ''),
        **grader_inputs(),
    }
    print(json.dumps(result, sort_keys=True, separators=(',', ':')))


if __name__ == '__main__':
    main()
