import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

module_spec = importlib.util.spec_from_file_location('verify_artifact', Path(__file__).with_name('verify-artifact.py'))
verifier = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(verifier)

class ArtifactIntegrityTests(unittest.TestCase):
    def test_committed_artifact_and_tamper_refusal(self):
        verifier.verify()
        with tempfile.TemporaryDirectory(prefix='nm-artifact-') as temporary:
            root = Path(temporary)
            shutil.copytree(verifier.ROOT / 'Artifacts', root / 'Artifacts')
            shutil.copytree(verifier.ROOT / 'tools/tint', root / 'tools/tint')
            shutil.copy2(verifier.ROOT / 'LICENSE', root / 'LICENSE')
            shutil.copytree(verifier.ROOT / 'Sources/CNoisemakerTint', root / 'Sources/CNoisemakerTint')
            shutil.copy2(verifier.ROOT / 'tools/build-tint.py', root / 'tools/build-tint.py')
            verifier.verify(root)
            shim = root / 'Sources/CNoisemakerTint/NoisemakerTint.cpp'
            original = shim.read_bytes()
            shim.write_bytes(original + b'\n// changed source\n')
            with self.assertRaisesRegex(RuntimeError, 'build input differs'):
                verifier.verify(root)
            shim.write_bytes(original)
            for name in verifier.PINNED_LICENSES:
                with self.subTest(notice=name):
                    notice = root / f'tools/tint/LICENSE-{name}.txt'
                    notice.write_bytes(notice.read_bytes() + b'changed')
                    with self.assertRaisesRegex(RuntimeError, 'dependency license differs from pinned source'):
                        verifier.verify(root)
                    shutil.copy2(verifier.ROOT / f'tools/tint/LICENSE-{name}.txt', notice)
            archive = root / 'Artifacts/CNoisemakerTint.xcframework/macos-arm64/libCNoisemakerTint.a'
            with archive.open('r+b') as file:
                file.seek(20)
                byte = file.read(1)
                file.seek(20)
                file.write(bytes([byte[0] ^ 1]))
            with self.assertRaisesRegex(RuntimeError, 'artifact hash differs'):
                verifier.verify(root)

if __name__ == '__main__':
    unittest.main()
