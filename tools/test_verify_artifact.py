import importlib.util
import hashlib
import json
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

    def test_raster_artifact_provenance_and_tamper_refusal(self):
        verifier.verify_raster()
        with tempfile.TemporaryDirectory(prefix='nm-raster-artifact-') as temporary:
            root = Path(temporary)
            for directory in ['Artifacts/CNoisemakerRaster.xcframework',
                              'Sources/CNoisemakerRaster', 'tools/raster', 'parity/overlays']:
                shutil.copytree(verifier.ROOT / directory, root / directory)
            for name in ['Artifacts/raster.json', 'tools/raster.json',
                         'tools/build-raster.py', 'tools/raster-api-test.cpp',
                         'tools/raster-smoke.cpp', 'parity/grade-overlays.py',
                         'parity/reference.json']:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(verifier.ROOT / name, target)
            verifier.verify_raster(root)
            shim = root / 'Sources/CNoisemakerRaster/NoisemakerRaster.cpp'
            shim.write_bytes(shim.read_bytes() + b'\n// altered\n')
            with self.assertRaisesRegex(RuntimeError, 'raster build input differs'):
                verifier.verify_raster(root)
            shutil.copy2(verifier.ROOT / 'Sources/CNoisemakerRaster/NoisemakerRaster.cpp', shim)
            license = root / 'tools/raster/LICENSE-skia.txt'
            license.write_bytes(license.read_bytes() + b'altered')
            with self.assertRaisesRegex(RuntimeError, 'raster license differs'):
                verifier.verify_raster(root)
            artifact_license = root / 'Artifacts/CNoisemakerRaster.xcframework/LICENSE-skia.txt'
            artifact_license.write_bytes(license.read_bytes())
            manifest_path = root / 'Artifacts/raster.json'
            original_manifest = manifest_path.read_bytes()
            manifest = json.loads(original_manifest)
            forged_sha = hashlib.sha256(license.read_bytes()).hexdigest()
            manifest['licenseSha256'] = forged_sha
            manifest['files']['LICENSE-skia.txt'] = forged_sha
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(RuntimeError, 'source provenance differs from pin'):
                verifier.verify_raster(root)
            manifest_path.write_bytes(original_manifest)
            shutil.copy2(verifier.ROOT / 'Artifacts/CNoisemakerRaster.xcframework/LICENSE-skia.txt', artifact_license)
            shutil.copy2(verifier.ROOT / 'tools/raster/LICENSE-skia.txt', license)
            archive = root / 'Artifacts/CNoisemakerRaster.xcframework/macos-arm64/libCNoisemakerRaster.a'
            with archive.open('r+b') as file:
                file.seek(20)
                byte = file.read(1)
                file.seek(20)
                file.write(bytes([byte[0] ^ 1]))
            with self.assertRaisesRegex(RuntimeError, 'raster artifact hash differs'):
                verifier.verify_raster(root)

if __name__ == '__main__':
    unittest.main()
