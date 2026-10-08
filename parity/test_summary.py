import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('summarize', ROOT / 'parity/summarize.py')
summarize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summarize)


class SummaryBoundaryTests(unittest.TestCase):
    def refusal_pair(self):
        corpus = json.loads((ROOT / 'parity/corpus.json').read_text())
        item = next(case for case in corpus['cases'] if case['id'] == 'qtPrograms/funcChainScoped')
        source_error = ("page.waitForFunction: Error: reference DSL failed: compilation failed: "
                        "GPUDevice.createTexture rejected GPUExtent3DDict height: value is not of type unsigned long")
        golden = {'id': item['id'], 'sourceSha256': item['sourceSha256'],
                  'capture': item['capture'], 'status': 'fail', 'error': source_error,
                  'capabilityProfile': {'maxTextureDimension2D': 8192}}
        candidate = {'id': item['id'], 'sourceSha256': item['sourceSha256'], 'backend': 'Metal',
                     'stage': 'graph', 'status': 'fail',
                     'error': 'Unsupported graph semantics: texture dimension parameter zoom_chain_0 is not a finite number',
                     'capabilityProfile': {'maxTextureDimension2D': 8192}}
        refusal = json.loads((ROOT / 'parity/source-refusals.json').read_text())['cases'][0]
        return item, golden, candidate, refusal

    def test_source_refusal_class_and_diagnostic_variations(self):
        _, golden, candidate, _ = self.refusal_pair()
        self.assertTrue(summarize.source_refusal_matches(golden))
        self.assertTrue(summarize.native_refusal_matches(candidate, 'zoom_chain_0'))
        variant = {**golden, 'error': 'Compilation failed: GPUDevice.createTexture invalid height (non-finite)'}
        self.assertTrue(summarize.source_refusal_matches(variant))
        native_variant = {**candidate,
                          'error': "Texture dimension parameter 'zoom_chain_0' is non-finite"}
        self.assertTrue(summarize.native_refusal_matches(native_variant, 'zoom_chain_0'))
        self.assertFalse(summarize.source_refusal_matches({**golden,
            'error': 'compilation failed: WGSL shader module is invalid'}))
        self.assertFalse(summarize.native_refusal_matches({**candidate,
            'error': 'texture dimension parameter stateSize_node_1 is not a finite number'}, 'zoom_chain_0'))
        self.assertFalse(summarize.native_refusal_matches({**candidate, 'status': 'ok'}, 'zoom_chain_0'))

    def test_capability_profile_is_required_and_exact(self):
        _, golden, candidate, _ = self.refusal_pair()
        summarize.verify_capability_profile(golden, candidate)
        with self.assertRaisesRegex(ValueError, 'reference lacks'):
            summarize.verify_capability_profile({**golden, 'capabilityProfile': None}, candidate)
        with self.assertRaisesRegex(ValueError, 'candidate lacks'):
            summarize.verify_capability_profile(golden, {**candidate, 'capabilityProfile': {'maxTextureDimension2D': True}})
        with self.assertRaisesRegex(ValueError, 'differs from reference'):
            summarize.verify_capability_profile(golden, {**candidate, 'capabilityProfile': {'maxTextureDimension2D': 16384}})

    def test_sampled_volume_requires_exact_binary_and_identity(self):
        corpus = json.loads((ROOT / 'parity/corpus.json').read_text())
        item = next(case for case in corpus['cases'] if case['id'] == 'micro/sampled3dProbe')
        contract = item['capture']['volumeInput']
        source = ROOT / contract['assetPath']
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            binary = output / 'volume.rgba8'
            binary.write_bytes(source.read_bytes())
            record = {**contract, 'sha256': contract['assetSha256']}
            golden = {'hostVolumes': [{**record, 'path': 'volume.rgba8'}]}
            candidate = {'hostVolumes': [record]}
            summarize.verify_volume_evidence(item, golden, candidate, output)
            with self.assertRaisesRegex(ValueError, 'inventory differs'):
                summarize.verify_volume_evidence(item, golden, {'hostVolumes': []}, output)
            with self.assertRaisesRegex(ValueError, 'native host volume identity'):
                summarize.verify_volume_evidence(item, golden,
                    {'hostVolumes': [{**record, 'depth': 7}]}, output)
            binary.write_bytes(bytes([1]) + binary.read_bytes()[1:])
            with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
                summarize.verify_volume_evidence(item, golden, candidate, output)

    def test_refusal_inventory_provenance_and_no_pixel_credit(self):
        corpus = json.loads((ROOT / 'parity/corpus.json').read_text())
        lock = json.loads((ROOT / 'parity/reference.json').read_text())
        refusals = json.loads((ROOT / 'parity/source-refusals.json').read_text())
        inventory = summarize.refusal_inventory(refusals, corpus, lock)
        self.assertEqual(len(inventory), 3)
        with self.assertRaisesRegex(ValueError, 'source refusal oracle'):
            summarize.refusal_inventory({**refusals, 'corpusSha256': 'stale'}, corpus, lock)
        with self.assertRaisesRegex(ValueError, 'source refusal oracle case'):
            summarize.refusal_inventory({**refusals, 'cases': [
                {**refusals['cases'][0], 'sourceSha256': 'stale'}]}, corpus, lock)
        item, golden, candidate, refusal = self.refusal_pair()
        stages = json.loads((ROOT / 'parity/corpus-stages.json').read_text())
        graph_stage = next(case for case in stages['cases'] if case['id'] == item['id'])
        catalog = json.loads((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            def grade(expected):
                return summarize.count([item], {'expected': 1, 'cases': [golden]},
                    {'expected': 1, 'cases': [candidate]},
                    {'expected': 1, 'cases': [graph_stage]}, catalog,
                    directory, directory, expected)
            summary, details, _ = grade({item['id']: refusal})
            self.assertEqual((summary['expected'], summary['renderable'],
                              summary['refusal_equivalent'], summary['exact'],
                              summary['strict'], summary['effects_evidenced']),
                             (1, 0, 1, 0, 0, 0))
            self.assertEqual(details[0]['bucket'], 'refusal')
            golden['error'] = 'compilation failed: WGSL shader module is invalid'
            wrong_class, _, _ = grade({item['id']: refusal})
            self.assertEqual((wrong_class['refusal_equivalent'], wrong_class['fail']), (0, 1))
            golden['error'] = self.refusal_pair()[1]['error']
            candidate['status'] = 'ok'
            rendered, _, _ = grade({item['id']: refusal})
            self.assertEqual((rendered['refusal_equivalent'], rendered['fail']), (0, 1))
            candidate['status'] = 'fail'
            # Removing the refusal oracle cannot turn a failed reference render green.
            missing, details, _ = grade({})
            self.assertEqual((missing['refusal_equivalent'], missing['fail']), (0, 1))
            self.assertEqual(details[0]['bucket'], 'fail')

    def test_flat_smoke_fixtures_require_independent_effect_evidence(self):
        full = {'expected': 2, 'renderable': 2, 'refusal_expected': 0,
                'refusal_equivalent': 0, 'refusal': 0, 'exact': 1,
                'strict': 0, 'fail': 0, 'missing': 0, 'skip': 0, 'near': 0,
                'defer': 0, 'uninformative': 1, 'effects': 1,
                'effects_evidenced': 1}
        # Architecture section 4 retains flat smoke fixtures in the denominator;
        # only the separate informative case supplies effect evidence.
        self.assertTrue(summarize.qualified(full, requested=[]))
        self.assertEqual((full['exact'], full['uninformative']), (1, 1))
        self.assertFalse(summarize.qualified({**full, 'effects_evidenced': 0}, requested=[]))
        self.assertFalse(summarize.qualified({**full, 'expected': 3}, requested=[]))
        self.assertFalse(summarize.qualified(full, requested=['flat', 'structured']))
        for failure in ('near', 'fail', 'skip', 'missing', 'defer', 'refusal'):
            self.assertFalse(summarize.qualified({**full, failure: 1}, requested=[]), failure)

    def test_matching_source_and_native_refusals_never_qualify_full_gate(self):
        expected = len(json.loads((ROOT / 'parity/corpus.json').read_text())['cases'])
        full = {'expected': expected, 'renderable': expected - 3, 'refusal_expected': 3,
                'refusal_equivalent': 3, 'refusal': 3, 'exact': expected - 3,
                'strict': 0, 'fail': 0, 'missing': 0, 'skip': 0, 'near': 0,
                'defer': 0, 'uninformative': 0, 'effects': 210,
                'effects_evidenced': 210}
        self.assertFalse(summarize.qualified(full, requested=[]))
        self.assertFalse(summarize.qualified({**full, 'expected': 1,
                                             'renderable': 0, 'exact': 0,
                                             'refusal_expected': 1,
                                             'refusal_equivalent': 1,
                                             'refusal': 1}, requested=['qtPrograms/funcChainScoped']))
        renderable = {**full, 'renderable': expected, 'refusal_expected': 0,
                      'refusal_equivalent': 0, 'refusal': 0, 'exact': expected}
        self.assertTrue(summarize.qualified(renderable, requested=[]))
        self.assertFalse(summarize.qualified({**renderable, 'effects_evidenced': 209}, requested=[]))
        with tempfile.TemporaryDirectory() as temporary:
            golden = Path(temporary, 'goldens')
            candidate = Path(temporary, 'candidates')
            golden.mkdir()
            candidate.mkdir()
            corpus_hash = hashlib.sha256((ROOT / 'parity/corpus.json').read_bytes()).hexdigest()
            lock = json.loads((ROOT / 'parity/reference.json').read_text())
            (golden / 'goldens.json').write_text(json.dumps({
                'corpusSha256': corpus_hash, 'authority': lock}))
            (candidate / 'candidates.json').write_text(json.dumps({'corpusSha256': corpus_hash}))
            output = io.StringIO()
            with patch.object(summarize, 'count', return_value=(full, [], [])), \
                 patch.object(sys, 'argv', ['summarize.py', str(golden), str(candidate)]), \
                 redirect_stdout(output):
                self.assertEqual(summarize.main(), 1)
            self.assertIn('PARITY-SUMMARY ', output.getvalue())

    def test_cpu_hooks_require_native_evidence_not_host_replay(self):
        catalog = json.loads((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaisesRegex(ValueError, 'native CPU effect evidence'):
                summarize.verify_input_evidence({'filter.fibers'}, {'hostTextures': []},
                    {'hostTextures': [], 'nativeCpuEffects': []}, catalog, directory)
            summarize.verify_input_evidence({'filter.fibers'}, {'hostTextures': []},
                {'hostTextures': [], 'nativeCpuEffects': ['filter.fibers']}, catalog, directory)
            with self.assertRaisesRegex(ValueError, 'native CPU effect evidence'):
                summarize.verify_input_evidence({'filter.fibers'}, {'hostTextures': []},
                    {'hostTextures': [], 'nativeCpuEffects': ['filter.text']}, catalog, directory)

    def test_external_text_input_requires_exact_binary_metadata(self):
        catalog = json.loads((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            payload = bytes([10, 20, 30, 255])
            (directory / 'text.rgba8').write_bytes(payload)
            entry = {'id': 'textTex_step_1', 'frame': 0, 'path': 'text.rgba8',
                     'sha256': hashlib.sha256(payload).hexdigest(), 'width': 1, 'height': 1,
                     'format': 'rgba8unorm', 'orientation': 'top-down', 'bytesPerRow': 4}
            replay = {key: value for key, value in entry.items() if key != 'path'}
            candidate = {'hostTextures': [replay], 'hostInputMode': 'referenceReplay',
                         'nativeCpuEffects': []}
            summarize.verify_input_evidence({'filter.text'}, {'hostTextures': [entry]},
                candidate, catalog, directory)
            bad = {**candidate, 'hostTextures': [{**replay, 'orientation': 'bottom-up'}]}
            with self.assertRaisesRegex(ValueError, 'identity, format, dimensions'):
                summarize.verify_input_evidence({'filter.text'}, {'hostTextures': [entry]},
                    bad, catalog, directory)

    def test_audio_effect_requires_exact_host_samples(self):
        catalog = json.loads((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_text())
        asset = ROOT / 'parity/inputs/audio-v1.json'
        payload = json.loads(asset.read_text())
        evidence = {'frame': 0, 'assetPath': 'parity/inputs/audio-v1.json',
                    'assetSha256': hashlib.sha256(asset.read_bytes()).hexdigest(),
                    'updatePolicy': 'static-before-frame-1',
                    'waveformF32Sha256': payload['waveformF32']['sha256'],
                    'spectrumF32Sha256': payload['spectrumF32']['sha256']}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            zero_hash = hashlib.sha256(bytes(512)).hexdigest()
            golden = {'hostTextures': [], 'hostAudio': evidence,
                      'audioBindingEffectiveSha256': zero_hash}
            candidate = {'hostTextures': [], 'nativeCpuEffects': [], 'hostAudio': evidence,
                         'audioBindingEffectiveSha256': zero_hash}
            summarize.verify_input_evidence({'synth.scope'}, golden, candidate, catalog, directory)
            with self.assertRaisesRegex(ValueError, 'effective audio uniform bytes'):
                summarize.verify_input_evidence({'synth.scope'},
                    {**golden, 'audioBindingEffectiveSha256': payload['waveformF32']['sha256']},
                    candidate, catalog, directory)
            plain = {**evidence, 'representation': 'plain-array'}
            summarize.verify_input_evidence({'synth.scope'},
                {**golden, 'capture': {'audioInput': {'representation': 'plain-array'}},
                 'hostAudio': plain, 'audioBindingEffectiveSha256': payload['waveformF32']['sha256']},
                {**candidate, 'hostAudio': plain,
                 'audioBindingEffectiveSha256': payload['waveformF32']['sha256']}, catalog, directory)
            with self.assertRaisesRegex(ValueError, 'effective audio uniform bytes'):
                summarize.verify_input_evidence({'synth.scope'},
                    {**golden, 'capture': {'audioInput': {'representation': 'plain-array'}},
                     'hostAudio': plain}, {**candidate, 'hostAudio': plain}, catalog, directory)
            with self.assertRaisesRegex(ValueError, 'host sample identity'):
                summarize.verify_input_evidence({'synth.scope'}, golden,
                    {**candidate, 'hostAudio': {**evidence, 'frame': 1}}, catalog, directory)
            with self.assertRaisesRegex(ValueError, 'lacks host sample'):
                summarize.verify_input_evidence({'synth.spectrum'}, {'hostTextures': []},
                    candidate, catalog, directory)
            with self.assertRaisesRegex(ValueError, 'no source audio effect'):
                summarize.verify_input_evidence({'synth.solid'}, golden,
                    candidate, catalog, directory)

    def test_zero_bound_audio_pixel_match_does_not_evidence_effect(self):
        corpus = json.loads((ROOT / 'parity/corpus.json').read_text())
        item = next(case for case in corpus['cases'] if case['id'] == 'coverage/synth_scope')
        stages = json.loads((ROOT / 'parity/corpus-stages.json').read_text())
        stage = next(case for case in stages['cases'] if case['id'] == item['id'])
        catalog = json.loads((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_text())
        asset = ROOT / 'parity/inputs/audio-v1.json'
        payload = json.loads(asset.read_text())
        audio = {'frame': 0, 'assetPath': 'parity/inputs/audio-v1.json',
                 'assetSha256': hashlib.sha256(asset.read_bytes()).hexdigest(),
                 'updatePolicy': 'static-before-frame-1',
                 'waveformF32Sha256': payload['waveformF32']['sha256'],
                 'spectrumF32Sha256': payload['spectrumF32']['sha256']}
        zero_hash = hashlib.sha256(bytes(512)).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            png = directory / 'audio.png'
            image = Image.new('RGBA', (256, 256))
            for y in range(128, 131):
                for x in range(256):
                    image.putpixel((x, y), (0, 255, 0, 255))
            image.save(png)
            descriptor = {'frame': 8, 'path': str(png),
                          'sha256': hashlib.sha256(png.read_bytes()).hexdigest()}
            golden = {'id': item['id'], 'sourceSha256': item['sourceSha256'],
                      'capture': item['capture'], 'status': 'ok', 'backend': 'WebGPU', 'hostTextures': [],
                      'capabilityProfile': {'maxTextureDimension2D': 8192},
                      'hostAudio': audio, 'audioBindingEffectiveSha256': zero_hash,
                      'images': [descriptor]}
            candidate = {'id': item['id'], 'sourceSha256': item['sourceSha256'],
                         'status': 'ok', 'backend': 'Metal', 'effects': stage['effects'],
                         'capabilityProfile': {'maxTextureDimension2D': 8192},
                         'hostTextures': [], 'nativeCpuEffects': [], 'hostAudio': audio,
                         'audioBindingEffectiveSha256': zero_hash, 'images': [descriptor]}
            summary, details, _ = summarize.count([item], {'expected': 1, 'cases': [golden]},
                {'expected': 1, 'cases': [candidate]}, {'expected': 1, 'cases': [stage]},
                catalog, directory, directory, {})
            self.assertTrue(details[0]['samples'][0]['pass'])
            self.assertEqual((summary['uninformative'], summary['effects_evidenced']), (1, 0))
            self.assertFalse(details[0]['audioSignalBound'])

    def test_selected_green_is_probe_not_family_gate(self):
        corpus_path = ROOT / 'parity/corpus.json'
        corpus = json.loads(corpus_path.read_text())
        item = next(case for case in corpus['cases'] if case['id'] == 'micro/marker')
        corpus_hash = hashlib.sha256(corpus_path.read_bytes()).hexdigest()
        lock = json.loads((ROOT / 'parity/reference.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            golden = Path(temporary, 'goldens')
            candidate = Path(temporary, 'candidates')
            golden.mkdir()
            candidate.mkdir()
            width, height = item['capture']['size']
            pixels = Image.new('RGBA', (width, height))
            pixels.putdata([(x % 256, y % 256, (x + y) % 256, 255)
                            for y in range(height) for x in range(width)])
            for directory, backend in ((golden, 'WebGPU'), (candidate, 'Metal')):
                image_path = directory / 'marker.frame8.png'
                pixels.save(image_path)
                image_hash = hashlib.sha256(image_path.read_bytes()).hexdigest()
                case = {'id': item['id'], 'sourceSha256': item['sourceSha256'],
                        'status': 'ok', 'backend': backend, 'effects': ['user.marker'],
                        'capabilityProfile': {'maxTextureDimension2D': 8192},
                        'images': [{'frame': 8, 'path': str(image_path), 'sha256': image_hash}]}
                if backend == 'WebGPU':
                    case['capture'] = item['capture']
                ledger = {'schemaVersion': 1, 'corpusSha256': corpus_hash,
                          'expected': 1, 'cases': [case]}
                if backend == 'WebGPU':
                    ledger['authority'] = lock
                (directory / ('goldens.json' if backend == 'WebGPU' else 'candidates.json')).write_text(
                    json.dumps(ledger))
            command = [sys.executable, str(ROOT / 'parity/summarize.py'), str(golden), str(candidate)]
            selected = subprocess.run(command + [item['id']], text=True, capture_output=True)
            self.assertEqual(selected.returncode, 0, selected.stderr)
            self.assertIn('PARITY-PROBE ', selected.stdout)
            self.assertNotIn('PARITY-SUMMARY ', selected.stdout)
            full = subprocess.run(command, text=True, capture_output=True)
            self.assertNotEqual(full.returncode, 0)
            self.assertIn('PARITY-SUMMARY ', full.stdout)
            self.assertNotIn(f'"executed":{len(corpus["cases"])}', full.stdout)


if __name__ == '__main__':
    unittest.main()
