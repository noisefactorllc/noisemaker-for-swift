#!/usr/bin/env python3
"""Strict variable-size RGBA8 presented-surface parity grading."""

from collections import Counter
from math import sqrt
from pathlib import Path
from PIL import Image

MAX_ERROR = 2.001
MIN_SSIM = 0.98


def pixels(path, expected_size):
    path = Path(path)
    if not path.is_file() or path.suffix.lower() != '.png':
        raise ValueError(f'missing PNG: {path}')
    with Image.open(path) as image:
        image.load()
        if image.size != tuple(expected_size):
            raise ValueError(f'{path} has size {image.size}, expected {tuple(expected_size)}')
        if image.mode not in ('RGB', 'RGBA'):
            raise ValueError(f'{path} has unsupported mode {image.mode}')
        rgba = image.convert('RGBA')
        return list(rgba.get_flattened_data() if hasattr(rgba, 'get_flattened_data') else rgba.getdata())


def luminance(pixel):
    return (.2126 * pixel[0] + .7152 * pixel[1] + .0722 * pixel[2]) * pixel[3] / 255


def compare(golden_path, candidate_path, size):
    golden = pixels(golden_path, size)
    candidate = pixels(candidate_path, size)
    if len(golden) != size[0] * size[1] or len(candidate) != len(golden):
        raise ValueError('incomplete RGBA8 image')
    count = len(golden)
    dominant = Counter(golden).most_common(1)[0][1] / count
    sums = [0.0] * 5
    maximum = 0
    for left, right in zip(golden, candidate):
        x, y = luminance(left), luminance(right)
        sums[0] += x
        sums[1] += y
        sums[2] += x * x
        sums[3] += y * y
        sums[4] += x * y
        maximum = max(maximum, *(abs(a - b) for a, b in zip(left, right)))
    mean_x, mean_y = sums[0] / count, sums[1] / count
    variance_x = sums[2] / count - mean_x * mean_x
    variance_y = sums[3] / count - mean_y * mean_y
    covariance = sums[4] / count - mean_x * mean_y
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    score = ((2 * mean_x * mean_y + c1) * (2 * covariance + c2)) / (
        (mean_x * mean_x + mean_y * mean_y + c1) * (variance_x + variance_y + c2))
    spread = sqrt(max(variance_x, 0))
    informative = dominant < .99 and spread >= 1
    return {'maxChannelError': maximum, 'ssim': score, 'dominantPixelFraction': dominant,
            'luminanceDeviation': spread, 'informative': informative,
            'exact': maximum == 0, 'pass': maximum <= MAX_ERROR and score >= MIN_SSIM}
