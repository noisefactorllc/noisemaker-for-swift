import importlib.util
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


module_spec = importlib.util.spec_from_file_location(
    'qualification_fingerprint', Path(__file__).with_name('qualification-fingerprint.py'))
fingerprint = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(fingerprint)


class QualificationFingerprintTests(unittest.TestCase):
    def test_enabled_swiftshader_is_rejected(self):
        for value in ('1', 'true'):
            with self.subTest(value=value), patch.dict(os.environ, {'SHADE_SWIFTSHADER': value}):
                with self.assertRaisesRegex(ValueError, 'software WebGPU'):
                    fingerprint.reject_software_webgpu()
        for value in ('', '0', 'false'):
            with self.subTest(value=value), patch.dict(os.environ, {'SHADE_SWIFTSHADER': value}):
                fingerprint.reject_software_webgpu()

    def test_source_artifact_and_binary_drift_change_digest(self):
        with tempfile.TemporaryDirectory(prefix='nm-qualification-') as temporary:
            root = Path(temporary)
            (root / 'Sources').mkdir()
            (root / 'Artifacts').mkdir()
            for directory in ['tools', 'scripts', 'parity']:
                (root / directory).mkdir()
            (root / 'Package.swift').write_text('package')
            source = root / 'Sources/Compiler.swift'
            source.write_text('source')
            artifact = root / 'Artifacts/Translator.a'
            artifact.write_bytes(b'artifact')
            binary = root / 'nm-render'
            binary.write_bytes(b'binary')
            initial = fingerprint.snapshot(root, binary)
            self.assertEqual(initial, fingerprint.snapshot(root, binary))
            source.write_text('changed')
            self.assertNotEqual(initial['sources'], fingerprint.snapshot(root, binary)['sources'])
            source.write_text('source')
            artifact.write_bytes(b'changed')
            self.assertNotEqual(initial['artifacts'], fingerprint.snapshot(root, binary)['artifacts'])
            artifact.write_bytes(b'artifact')
            for directory, name in [('parity', 'batch-golden.mjs'), ('parity', 'grade-corpus.py'),
                                    ('parity', 'corpus.json'), ('tools', 'export-reference.mjs'),
                                    ('scripts', 'parity-summary')]:
                target = root / directory / name
                before = fingerprint.snapshot(root, binary)
                target.write_text('mutated authority or harness')
                self.assertNotEqual(before[directory], fingerprint.snapshot(root, binary)[directory])
                target.unlink()
            binary.write_bytes(b'changed')
            self.assertNotEqual(initial['binarySha256'], fingerprint.snapshot(root, binary)['binarySha256'])

    def test_external_source_manifest_and_browser_dependencies_drift(self):
        with tempfile.TemporaryDirectory(prefix='nm-external-authority-') as temporary:
            root = Path(temporary) / 'package'
            reference = Path(temporary) / 'reference'
            (root / 'parity').mkdir(parents=True)
            (root / '.build/reference').mkdir(parents=True)
            (reference / 'vendor/shade-mcp/harness').mkdir(parents=True)
            (reference / 'node_modules/playwright').mkdir(parents=True)
            harness = reference / 'vendor/shade-mcp/harness/index.js'
            harness.write_text('export const version = 1\n')
            name = 'vendor/shade-mcp/harness/index.js'
            source_sha = fingerprint.sha256(harness)
            manifest_sha = hashlib.sha256(f'{name}\0{source_sha}\n'.encode()).hexdigest()
            lock = {'repository': 'https://example.com/authority', 'commit': 'c' * 40,
                    'sourceManifestSha256': manifest_sha}
            (root / 'parity/reference.json').write_text(json.dumps(lock))
            manifest = {'repository': lock['repository'], 'commit': lock['commit'],
                        'contentSha256': manifest_sha,
                        'files': [{'path': name, 'sha256': source_sha}]}
            manifest_path = root / '.build/reference/source-manifest.json'
            manifest_path.write_text(json.dumps(manifest))
            (reference / 'package-lock.json').write_text('browser lock')
            dependency = reference / 'node_modules/playwright/index.js'
            dependency.write_text('browser code')
            browser = {'executableSha256': 'a' * 64, 'bundleSha256': 'b' * 64}
            baseline = fingerprint.authority_inputs(root, reference, browser)
            self.assertEqual(baseline, fingerprint.authority_inputs(root, reference, browser))
            harness.write_text('export const version = 2\n')
            with self.assertRaisesRegex(ValueError, 'reference source differs'):
                fingerprint.authority_inputs(root, reference, browser)
            harness.write_text('export const version = 1\n')
            dependency.write_text('altered browser code')
            self.assertNotEqual(baseline['nodeModules'],
                                fingerprint.authority_inputs(root, reference, browser)['nodeModules'])
            dependency.write_text('browser code')
            manifest_path.write_text(json.dumps(manifest, indent=2))
            self.assertNotEqual(baseline['sourceManifestFileSha256'],
                                fingerprint.authority_inputs(root, reference, browser)['sourceManifestFileSha256'])
            manifest_path.write_text(json.dumps(manifest))
            (reference / 'package-lock.json').write_text('altered browser lock')
            self.assertNotEqual(baseline['packageLockSha256'],
                                fingerprint.authority_inputs(root, reference, browser)['packageLockSha256'])

    def test_browser_executable_and_bundle_drift(self):
        with tempfile.TemporaryDirectory(prefix='nm-browser-bundle-') as temporary:
            bundle = Path(temporary) / 'chrome-headless-shell-mac-arm64'
            bundle.mkdir()
            executable = bundle / 'chrome-headless-shell'
            library = bundle / 'libGLESv2.dylib'
            executable.write_bytes(b'executable version one')
            library.write_bytes(b'library version one')
            baseline = fingerprint.browser_bundle(executable, True)
            self.assertEqual(baseline, fingerprint.browser_bundle(executable, True))
            executable.write_bytes(b'executable version two')
            changed = fingerprint.browser_bundle(executable, True)
            self.assertNotEqual(baseline['executableSha256'], changed['executableSha256'])
            executable.write_bytes(b'executable version one')
            library.write_bytes(b'library version two')
            changed = fingerprint.browser_bundle(executable, True)
            self.assertEqual(baseline['executableSha256'], changed['executableSha256'])
            self.assertNotEqual(baseline['bundleSha256'], changed['bundleSha256'])
            executable.unlink()
            with self.assertRaisesRegex(ValueError, 'executable is missing'):
                fingerprint.browser_bundle(executable, True)

    def test_pillow_grader_code_drift_changes_fingerprint(self):
        with tempfile.TemporaryDirectory(prefix='nm-pillow-grader-') as temporary:
            package = Path(temporary) / 'PIL'
            package.mkdir()
            decoder = package / 'Image.py'
            decoder.write_text('decoder version one')
            baseline = fingerprint.grader_inputs(package)
            self.assertTrue(baseline['python'])
            self.assertTrue(baseline['pillow'])
            decoder.write_text('decoder version two')
            self.assertNotEqual(baseline['pillowTree'],
                                fingerprint.grader_inputs(package)['pillowTree'])


if __name__ == '__main__':
    unittest.main()
