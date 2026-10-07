#!/usr/bin/env python3
"""Grade the same-run asymmetric presented-surface marker capture."""

import hashlib
import json
import math
import sys
from collections import Counter
from pathlib import Path

from PIL import Image


SIZE = (257, 129)
CORNERS = {
    'topLeft': ((4, 4), (0, 0, 255)),
    'topRight': ((252, 4), (255, 255, 0)),
    'bottomLeft': ((4, 124), (255, 0, 0)),
    'bottomRight': ((252, 124), (0, 255, 0)),
}
MAX_ERROR = 2.001
MIN_SSIM = .98


def image_data(path):
    path = Path(path)
    if not path.is_file():
        raise ValueError(f'missing image: {path}')
    if path.suffix.lower() != '.png':
        raise ValueError(f'expected PNG: {path}')
    with Image.open(path) as opened:
        opened.load()
        if opened.size != SIZE:
            raise ValueError(f'{path} has size {opened.size}, expected {SIZE}')
        if opened.mode not in ('RGB', 'RGBA'):
            raise ValueError(f'{path} has unsupported pixel mode {opened.mode}')
        image = opened.convert('RGBA')
    pixels = list(image.get_flattened_data() if hasattr(image, 'get_flattened_data') else image.getdata())
    if any(pixel[3] != 255 for pixel in pixels):
        raise ValueError(f'{path} has nonopaque alpha')
    for name, (point, expected) in CORNERS.items():
        actual = image.getpixel(point)[:3]
        if max(abs(a - b) for a, b in zip(actual, expected)) > MAX_ERROR:
            raise ValueError(f'{path} {name} is {actual}, expected {expected}; possible flip or color error')
    center = image.getpixel((128, 64))[:3]
    if max(abs(a - b) for a, b in zip(center, (128, 128, 191))) > 3:
        raise ValueError(f'{path} center gradient is {center}, expected near (128, 128, 191)')
    return pixels


def luminance(pixel):
    return .2126 * pixel[0] + .7152 * pixel[1] + .0722 * pixel[2]


def ssim(reference, candidate):
    count = len(reference)
    sums = [0.0] * 5
    for left, right in zip(reference, candidate):
        x, y = luminance(left), luminance(right)
        sums[0] += x
        sums[1] += y
        sums[2] += x * x
        sums[3] += y * y
        sums[4] += x * y
    mean_x, mean_y = sums[0] / count, sums[1] / count
    variance_x = sums[2] / count - mean_x * mean_x
    variance_y = sums[3] / count - mean_y * mean_y
    covariance = sums[4] / count - mean_x * mean_y
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    score = ((2 * mean_x * mean_y + c1) * (2 * covariance + c2)) / (
        (mean_x * mean_x + mean_y * mean_y + c1) * (variance_x + variance_y + c2))
    return score, math.sqrt(max(variance_x, 0))


def grade(golden, candidate):
    reference = image_data(golden)
    rendered = image_data(candidate)
    if len(reference) != SIZE[0] * SIZE[1]:
        raise ValueError('incomplete marker image')
    dominant = Counter(reference).most_common(1)[0][1] / len(reference)
    if dominant >= .99:
        raise ValueError(f'uninformative golden: dominant pixel fraction {dominant:.4f}')
    score, spread = ssim(reference, rendered)
    if spread < 1:
        raise ValueError(f'uninformative golden: luminance deviation {spread:.4f}')
    max_difference = max(abs(a - b) for left, right in zip(reference, rendered)
                         for a, b in zip(left, right))
    report = {
        'case': 'marker', 'size': list(SIZE),
        'goldenSha256': hashlib.sha256(Path(golden).read_bytes()).hexdigest(),
        'candidateSha256': hashlib.sha256(Path(candidate).read_bytes()).hexdigest(),
        'maxChannelError': max_difference, 'ssim': score,
        'goldenLuminanceDeviation': spread, 'goldenDominantPixelFraction': dominant,
        'thresholds': {'maxChannelError': MAX_ERROR, 'ssim': MIN_SSIM},
        'pass': max_difference <= MAX_ERROR and score >= MIN_SSIM,
    }
    return report


def main():
    if len(sys.argv) not in (3, 4):
        print('usage: grade-marker.py <golden.png> <candidate.png> [result.json]', file=sys.stderr)
        return 2
    try:
        report = grade(sys.argv[1], sys.argv[2])
        payload = json.dumps(report, sort_keys=True, indent=2) + '\n'
        if len(sys.argv) == 4:
            Path(sys.argv[3]).write_text(payload)
        sys.stdout.write(payload)
        return 0 if report['pass'] else 1
    except (OSError, ValueError) as error:
        print(f'MARKER-PARITY: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
