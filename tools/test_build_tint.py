import hashlib
import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('build_tint', Path(__file__).with_name('build-tint.py'))
build_tint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_tint)


class BuildTintSourceTests(unittest.TestCase):
    def make_archive(self, path, member_name, payload=b'hello', kind=tarfile.REGTYPE):
        with tarfile.open(path, 'w') as tar:
            member = tarfile.TarInfo(member_name)
            member.type = kind
            member.size = len(payload) if kind == tarfile.REGTYPE else 0
            if kind == tarfile.SYMTYPE:
                member.linkname = 'elsewhere'
            tar.addfile(member, io.BytesIO(payload) if kind == tarfile.REGTYPE else None)

    def test_regular_source_hash_is_verified_on_reuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / 'source.tar'
            destination = root / 'source'
            self.make_archive(archive, 'src/file.txt')
            build_tint.safe_extract(archive, destination)
            manifest = build_tint.archive_manifest(archive)
            build_tint.verify_source(destination, manifest)
            (destination / 'src/file.txt').write_text('tampered')
            with self.assertRaisesRegex(RuntimeError, 'source hash differs'):
                build_tint.verify_source(destination, manifest)

    def test_archive_path_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / 'bad.tar'
            self.make_archive(archive, '../escape')
            with self.assertRaisesRegex(RuntimeError, 'unsafe archive path'):
                build_tint.safe_extract(archive, root / 'source')
            self.assertFalse((root / 'escape').exists())

    def test_archive_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / 'bad.tar'
            self.make_archive(archive, 'link', kind=tarfile.SYMTYPE)
            with self.assertRaisesRegex(RuntimeError, 'unsupported archive member'):
                build_tint.safe_extract(archive, root / 'source')


if __name__ == '__main__':
    unittest.main()
