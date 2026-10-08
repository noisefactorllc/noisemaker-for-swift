import importlib.util
from pathlib import Path
import tempfile
import unittest


module_spec = importlib.util.spec_from_file_location(
    'qualification_fingerprint', Path(__file__).with_name('qualification-fingerprint.py'))
fingerprint = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(fingerprint)


class QualificationFingerprintTests(unittest.TestCase):
    def test_source_artifact_and_binary_drift_change_digest(self):
        with tempfile.TemporaryDirectory(prefix='nm-qualification-') as temporary:
            root = Path(temporary)
            (root / 'Sources').mkdir()
            (root / 'Artifacts').mkdir()
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
            binary.write_bytes(b'changed')
            self.assertNotEqual(initial['binarySha256'], fingerprint.snapshot(root, binary)['binarySha256'])


if __name__ == '__main__':
    unittest.main()
