import importlib.util
import tempfile
import unittest
from pathlib import Path

from PIL import Image


MODULE = Path(__file__).with_name('grade-corpus.py')
SPEC = importlib.util.spec_from_file_location('grade_corpus', MODULE)
grader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(grader)


class CorpusImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.golden = Path(self.temp.name, 'golden.png')
        self.candidate = Path(self.temp.name, 'candidate.png')
        self.size = (17, 9)
        image = Image.new('RGBA', self.size)
        image.putdata([(x * 13, y * 29, (x * 7 + y * 11) % 256, 255)
                       for y in range(self.size[1]) for x in range(self.size[0])])
        image.save(self.golden)
        image.save(self.candidate)

    def test_exact_informative_variable_size(self):
        result = grader.compare(self.golden, self.candidate, self.size)
        self.assertTrue(result['pass'])
        self.assertTrue(result['informative'])
        self.assertTrue(result['exact'])

    def test_vertical_flip_fails(self):
        with Image.open(self.candidate) as image:
            image.transpose(Image.Transpose.FLIP_TOP_BOTTOM).save(self.candidate)
        self.assertFalse(grader.compare(self.golden, self.candidate, self.size)['pass'])

    def test_alpha_and_dimensions_are_checked(self):
        with Image.open(self.candidate) as image:
            altered = image.copy()
        altered.putpixel((1, 1), (13, 29, 18, 0))
        altered.save(self.candidate)
        self.assertFalse(grader.compare(self.golden, self.candidate, self.size)['pass'])
        Image.new('RGBA', (16, 9), (1, 2, 3, 255)).save(self.candidate)
        with self.assertRaisesRegex(ValueError, 'has size'):
            grader.compare(self.golden, self.candidate, self.size)

    def test_flat_reference_is_uninformative(self):
        Image.new('RGBA', self.size, (1, 2, 3, 255)).save(self.golden)
        result = grader.compare(self.golden, self.candidate, self.size)
        self.assertFalse(result['informative'])


if __name__ == '__main__':
    unittest.main()
