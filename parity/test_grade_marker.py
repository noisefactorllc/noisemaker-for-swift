import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parent
GRADER = ROOT / 'grade-marker.py'
SIZE = (257, 129)


def marker():
    image = Image.new('RGBA', SIZE)
    pixels = image.load()
    for y in range(SIZE[1]):
        for x in range(SIZE[0]):
            source_y = SIZE[1] - 1 - y
            if x < 16 and source_y < 16:
                color = (255, 0, 0, 255)
            elif x >= 241 and source_y < 16:
                color = (0, 255, 0, 255)
            elif x < 16 and source_y >= 113:
                color = (0, 0, 255, 255)
            elif x >= 241 and source_y >= 113:
                color = (255, 255, 0, 255)
            else:
                color = (round(255 * (x + .5) / 257), round(255 * (source_y + .5) / 129),
                         round(255 * (1 - (x + .5) / 514)), 255)
            pixels[x, y] = color
    return image


class GradeMarkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.gold = self.dir / 'gold.png'
        self.candidate = self.dir / 'candidate.png'
        marker().save(self.gold)

    def grade(self):
        return subprocess.run([sys.executable, GRADER, self.gold, self.candidate],
                              capture_output=True, text=True)

    def test_identical_marker_passes(self):
        marker().save(self.candidate)
        result = self.grade()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['pass'])

    def test_wrong_size_fails(self):
        marker().resize((256, 129)).save(self.candidate)
        self.assertNotEqual(self.grade().returncode, 0)

    def test_horizontal_and_vertical_flips_fail(self):
        for transpose in (Image.Transpose.FLIP_LEFT_RIGHT, Image.Transpose.FLIP_TOP_BOTTOM):
            marker().transpose(transpose).save(self.candidate)
            self.assertNotEqual(self.grade().returncode, 0)

    def test_one_bad_alpha_or_color_fails(self):
        for color in ((0, 0, 255, 254), (0, 0, 250, 255)):
            image = marker()
            image.putpixel((4, 4), color)
            image.save(self.candidate)
            self.assertNotEqual(self.grade().returncode, 0)

    def test_uniform_golden_is_uninformative(self):
        Image.new('RGBA', SIZE, (0, 0, 0, 255)).save(self.gold)
        Image.new('RGBA', SIZE, (0, 0, 0, 255)).save(self.candidate)
        self.assertNotEqual(self.grade().returncode, 0)

    def test_missing_file_fails(self):
        self.assertNotEqual(self.grade().returncode, 0)


if __name__ == '__main__':
    unittest.main()
