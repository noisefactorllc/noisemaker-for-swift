import importlib.util
import json
import pathlib
import shutil
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("grade_overlays", ROOT / "grade-overlays.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OverlayGraderTests(unittest.TestCase):
    def test_exact_and_one_byte_mutant(self):
        oracle = ROOT / "overlays"
        ledger = json.loads((oracle / "oracle.json").read_text())
        with tempfile.TemporaryDirectory() as temporary:
            candidates = pathlib.Path(temporary)
            for case in ledger["cases"]:
                shutil.copyfile(oracle / case["file"], candidates / case["file"])
            result = module.grade(candidates, oracle)
            self.assertEqual(result["exact"], len(ledger["cases"]))
            first = candidates / ledger["cases"][0]["file"]
            bytes_ = bytearray(first.read_bytes())
            bytes_[0] ^= 1
            first.write_bytes(bytes_)
            mutant = module.grade(candidates, oracle)
            self.assertEqual(mutant["exact"], len(ledger["cases"]) - 1)
            self.assertEqual(mutant["cases"][0]["maxChannelError"], 1)


if __name__ == "__main__":
    unittest.main()
