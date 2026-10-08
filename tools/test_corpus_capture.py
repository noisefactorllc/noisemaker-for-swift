#!/usr/bin/env python3
"""Exercise the native timed corpus capture through its Metal executable."""

import copy
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image


def test_failed_golden_admission(root, renderer, temporary, solid):
    """A source refusal authenticates metadata but never controls native execution."""
    case = copy.deepcopy(solid)
    case['id'] = 'regression/golden-solid'
    case['capture']['size'] = [16, 8]
    corpus_path = temporary / 'golden-solid-corpus.json'
    corpus_data = json.dumps({'schemaVersion': 1, 'cases': [case]}).encode()
    corpus_path.write_bytes(corpus_data)
    golden = {
        'id': case['id'], 'sourceSha256': case['sourceSha256'],
        'capture': copy.deepcopy(case['capture']), 'backend': 'WebGPU',
        'capabilityProfile': {'maxTextureDimension2D': 8192},
        'status': 'ok',
    }
    refusal = ('compilation failed: GPUDevice.createTexture rejected '
               'GPUExtent3DDict height: value is not of type unsigned long')

    def candidate(label, golden_case):
        golden_path = temporary / f'{label}-goldens.json'
        golden_path.write_text(json.dumps({
            'schemaVersion': 1, 'corpusSha256': hashlib.sha256(corpus_data).hexdigest(),
            'expected': 1, 'cases': [golden_case],
        }))
        output = temporary / f'{label}-candidates'
        result = subprocess.run([
            str(renderer), '--corpus', str(corpus_path), '--goldens', str(golden_path),
            '--out-dir', str(output),
        ], cwd=root, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(f'{label} nm-render failed: {result.stdout}\n{result.stderr}')
        ledger = json.loads((output / 'candidates.json').read_text())
        assert ledger['expected'] == 1 and len(ledger['cases']) == 1, ledger
        return ledger['cases'][0], output

    control, control_dir = candidate('golden-ok', golden)
    assert control['status'] == 'ok', control
    assert [image['frame'] for image in control['images']] == [8], control
    assert control['capabilityProfile'] == golden['capabilityProfile'], control
    assert control['hostTextures'] == [] and control['hostVolumes'] == [], control
    control_images = {
        image['frame']: (control_dir / image['path']).read_bytes()
        for image in control['images']
    }
    for image in control['images']:
        assert hashlib.sha256(control_images[image['frame']]).hexdigest() == image['sha256']

    failed_source = copy.deepcopy(golden)
    failed_source.update(status='fail', error=refusal)
    native, native_dir = candidate('golden-source-fail', failed_source)
    assert native['status'] == 'ok', native
    assert native['capabilityProfile'] == control['capabilityProfile'], native
    assert native['hostTextures'] == [] and native['hostVolumes'] == [], native
    assert [image['frame'] for image in native['images']] == list(control_images), native
    for image in native['images']:
        data = (native_dir / image['path']).read_bytes()
        assert data == control_images[image['frame']], image
        assert image['sha256'] == hashlib.sha256(data).hexdigest(), image

    invalid = {
        'source-sha': {'sourceSha256': '0' * 64},
        'capture': {'capture': {**case['capture'], 'size': [17, 8]}},
        'profile': {'capabilityProfile': {'maxTextureDimension2D': 0}},
        'backend': {'backend': 'WebGL2'},
        'error': {'error': 'unrelated shader compilation failed'},
        'host-input': {'hostTextures': [{'id': 'overlayTex'}]},
        'malformed-host-input': {'hostTextures': {'id': 'overlayTex'}},
    }
    for label, changes in invalid.items():
        bad = copy.deepcopy(failed_source)
        bad.update(changes)
        record, output = candidate(f'golden-bad-{label}', bad)
        assert record['status'] == 'fail' and record['stage'] == 'graph', (label, record)
        assert 'golden' in record['error'], (label, record)
        assert not record.get('images') and not list(output.rglob('*.png')), (label, record)
        assert record['hostTextures'] == [] and record['hostVolumes'] == [], (label, record)
    print('failed source golden: native control pixels unchanged; seven invalid ledgers refused')


def main():
    root = Path(__file__).resolve().parent.parent
    renderer = Path(os.environ['NM_RENDER_BIN']).resolve()
    seconds = int(os.environ.get('NM_CAPTURE_SECONDS', '1'))
    if seconds not in (1, 5) or not renderer.is_file():
        raise ValueError('NM_RENDER_BIN must exist and NM_CAPTURE_SECONDS must be 1 or 5')

    corpus = json.loads((root / 'parity/corpus.json').read_text())
    solid = next(item for item in corpus['cases'] if item['id'] == 'micro/solid')
    case = copy.deepcopy(solid)
    case['id'] = 'regression/timed-solid'
    case['capture'] = {
        'size': [16, 8],
        'sample': 'WebGPU presented surface',
        'orientation': 'top-down RGBA8 PNG',
        'resetState': True,
        'frameTime': '((frame + 1) / 600) % 1',
        'runSeconds': seconds,
        'sampleEverySeconds': 1,
        'sampleFrames': [1, 2, 4, 10, 30],
    }
    expected = sorted({1, 2, 4, 10, 30} | {600 * second for second in range(1, seconds + 1)})

    with tempfile.TemporaryDirectory(prefix='nm-timed-capture-') as directory:
        temporary = Path(directory)
        test_failed_golden_admission(root, renderer, temporary, solid)
        corpus_path = temporary / 'corpus.json'
        output = temporary / 'candidates'
        corpus_path.write_text(json.dumps({'schemaVersion': 1, 'cases': [case]}))
        result = subprocess.run([str(renderer), '--corpus', str(corpus_path), '--out-dir', str(output)],
                                cwd=root, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(f'nm-render failed ({result.returncode}): {result.stdout}\n{result.stderr}')
        ledger = json.loads((output / 'candidates.json').read_text())
        records = ledger['cases']
        assert len(records) == 1, records
        record = records[0]
        assert record['status'] == 'ok', record
        observed = sorted(image['frame'] for image in record['images'])
        assert observed == expected, f'expected frames {expected}, got {observed}'
        for image in record['images']:
            data = (output / image['path']).read_bytes()
            assert hashlib.sha256(data).hexdigest() == image['sha256']
            assert data[:8] == b'\x89PNG\r\n\x1a\n'
            assert (int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big')) == (16, 8)
        print(f'timed corpus CLI: {seconds * 600} rendered frames; PNG samples {observed}')

        # At frame 800 the source evaluates (800 / 600) % 1 before applying
        # saw(speed: 3). Taking the remainder first rounds to an exact cycle
        # boundary and turns the source's white pixel black.
        source_time = (800 / 600) % 1
        source_saw = 3 * source_time - math.floor(3 * source_time)
        assert source_saw > 0.99
        definition = json.dumps({
            'name': 'Saw Boundary', 'namespace': 'user', 'func': 'sawBoundary',
            'starter': True,
            'globals': {'value': {'type': 'float', 'default': 0, 'min': 0,
                                  'max': 1, 'uniform': 'value'}},
            'passes': [{'name': 'show', 'program': 'show', 'inputs': {},
                        'outputs': {'fragColor': 'outputTex'}}],
            'shaders': {'show': {}},
        }, separators=(',', ':'))
        wgsl = ('@group(0) @binding(0) var<uniform> value: f32;\n'
                '@fragment fn main() -> @location(0) vec4<f32> { '
                'return vec4<f32>(value, value, value, 1.0); }\n')
        source = ('search user\n'
                  'sawBoundary(value: osc(type: oscKind.saw, min: 0, max: 1, speed: 3))'
                  '.write(o0)\nrender(o0)\n')
        assets = [
            {'path': path, 'text': text, 'sha256': hashlib.sha256(text.encode()).hexdigest()}
            for path, text in [('regression/sawBoundary.portable.json', definition),
                               ('regression/sawBoundary.show.wgsl', wgsl)]
        ]
        saw_case = {
            'id': 'regression/timed-saw-boundary', 'source': source,
            'sourceSha256': hashlib.sha256(source.encode()).hexdigest(),
            'assets': assets,
            'capture': {
                'size': [16, 8], 'sample': 'WebGPU presented surface',
                'orientation': 'top-down RGBA8 PNG', 'resetState': True,
                'frameTime': '((frame + 1) / 600) % 1', 'runSeconds': 2,
                'sampleEverySeconds': 1, 'sampleFrames': [1, 800],
            },
        }
        saw_corpus = temporary / 'saw-corpus.json'
        saw_output = temporary / 'saw-candidates'
        saw_corpus.write_text(json.dumps({'schemaVersion': 1, 'cases': [saw_case]}))
        result = subprocess.run([str(renderer), '--corpus', str(saw_corpus),
                                 '--out-dir', str(saw_output)], cwd=root,
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(f'saw boundary render failed: {result.stdout}\n{result.stderr}')
        saw_records = json.loads((saw_output / 'candidates.json').read_text())['cases']
        assert len(saw_records) == 1 and saw_records[0]['status'] == 'ok', saw_records
        samples = {image['frame']: image for image in saw_records[0]['images']}
        assert set(samples) == {1, 600, 800, 1200}, samples
        with Image.open(saw_output / samples[800]['path']) as image:
            assert image.convert('RGBA').getpixel((8, 4)) == (255, 255, 255, 255), samples[800]
        print('timed saw boundary: source-order frame 800 is white')

        # Execute the pinned Pipeline.render deltaTime behavior across two
        # normalized-time wraps. lastTime == 0 forces a zero delta on the
        # frame immediately following each wrap (completed frames 601/1201).
        delta_definition = json.dumps({
            'name': 'Delta Echo', 'namespace': 'user', 'func': 'deltaEcho',
            'starter': True, 'globals': {},
            'passes': [{'name': 'show', 'program': 'show', 'inputs': {},
                        'outputs': {'fragColor': 'outputTex'}}],
            'shaders': {'show': {}},
        }, separators=(',', ':'))
        delta_wgsl = ('@group(0) @binding(0) var<uniform> deltaTime: f32;\n'
                      '@fragment fn main() -> @location(0) vec4<f32> { '
                      'let lit = select(0.0, 1.0, deltaTime > 0.0008); '
                      'return vec4<f32>(lit, lit, lit, 1.0); }\n')
        delta_source = 'search user\ndeltaEcho().write(o0)\nrender(o0)\n'
        delta_assets = [
            {'path': path, 'text': text, 'sha256': hashlib.sha256(text.encode()).hexdigest()}
            for path, text in [('regression/deltaEcho.portable.json', delta_definition),
                               ('regression/deltaEcho.show.wgsl', delta_wgsl)]
        ]
        delta_case = {
            'id': 'regression/timed-delta-echo', 'source': delta_source,
            'sourceSha256': hashlib.sha256(delta_source.encode()).hexdigest(),
            'assets': delta_assets,
            'capture': {
                'size': [16, 8], 'sample': 'WebGPU presented surface',
                'orientation': 'top-down RGBA8 PNG', 'resetState': True,
                'frameTime': '((frame + 1) / 600) % 1', 'runSeconds': 3,
                'sampleEverySeconds': 1,
                'sampleFrames': [600, 601, 602, 1200, 1201, 1202],
            },
        }
        delta_corpus = temporary / 'delta-corpus.json'
        delta_output = temporary / 'delta-candidates'
        delta_corpus.write_text(json.dumps({'schemaVersion': 1, 'cases': [delta_case]}))
        result = subprocess.run([str(renderer), '--corpus', str(delta_corpus),
                                 '--out-dir', str(delta_output)], cwd=root,
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(f'delta echo render failed: {result.stdout}\n{result.stderr}')
        delta_records = json.loads((delta_output / 'candidates.json').read_text())['cases']
        assert len(delta_records) == 1 and delta_records[0]['status'] == 'ok', delta_records
        delta_samples = {image['frame']: image for image in delta_records[0]['images']}
        expected_pixels = {600: 255, 601: 0, 602: 255, 1200: 255,
                           1201: 0, 1202: 255, 1800: 255}
        assert set(delta_samples) == set(expected_pixels), delta_samples
        actual_pixels = {}
        for frame, sample in delta_samples.items():
            with Image.open(delta_output / sample['path']) as image:
                actual_pixels[frame] = image.convert('RGBA').getpixel((8, 4))
        for frame, intensity in expected_pixels.items():
            assert actual_pixels[frame] == (intensity, intensity, intensity, 255), actual_pixels
        print('timed delta echo: source Pipeline.render wraps at frames 600 and 1200')


if __name__ == '__main__':
    main()
