#!/usr/bin/env python3
"""Build the native example as a local, unsigned macOS application bundle."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--no-build', action='store_true', help='Package an already built debug example')
args = parser.parse_args()
if not args.no_build:
    subprocess.run(['swift', 'build', '--product', 'nm-viewer'], cwd=root, check=True)
binaries = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
app = root / '.build/Noisemaker.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
shutil.copy2(binaries / 'nm-viewer', contents / 'MacOS/nm-viewer')
# SwiftPM's generated Bundle.module resolves this exact location from Bundle.main.
shutil.copytree(binaries / 'Noisemaker_Noisemaker.bundle', app / 'Noisemaker_Noisemaker.bundle', dirs_exist_ok=True)
with (contents / 'Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleIdentifier':'io.noisefactor.noisemaker.swift-example',
                  'CFBundleName':'Noisemaker', 'CFBundleDisplayName':'Noisemaker',
                  'CFBundleExecutable':'nm-viewer', 'CFBundlePackageType':'APPL',
                  'CFBundleVersion':'1', 'CFBundleShortVersionString':'0.1',
                  'LSMinimumSystemVersion':'14.0', 'NSHighResolutionCapable':True}, output)
print(app)
