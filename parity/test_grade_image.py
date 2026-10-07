import importlib.util
import tempfile
import unittest
from pathlib import Path

from PIL import Image


MODULE = Path(__file__).with_name('grade-image.py')
SPEC = importlib.util.spec_from_file_location('grade_image', MODULE)
grade_image = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(grade_image)


class ImageParityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.golden = Path(self.temp.name, 'golden.png')
        self.candidate = Path(self.temp.name, 'candidate.png')
        image = Image.new('RGBA', grade_image.SIZE)
        image.putdata([(x % 256, y % 256, (x + y) % 256, 255)
                       for y in range(grade_image.SIZE[1]) for x in range(grade_image.SIZE[0])])
        image.save(self.golden)
        image.save(self.candidate)

    def test_exact_source_image_passes(self):
        report = grade_image.grade('computeFilter', self.golden, self.candidate)
        self.assertTrue(report['pass'])
        self.assertEqual(report['maxChannelError'], 0)
        self.assertAlmostEqual(report['ssim'], 1)

    def test_flip_fails(self):
        image = Image.open(self.candidate)
        image.transpose(Image.Transpose.FLIP_TOP_BOTTOM).save(self.candidate)
        self.assertFalse(grade_image.grade('computeFilter', self.golden, self.candidate)['pass'])

    def test_wrong_size_and_alpha_fail(self):
        Image.new('RGBA', (256, 129), (1, 2, 3, 255)).save(self.candidate)
        with self.assertRaisesRegex(ValueError, 'has size'):
            grade_image.grade('computeFilter', self.golden, self.candidate)
        Image.new('RGBA', grade_image.SIZE, (1, 2, 3, 0)).save(self.candidate)
        with self.assertRaisesRegex(ValueError, 'nonopaque'):
            grade_image.grade('computeFilter', self.golden, self.candidate)

    def test_flat_golden_is_rejected(self):
        Image.new('RGBA', grade_image.SIZE, (1, 2, 3, 255)).save(self.golden)
        with self.assertRaisesRegex(ValueError, 'uninformative golden'):
            grade_image.grade('computeFilter', self.golden, self.candidate)


if __name__ == '__main__':
    unittest.main()
