#!/usr/bin/env python3
"""Fail-closed accounting for the complete same-run WebGPU versus Metal corpus."""

import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE = Path(__file__).with_name('grade-corpus.py')
SPEC = importlib.util.spec_from_file_location('grade_corpus', MODULE)
grade_corpus = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(grade_corpus)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def sample_frames(item):
    capture = item['capture']
    if 'frameTime' in capture:
        return sorted(set(capture['sampleFrames']) |
                      {600 * second for second in range(1, capture['runSeconds'] + 1)})
    return [capture['frames']]


def image_path(directory, descriptor):
    path = Path(descriptor['path'])
    if not path.is_absolute():
        path = directory / path
    path = path.resolve()
    if not path.is_relative_to(directory.resolve()):
        raise ValueError(f'image path escapes output directory: {path}')
    if sha256(path) != descriptor['sha256']:
        raise ValueError(f'image SHA256 mismatch: {path}')
    return path


def source_refusal_matches(record):
    if record.get('status') != 'fail' or record.get('backend', 'WebGPU') != 'WebGPU' or \
            record.get('images'):
        return False
    error = record.get('error', '')
    return bool(re.search(r'compilation failed', error, re.I) and
                re.search(r'createTexture', error, re.I) and
                re.search(r'height', error, re.I) and
                re.search(r'unsigned long|GPUExtent3D|invalid|non.?finite|not of type|integer', error, re.I))


def native_refusal_matches(record, parameter):
    if record.get('status') != 'fail' or record.get('backend') != 'Metal' or \
            record.get('stage') != 'graph' or record.get('images'):
        return False
    pattern = (r'texture dimension parameter\s+[\'"`]?'
               + re.escape(parameter) + r'[\'"`]?\s+(?:is\s+)?'
               + r'(?:not\s+(?:a\s+)?finite\s+number|non[-\s]?finite)')
    return bool(re.search(pattern, record.get('error', ''), re.I))


def verify_capability_profile(golden, candidate):
    for label, record in (('reference', golden), ('candidate', candidate)):
        profile = record.get('capabilityProfile')
        limit = profile.get('maxTextureDimension2D') if isinstance(profile, dict) else None
        if type(limit) is not int or not 256 <= limit <= 16384:
            raise ValueError(f'{label} lacks a valid texture capability profile')
    if golden['capabilityProfile'] != candidate['capabilityProfile']:
        raise ValueError('candidate texture capability profile differs from reference')


def refusal_inventory(refusals, corpus, lock):
    if refusals.get('schemaVersion') != 1 or \
            refusals.get('authorityCommit') != lock['commit'] or \
            refusals.get('sourceManifestSha256') != lock['sourceManifestSha256'] or \
            refusals.get('corpusSha256') != sha256(ROOT / 'parity/corpus.json'):
        raise ValueError('source refusal oracle differs from locked authority or corpus')
    by_id = {item['id']: item for item in corpus['cases']}
    entries = refusals.get('cases', [])
    if not isinstance(entries, list) or len(entries) != len({entry['id'] for entry in entries}):
        raise ValueError('source refusal oracle has duplicate or invalid case IDs')
    result = {}
    for entry in entries:
        item = by_id.get(entry['id'])
        if item is None or entry.get('sourceSha256') != item['sourceSha256'] or \
                entry.get('sourceFailure') != 'compile/createTexture/invalid-height' or \
                entry.get('nativeFailure') != 'graph/nonfinite-dimension' or \
                not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', entry.get('dimensionParameter', '')):
            raise ValueError(f"source refusal oracle case differs from corpus: {entry['id']}")
        result[entry['id']] = entry
    return result


def verify_input_evidence(source_effects, golden, candidate, catalog, golden_dir):
    definitions = {f"{effect['namespace']}.{effect['func']}": effect
                   for effect in catalog['effects']}
    native_required = {name for name in source_effects
                       if definitions.get(name, {}).get('lifecycle', {}).get('asyncInit') or
                       definitions.get(name, {}).get('externalMesh')}
    native_claimed = candidate.get('nativeCpuEffects', [])
    if not isinstance(native_claimed, list) or len(set(native_claimed)) != len(native_claimed) or \
            set(native_claimed) != native_required:
        raise ValueError(f'native CPU effect evidence differs from source-owned hooks: {sorted(native_required)}')
    host_effects = {name for name in source_effects if definitions.get(name, {}).get('externalTexture')}
    reference_inputs = golden.get('hostTextures', [])
    native_inputs = candidate.get('hostTextures', [])
    if not isinstance(reference_inputs, list) or not isinstance(native_inputs, list) or \
            len(reference_inputs) != len(native_inputs):
        raise ValueError('host input count differs from reference')
    if host_effects and not reference_inputs:
        raise ValueError('source external texture lacks host input capture')
    if reference_inputs and not host_effects:
        raise ValueError('host replay has no source external texture effect')
    fields = ('id', 'frame', 'sha256', 'width', 'height', 'format', 'orientation', 'bytesPerRow')
    by_id = {}
    for entry in reference_inputs:
        if not isinstance(entry, dict) or entry.get('id') in by_id:
            raise ValueError('duplicate or malformed reference host input')
        if not isinstance(entry.get('width'), int) or not isinstance(entry.get('height'), int) or \
                entry['width'] < 1 or entry['height'] < 1 or \
                entry.get('frame') != 0 or entry.get('format') != 'rgba8unorm' or \
                entry.get('orientation') != 'top-down' or \
                entry.get('bytesPerRow') != entry.get('width', -1) * 4:
            raise ValueError('unsupported host input capture protocol')
        path = image_path(golden_dir, entry)
        if path.stat().st_size != entry['width'] * entry['height'] * 4:
            raise ValueError('host input byte count differs from dimensions')
        by_id[entry['id']] = tuple(entry.get(field) for field in fields)
    observed = {}
    for entry in native_inputs:
        if not isinstance(entry, dict) or entry.get('id') in observed:
            raise ValueError('duplicate or malformed native host input')
        observed[entry['id']] = tuple(entry.get(field) for field in fields)
    if observed != by_id:
        raise ValueError('native host input identity, format, dimensions, or bytes differ from reference')
    if bool(reference_inputs) != (candidate.get('hostInputMode') == 'referenceReplay'):
        raise ValueError('native host input mode does not match replay evidence')
    audio_required = bool(source_effects & {'synth.scope', 'synth.spectrum'})
    source_audio = golden.get('hostAudio')
    native_audio = candidate.get('hostAudio')
    if audio_required:
        if not isinstance(source_audio, dict) or not isinstance(native_audio, dict):
            raise ValueError('source audio effect lacks host sample evidence')
        asset = ROOT / 'parity/inputs/audio-v1.json'
        payload = json.loads(asset.read_text())
        expected = {'frame': 0, 'assetPath': 'parity/inputs/audio-v1.json',
                    'assetSha256': sha256(asset), 'updatePolicy': 'static-before-frame-1',
                    'waveformF32Sha256': payload['waveformF32']['sha256'],
                    'spectrumF32Sha256': payload['spectrumF32']['sha256']}
        for name in ('waveform', 'spectrum'):
            descriptor = payload[f'{name}F32']
            if descriptor['bytes'] != 512 or descriptor['path'] != f'audio-v1.{name}.f32le' or \
                    sha256(asset.parent / descriptor['path']) != descriptor['sha256']:
                raise ValueError('source audio float snapshot differs from host asset')
        representation = golden.get('capture', {}).get('audioInput', {}).get('representation')
        if representation not in (None, 'plain-array'):
            raise ValueError('unsupported source audio host representation')
        if representation == 'plain-array':
            expected['representation'] = 'plain-array'
        if source_audio != expected or native_audio != expected:
            raise ValueError('native or reference audio host sample identity differs')
        source_kind = 'waveform' if 'synth.scope' in source_effects else 'spectrum'
        source_binding = golden.get('audioBindingEffectiveSha256')
        native_binding = candidate.get('audioBindingEffectiveSha256')
        expected_binding = (payload[f'{source_kind}F32']['sha256'] if representation == 'plain-array'
                            else hashlib.sha256(bytes(512)).hexdigest())
        if source_binding != expected_binding or native_binding != expected_binding:
            raise ValueError('native and source effective audio uniform bytes differ')
    elif source_audio is not None or native_audio is not None:
        raise ValueError('audio input evidence has no source audio effect')


def verify_volume_evidence(item, golden, candidate, golden_dir):
    contract = item['capture'].get('volumeInput')
    reference = golden.get('hostVolumes', [])
    native = candidate.get('hostVolumes', [])
    if contract is None:
        if reference or native:
            raise ValueError('host volume has no corpus input contract')
        return
    if item['id'] != 'micro/sampled3dProbe' or contract.get('id') != 'node_0_volume' or \
            contract.get('assetPath') != 'parity/inputs/sampled3d-v1.rgba8' or \
            (contract.get('width'), contract.get('height'), contract.get('depth')) != (8, 8, 8) or \
            contract.get('format') != 'rgba8unorm' or contract.get('bytesPerRow') != 32 or \
            contract.get('bytesPerImage') != 256 or contract.get('frame') != 0 or \
            contract.get('orientation') != 'x-fastest-y-next-z-outermost' or \
            contract.get('updatePolicy') != 'static-before-frame-1':
        raise ValueError('unsupported host volume corpus protocol')
    asset = ROOT / contract['assetPath']
    if asset.stat().st_size != 2048 or sha256(asset) != contract.get('assetSha256'):
        raise ValueError('host volume asset differs from corpus contract')
    if not isinstance(reference, list) or not isinstance(native, list) or \
            len(reference) != 1 or len(native) != 1:
        raise ValueError('host volume source/native inventory differs')
    expected = {**contract, 'sha256': contract['assetSha256']}
    for label, entry in (('reference', reference[0]), ('native', native[0])):
        if not isinstance(entry, dict) or any(entry.get(key) != value for key, value in expected.items()):
            raise ValueError(f'{label} host volume identity differs from corpus')
    source_path = image_path(golden_dir, reference[0])
    if source_path.stat().st_size != 2048 or source_path.read_bytes() != asset.read_bytes():
        raise ValueError('same-run source host volume differs from tracked input')


def count(selected, goldens, candidates, stages, catalog, golden_dir, candidate_dir, refusals):
    stage_by_id = {item['id']: item for item in stages['cases']}
    gold_by_id = {item['id']: item for item in goldens['cases']}
    candidate_by_id = {item['id']: item for item in candidates['cases']}
    ids = {item['id'] for item in selected}
    if len(stage_by_id) != stages['expected'] or len(gold_by_id) != len(goldens['cases']) or \
       len(candidate_by_id) != len(candidates['cases']) or goldens['expected'] != len(selected) or \
       candidates['expected'] != len(selected) or not set(gold_by_id).issubset(ids) or \
       not set(candidate_by_id).issubset(ids):
        raise ValueError('golden/candidate ledger has duplicate or extra case IDs')
    all_effects = {f"{effect['namespace']}.{effect['func']}" for effect in catalog['effects']}
    evidenced = set()
    buckets = {name: 0 for name in ('exact', 'strict', 'near', 'defer', 'skip', 'fail', 'missing', 'uninformative', 'refusal')}
    details = []
    for item in selected:
        case_id = item['id']
        golden = gold_by_id.get(case_id)
        candidate = candidate_by_id.get(case_id)
        stage = stage_by_id.get(case_id)
        result = {'id': case_id}
        if golden is None or candidate is None:
            result['bucket'] = 'missing'
            result['error'] = 'golden or candidate ledger entry missing'
            buckets['missing'] += 1
            details.append(result)
            continue
        try:
            if stage is None or stage['sourceSha256'] != item['sourceSha256'] or \
               stage['stages']['graph']['status'] != 'ok':
                raise ValueError('missing successful locked-JS graph stage')
            if golden['sourceSha256'] != item['sourceSha256'] or candidate['sourceSha256'] != item['sourceSha256']:
                raise ValueError('ledger source differs from corpus')
            if golden.get('capture') != item['capture']:
                raise ValueError('reference capture protocol differs from corpus')
            verify_capability_profile(golden, candidate)
            result['capabilityProfile'] = golden['capabilityProfile']
            refusal = refusals.get(case_id)
            if refusal is not None:
                if not source_refusal_matches(golden):
                    raise ValueError('locked WebGPU source did not refuse at texture-height creation')
                if not native_refusal_matches(candidate, refusal['dimensionParameter']):
                    raise ValueError('native graph did not refuse the same nonfinite dimension')
                bucket = 'refusal'
                result['sourceFailure'] = refusal['sourceFailure']
                result['nativeFailure'] = refusal['nativeFailure']
                result['dimensionParameter'] = refusal['dimensionParameter']
                result['bucket'] = bucket
                buckets[bucket] += 1
                details.append(result)
                continue
            if golden.get('status') != 'ok' or golden.get('backend') != 'WebGPU':
                raise ValueError(f"reference capture failed: {golden.get('error', golden.get('status'))}")
            if candidate.get('status') != 'ok' or candidate.get('backend') != 'Metal':
                raise ValueError(f"native render failed: {candidate.get('error', candidate.get('status'))}")
            source_effects = set(stage['effects'])
            if set(candidate.get('effects', [])) != source_effects:
                raise ValueError('candidate graph effects differ from locked-JS graph')
            verify_input_evidence(source_effects, golden, candidate, catalog, golden_dir)
            verify_volume_evidence(item, golden, candidate, golden_dir)
            audio_unreactive = bool(source_effects & {'synth.scope', 'synth.spectrum'}) and \
                golden['audioBindingEffectiveSha256'] != golden['hostAudio'][
                    'waveformF32Sha256' if 'synth.scope' in source_effects else 'spectrumF32Sha256']
            if source_effects & {'synth.scope', 'synth.spectrum'}:
                result['audioSignalBound'] = not audio_unreactive
            expected_frames = sample_frames(item)
            golden_images = {image['frame']: image for image in golden['images']}
            candidate_images = {image['frame']: image for image in candidate['images']}
            if len(golden_images) != len(expected_frames) or len(candidate_images) != len(expected_frames) or \
               set(golden_images) != set(expected_frames) or set(candidate_images) != set(expected_frames):
                raise ValueError('golden or candidate sample frame set differs from protocol')
            samples = []
            for frame in expected_frames:
                gpath = image_path(golden_dir, golden_images[frame])
                cpath = image_path(candidate_dir, candidate_images[frame])
                samples.append({'frame': frame, **grade_corpus.compare(gpath, cpath, item['capture']['size'])})
            result['samples'] = samples
            if any(not sample['pass'] for sample in samples):
                bucket = 'fail'
            elif audio_unreactive or not any(sample['informative'] for sample in samples):
                bucket = 'uninformative'
            elif all(sample['exact'] for sample in samples):
                bucket = 'exact'
            else:
                bucket = 'strict'
            if bucket in ('exact', 'strict'):
                evidenced.update(source_effects & all_effects)
        except (KeyError, OSError, ValueError) as error:
            bucket = 'fail'
            result['error'] = str(error)
        result['bucket'] = bucket
        buckets[bucket] += 1
        details.append(result)
    summary = {'expected': len(selected),
               'renderable': len(selected) - sum(item['id'] in refusals for item in selected),
               'refusal_expected': sum(item['id'] in refusals for item in selected),
               'executed': sum(buckets[name] for name in ('exact', 'strict', 'near', 'fail', 'uninformative', 'refusal')),
               **buckets, 'refusal_equivalent': buckets['refusal'],
               'effects': len(all_effects), 'effects_evidenced': len(evidenced)}
    if sum(buckets.values()) != len(selected):
        raise ValueError('summary buckets do not partition corpus')
    return summary, details, sorted(all_effects - evidenced)


def qualified(summary, requested):
    # Refusals remain unsupported members of the complete denominator.
    if summary['refusal_expected'] != 0 or summary['refusal_equivalent'] != 0 or \
            any(summary[name] != 0 for name in
                ('refusal', 'fail', 'missing', 'skip', 'near', 'defer')):
        return False
    informative = summary['exact'] + summary['strict']
    if requested:
        return summary['uninformative'] == 0 and informative == summary['expected']
    # Architecture section 4 keeps flat smoke fixtures visible, without giving
    # them pixel-parity or effect-evidence credit. Every effect must still have
    # a separate informative exact/strict result, and every case is accounted for.
    return informative + summary['uninformative'] == summary['expected'] and \
        summary['effects_evidenced'] == summary['effects']


def main():
    if len(sys.argv) < 3:
        print('usage: parity/summarize.py <golden-dir> <candidate-dir> [case-id ...]', file=sys.stderr)
        return 2
    golden_dir, candidate_dir = Path(sys.argv[1]), Path(sys.argv[2])
    corpus_path = ROOT / 'parity/corpus.json'
    corpus = json.loads(corpus_path.read_text())
    by_id = {item['id']: item for item in corpus['cases']}
    if len(by_id) != len(corpus['cases']) or len(by_id) != sum(corpus['expected'].values()):
        raise ValueError('corpus denominator differs from family inventory')
    requested = sys.argv[3:]
    label = 'PARITY-PROBE' if requested else 'PARITY-SUMMARY'
    if len(set(requested)) != len(requested) or any(case_id not in by_id for case_id in requested):
        raise ValueError('duplicate or unknown requested corpus case')
    selected = [by_id[case_id] for case_id in requested] if requested else corpus['cases']
    lock = json.loads((ROOT / 'parity/reference.json').read_text())
    refusals = refusal_inventory(json.loads((ROOT / 'parity/source-refusals.json').read_text()), corpus, lock)
    try:
        goldens = json.loads((golden_dir / 'goldens.json').read_text())
        candidates = json.loads((candidate_dir / 'candidates.json').read_text())
    except (OSError, json.JSONDecodeError) as error:
        summary = {'expected': len(selected), 'renderable': len(selected) - sum(item['id'] in refusals for item in selected),
                   'refusal_expected': sum(item['id'] in refusals for item in selected),
                   'refusal_equivalent': 0, 'refusal': 0,
                   'executed': 0, 'exact': 0, 'strict': 0, 'near': 0,
                   'defer': 0, 'skip': len(selected), 'fail': 0, 'missing': 0,
                   'uninformative': 0, 'effects': len(json.loads((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_text())['effects']),
                   'effects_evidenced': 0}
        print(f'parity-summary: infrastructure ledger unavailable: {error}', file=sys.stderr)
        print(label + ' ' + json.dumps(summary, separators=(',', ':')))
        return 2
    corpus_hash = sha256(corpus_path)
    stages = json.loads((ROOT / 'parity/corpus-stages.json').read_text())
    catalog = json.loads((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_text())
    if goldens.get('corpusSha256') != corpus_hash or candidates.get('corpusSha256') != corpus_hash or \
       stages.get('corpusSha256') != corpus_hash or goldens.get('authority') != lock or \
       catalog['authority']['commit'] != lock['commit']:
        raise ValueError('ledger, stage, or catalog provenance differs from current locked corpus')
    summary, details, unevidenced = count(selected, goldens, candidates, stages, catalog, golden_dir, candidate_dir,
                                         refusals)
    output = golden_dir.parent / 'results.json'
    output.write_text(json.dumps({'summary': summary, 'cases': details, 'unevidencedEffects': unevidenced}, indent=2) + '\n')
    for case in details:
        if case['bucket'] not in ('exact', 'strict'):
            diagnostic = case.get('error') or case.get('sourceFailure', '')
            print(f"[{case['bucket']}] {case['id']}: {diagnostic}", file=sys.stderr)
    if not requested and unevidenced:
        print(f'parity-summary: {len(unevidenced)} effects lack informative exact/strict evidence', file=sys.stderr)
    print(label + ' ' + json.dumps(summary, separators=(',', ':')))
    return 0 if qualified(summary, requested) else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyError, OSError, ValueError) as error:
        print(f'parity-summary: {error}', file=sys.stderr)
        try:
            corpus = json.loads((ROOT / 'parity/corpus.json').read_text())
            requested = sys.argv[3:]
            expected = len(requested) if requested else len(corpus['cases'])
            effects = len(json.loads((ROOT / 'Sources/Noisemaker/Resources/catalog.json').read_text())['effects'])
        except (KeyError, OSError, ValueError):
            expected, effects = 0, 0
        summary = {'expected': expected, 'renderable': expected, 'refusal_expected': 0,
                   'refusal_equivalent': 0, 'refusal': 0, 'executed': 0, 'exact': 0, 'strict': 0,
                   'near': 0, 'defer': 0, 'skip': expected, 'fail': 0, 'missing': 0,
                   'uninformative': 0, 'effects': effects, 'effects_evidenced': 0}
        label = 'PARITY-PROBE' if len(sys.argv) > 3 else 'PARITY-SUMMARY'
        print(label + ' ' + json.dumps(summary, separators=(',', ':')))
        sys.exit(2)
