#!/usr/bin/env python3
"""Build and link a checked-in native measurement tool against the current package."""
import subprocess
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
name = sys.argv[1]
if name not in ('measure-translations', 'benchmark-runtime'):
    raise SystemExit('unsupported native measurement tool')
subprocess.run(['swift','build'],cwd=ROOT,check=True)
build = Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=ROOT,text=True).strip())
output = ROOT / '.build' / (name + '-tool')
archives = sorted((ROOT / 'Artifacts').glob('*.xcframework/macos-arm64/*.a'))
headers = sorted((ROOT / 'Artifacts').glob('*.xcframework/macos-arm64/Headers'))
subprocess.run(['swiftc','-target','arm64-apple-macosx14.0','-module-cache-path',str(build/'ModuleCache'),
 '-I',str(build/'Modules'), *[arg for path in headers for arg in ['-I',str(path)]],
 str(ROOT/'tools'/f'{name}.swift'), *map(str,sorted((build/'Noisemaker.build').glob('*.o'))), *map(str,archives),
 '-framework','AppKit','-framework','Metal','-framework','CoreGraphics','-framework','CoreText','-lc++','-o',str(output)],cwd=ROOT,check=True)
subprocess.run([str(output),*sys.argv[2:]],cwd=ROOT,check=True)
