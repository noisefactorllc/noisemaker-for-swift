#!/usr/bin/env python3
"""Measure the native runtime workload matrix and preserve raw phase/frame samples."""
import argparse
import hashlib
import json
import os
import platform
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKLOADS = {
    'generator': 'coverage/synth_perlin',
    'multipass': 'coverage/filter_blur',
    'simulation': 'coverage/synth_reactionDiffusion',
    'geometry': 'coverage/filter_wormhole',
}
DEFAULT_SIZES = [(256, 256), (512, 512), (1920, 1080), (257, 129)]

def dimensions(value):
    try:
        width, height = map(int, value.lower().split('x'))
        if width <= 0 or height <= 0:
            raise ValueError()
        return width, height
    except ValueError as error:
        raise argparse.ArgumentTypeError('expected positive WIDTHxHEIGHT') from error

parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
parser.add_argument('--workload', action='append', choices=WORKLOADS)
parser.add_argument('--size', action='append', type=dimensions)
parser.add_argument('--warmup-frames', type=int, default=8)
parser.add_argument('--measured-frames', type=int, default=120)
parser.add_argument('--sustained-frames', type=int, default=600)
parser.add_argument('--inflight-batches', type=int, default=20)
parser.add_argument('--resize-sequence', default='512x512,257x129,1920x1080,256x256,512x512,257x129,1920x1080,256x256')
parser.add_argument('--smoke', action='store_true',
                    help='one generator/256x256 run with four measured frames and no stress modes')
args = parser.parse_args()
if min(args.warmup_frames, args.measured_frames, args.sustained_frames,
       args.inflight_batches) < 0 or args.measured_frames == 0:
    parser.error('frame counts must be nonnegative and measured frames must be positive')
if not args.smoke and (args.sustained_frames == 0 or args.inflight_batches == 0):
    parser.error('sustained frames and in-flight batches must be positive')
for token in args.resize_sequence.split(','):
    dimensions(token)
workloads = args.workload or list(WORKLOADS)
sizes = args.size or DEFAULT_SIZES
if args.smoke:
    workloads, sizes = ['generator'], [(256, 256)]
    args.warmup_frames, args.measured_frames = 2, 4

OUT = ROOT / '.build' / ('benchmark-runtime-' + args.configuration)
OUT.mkdir(parents=True, exist_ok=True)

def fingerprint():
    paths = list((ROOT / 'Sources').rglob('*'))
    paths += list((ROOT / 'Artifacts').rglob('*'))
    paths += [ROOT / 'Package.swift', ROOT / 'tools/benchmark-runtime.py',
              ROOT / 'tools/benchmark-runtime.swift', ROOT / 'parity/corpus.json',
              ROOT / 'parity/reference.json', ROOT / 'Artifacts/translator.json']
    digest = hashlib.sha256()
    for path in sorted(set(paths)):
        if path.is_file():
            digest.update(str(path.relative_to(ROOT)).encode() + b'\0')
            digest.update(path.read_bytes())
    return digest.hexdigest()

def host_context():
    def sysctl(name):
        result = subprocess.run(['sysctl', '-n', name], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None
    return {
        'platform': platform.platform(), 'machine': platform.machine(),
        'cpuCount': os.cpu_count(), 'hardwareModel': sysctl('hw.model'),
        'physicalMemoryBytes': sysctl('hw.memsize'),
        'loadAverage': os.getloadavg(),
    }

def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

def tool_version(command):
    result = subprocess.run(command, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None

fingerprint_before = fingerprint()
host_before = host_context()
build_command = ['swift', 'build', '-c', args.configuration, '-j', '4',
                 '-Xswiftc', '-enable-testing']
subprocess.run(build_command, cwd=ROOT, check=True)
build_dir = Path(subprocess.check_output(
    ['swift', 'build', '-c', args.configuration, '--show-bin-path'],
    cwd=ROOT, text=True).strip())
objects = sorted((build_dir / 'Noisemaker.build').glob('*.o'))
if not objects:
    raise RuntimeError('SwiftPM did not build Noisemaker objects')
archives = sorted((ROOT / 'Artifacts').glob('*.xcframework/macos-arm64/*.a'))
headers = sorted((ROOT / 'Artifacts').glob('*.xcframework/macos-arm64/Headers'))
if not archives or not headers:
    raise RuntimeError('Tint/Raster macOS archive or headers unavailable')
executable = OUT / 'benchmark'
link_command = ['swiftc', '-target', 'arm64-apple-macosx14.0',
    '-module-cache-path', str(build_dir / 'ModuleCache'),
    '-enable-testing',
    '-O' if args.configuration == 'release' else '-Onone',
    '-I', str(build_dir / 'Modules'),
    *[arg for header in headers for arg in ['-I', str(header)]],
    str(ROOT / 'tools/benchmark-runtime.swift'), *map(str, objects),
    *map(str, archives),
    '-framework', 'AppKit', '-framework', 'Metal', '-framework', 'CoreGraphics',
    '-framework', 'CoreText', '-lc++', '-o', str(executable)]
subprocess.run(link_command, cwd=ROOT, check=True)
binary_artifacts = [{'path': str(path.relative_to(ROOT)), 'sha256': sha256(path)}
                    for path in archives]
executable_hash = sha256(executable)
corpus = json.loads((ROOT / 'parity/corpus.json').read_text())
case_by_id = {case['id']: case for case in corpus['cases']}
rows = []

def measure(workload, width, height, mode, warmup, measured, sequence=None):
    case_id = WORKLOADS[workload]
    case = case_by_id[case_id]
    if hashlib.sha256(case['source'].encode()).hexdigest() != case['sourceSha256']:
        raise RuntimeError(f'{case_id} source does not match the corpus fingerprint')
    source = OUT / f'{workload}.dsl'
    source.write_text(case['source'])
    name = f'{workload}-{width}x{height}-{mode}'
    output = OUT / f'{name}.json'
    command = [str(executable), str(source), str(width), str(height),
               str(output), mode, str(warmup), str(measured)]
    if sequence is not None:
        command.append(sequence)
    host_before_case = host_context()
    subprocess.run(command, cwd=ROOT, check=True)
    host_after_case = host_context()
    raw = json.loads(output.read_text())
    if workload == 'geometry' and not set(raw['drawModes']) & {'points', 'triangles', 'billboards'}:
        raise RuntimeError(f'{case_id} did not compile an actual geometry draw mode')
    rows.append({'workload': workload, 'case': case_id,
                 'hostContextBefore': host_before_case,
                 'hostContextAfter': host_after_case,
                 'sourceSha256': case['sourceSha256'], **raw})

for workload in workloads:
    for width, height in sizes:
        measure(workload, width, height, 'frames', args.warmup_frames, args.measured_frames)
if not args.smoke:
    measure('simulation', 512, 512, 'sustained', args.warmup_frames, args.sustained_frames)
    measure('simulation', 256, 256, 'resize', 0, 1, args.resize_sequence)
    measure('generator', 256, 256, 'inflight', 0, args.inflight_batches)

fingerprint_after = fingerprint()
if fingerprint_after != fingerprint_before:
    raise RuntimeError('Sources, benchmark tools, or authority changed during benchmark')
if any(sha256(ROOT / item['path']) != item['sha256'] for item in binary_artifacts):
    raise RuntimeError('A linked binary artifact changed during benchmark')
if sha256(executable) != executable_hash:
    raise RuntimeError('Benchmark executable changed during measurement')
report = {
    'schemaVersion': 2, 'sourceAndToolTreeSha256': fingerprint_before,
    'authority': json.loads((ROOT / 'parity/reference.json').read_text()),
    'catalogSha256': hashlib.sha256((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_bytes()).hexdigest(),
    'translator': json.loads((ROOT / 'Artifacts/translator.json').read_text()),
    'swift': subprocess.check_output(['swift', '--version'], text=True).strip(),
    'xcode': tool_version(['xcodebuild', '-version']),
    'metalCompilerPath': tool_version(['xcrun', '--find', 'metal']),
    'binaryArtifacts': binary_artifacts,
    'benchmarkExecutableSha256': executable_hash,
    'buildConfiguration': args.configuration, 'buildCommand': build_command,
    'linkOptimization': '-O' if args.configuration == 'release' else '-Onone',
    'measurementInstrumentation': {
        'libraryBuiltWithEnableTesting': True,
        'probeInstalledOnBenchmarkThread': True,
        'probeOverheadIncludedInCpuAndPreparationTimes': True,
        'allocationCountScope': 'TexturePool, FeedbackState, NoisemakerRenderer, BufferToTextureBridge',
    },
    'metalEnvironment': {name: os.environ.get(name) for name in [
        'MTL_DEBUG_LAYER', 'MTL_SHADER_VALIDATION', 'MTL_CAPTURE_ENABLED',
        'MTL_HUD_ENABLED', 'METAL_DEVICE_WRAPPER_TYPE', 'MTL_DEVICE_WRAPPER_TYPE']},
    'protocol': {'workloads': workloads, 'sizes': sizes,
        'warmupFrames': args.warmup_frames, 'measuredFrames': args.measured_frames,
        'sustainedFrames': 0 if args.smoke else args.sustained_frames,
        'inflightBatches': 0 if args.smoke else args.inflight_batches,
        'resizeSequence': [] if args.smoke else args.resize_sequence.split(','),
        'smoke': args.smoke},
    'hostContext': {'before': host_before, 'after': host_context(),
                    'exclusiveHost': False},
    'measurements': rows,
}
matrix = OUT / ('smoke.json' if args.smoke else 'matrix.json')
matrix.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'matrix': str(matrix), 'measurements': len(rows)}))
