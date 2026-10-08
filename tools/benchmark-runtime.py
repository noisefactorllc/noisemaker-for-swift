#!/usr/bin/env python3
"""Measure the native workload matrix without a browser or runtime source checkout."""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
args = parser.parse_args()
OUT = ROOT / '.build' / ('benchmark-runtime-' + args.configuration)
OUT.mkdir(parents=True, exist_ok=True)
def source_hash():
    digest = hashlib.sha256()
    for path in sorted((ROOT / 'Sources').rglob('*')):
        if path.is_file():
            digest.update(str(path.relative_to(ROOT)).encode() + b'\0')
            digest.update(path.read_bytes())
    return digest.hexdigest()
source_before = source_hash()
load_before = os.getloadavg()
subprocess.run(['swift', 'build', '-c', args.configuration, '-j', '4'], cwd=ROOT, check=True)
BUILD = Path(subprocess.check_output(['swift', 'build', '-c', args.configuration, '--show-bin-path'], cwd=ROOT, text=True).strip())
objects = sorted((BUILD / 'Noisemaker.build').glob('*.o'))
if not objects:
    raise RuntimeError('SwiftPM did not build Noisemaker objects')
executable = OUT / 'benchmark'
archives = sorted((ROOT / 'Artifacts').glob('*.xcframework/macos-arm64/*.a'))
headers = sorted((ROOT / 'Artifacts').glob('*.xcframework/macos-arm64/Headers'))
subprocess.run(['swiftc', '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(BUILD / 'ModuleCache'),
    '-O' if args.configuration == 'release' else '-Onone',
    '-I', str(BUILD / 'Modules'), *[arg for path in headers for arg in ['-I',str(path)]],
    str(ROOT / 'tools/benchmark-runtime.swift'), *map(str, objects),
    *map(str,archives),
    '-framework', 'AppKit', '-framework', 'Metal', '-framework', 'CoreGraphics', '-framework', 'CoreText', '-lc++', '-o', str(executable)],
    cwd=ROOT, check=True)
corpus = json.loads((ROOT / 'parity/corpus.json').read_text())
workloads = {'generator': 'coverage/synth_perlin', 'multipass': 'coverage/filter_blur',
             'simulation': 'coverage/synth_reactionDiffusion', 'geometry': 'coverage/filter_wormhole'}
rows = []
for name, case in workloads.items():
    item = next(item for item in corpus['cases'] if item['id'] == case)
    source = OUT / f'{name}.dsl'
    source.write_text(item['source'])
    for width, height in [(256,256),(512,512),(1920,1080),(257,129)]:
        output = OUT / f'{name}-{width}x{height}.json'
        subprocess.run([str(executable), str(source), str(width), str(height), str(output)], cwd=ROOT, check=True)
        report = json.loads(output.read_text())
        rows.append({'workload':name, 'case':case, 'sourceSha256':item['sourceSha256'], **report})
source_after = source_hash()
if source_after != source_before:
    raise RuntimeError('Source changed during benchmark; measurements are not qualified')
report = {'schemaVersion':1, 'sourceTreeSha256':source_before, 'authority':json.loads((ROOT / 'parity/reference.json').read_text()),
    'catalogSha256':hashlib.sha256((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_bytes()).hexdigest(),
    'translator':json.loads((ROOT / 'Artifacts/translator.json').read_text()),
    'swift':subprocess.check_output(['swift','--version'],text=True).strip(),
    'buildConfiguration':args.configuration,
    'hostContext':{'loadAverageBefore':load_before,'loadAverageAfter':os.getloadavg(),
                   'exclusiveHost':False}, 'measurements':rows}
(OUT / 'matrix.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'matrix':str(OUT / 'matrix.json'), 'measurements':len(rows)}))
