#!/usr/bin/env python3
"""Fingerprint the inputs and executable used by a native parity run."""

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree(root, directory):
    base = root / directory
    if not base.is_dir():
        raise ValueError(f'missing qualification input directory: {directory}')
    paths = sorted(base.rglob('*'))
    if any(path.is_symlink() for path in paths):
        raise ValueError(f'qualification input contains a symlink: {directory}')
    entries = [[path.relative_to(root).as_posix(), sha256(path)] for path in paths if path.is_file()]
    encoded = json.dumps(entries, separators=(',', ':'), ensure_ascii=True).encode()
    return {'files': len(entries), 'sha256': hashlib.sha256(encoded).hexdigest()}


def snapshot(root=ROOT, binary=None):
    root = Path(root)
    package = root / 'Package.swift'
    if not package.is_file():
        raise ValueError('missing Package.swift')
    result = {
        'scope': 'Package.swift, Sources/, Artifacts/ and optional executable',
        'packageSha256': sha256(package),
        'sources': tree(root, 'Sources'),
        'artifacts': tree(root, 'Artifacts'),
    }
    if binary is not None:
        binary = Path(binary)
        if not binary.is_file():
            raise ValueError(f'missing qualified native executable: {binary}')
        result['binarySha256'] = sha256(binary)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    arguments = parser.parse_args()
    print(json.dumps(snapshot(binary=arguments.binary), sort_keys=True, separators=(',', ':')))


if __name__ == '__main__':
    main()
