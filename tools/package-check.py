#!/usr/bin/env python3
"""Verify the bootstrapped macOS package in an isolated local SwiftPM consumer."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
artifact = root / '.build/tint/CNoisemakerTint.xcframework'
if not artifact.is_dir():
    raise SystemExit('Run python3 tools/build-tint.py before checking the package')
with tempfile.TemporaryDirectory(prefix='noisemaker-consumer-') as temporary:
    workspace = Path(temporary)
    package = workspace / 'Noisemaker'
    package.mkdir()
    shutil.copy2(root / 'Package.swift', package / 'Package.swift')
    shutil.copytree(root / 'Sources', package / 'Sources')
    # Preserve the manifest test target without carrying authority exports or sibling sources.
    (package / 'Tests/NoisemakerTests').mkdir(parents=True)
    (package / 'Tests/NoisemakerTests/ConsumerFixture.swift').write_text('import Noisemaker\n')
    shutil.copytree(artifact, package / '.build/tint/CNoisemakerTint.xcframework')
    consumer = workspace / 'Consumer'
    (consumer / 'Sources/Probe').mkdir(parents=True)
    (consumer / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Probe", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Noisemaker")],
    targets: [.executableTarget(name: "Probe", dependencies: [.product(name: "Noisemaker", package: "Noisemaker")])])
''')
    (consumer / 'Sources/Probe/main.swift').write_text('''import Foundation
import Noisemaker
let translator = ShaderTranslator()
let wgsl = "@compute @workgroup_size(1) fn main() {}"
let start = ProcessInfo.processInfo.systemUptime
let result = try translator.translate(wgsl: wgsl, entryPoint: "main", stage: .compute)
let cold = ProcessInfo.processInfo.systemUptime - start
let warmStart = ProcessInfo.processInfo.systemUptime
let warm = try translator.translate(wgsl: wgsl, entryPoint: "main", stage: .compute)
let warmTime = ProcessInfo.processInfo.systemUptime - warmStart
precondition(result.source == warm.source)
precondition(result.source.contains("kernel"))
print("CONSUMER-PASS dawn=\\(result.dawnRevision) cold_ms=\\(cold * 1000) warm_ms=\\(warmTime * 1000) msl_bytes=\\(result.source.utf8.count)")
''')
    environment = {key: value for key, value in os.environ.items() if not key.startswith('NM_')}
    command = ['swift', 'run', '--package-path', str(consumer), '--configuration', 'release', 'Probe']
    subprocess.run(command, env=environment, check=True)
    executable = consumer / '.build/release/Probe'
    print(json.dumps({'consumer': 'isolated local package with prebuilt macOS arm64 translator',
                      'executableBytes': executable.stat().st_size,
                      'archiveBytes': (artifact / 'macos-arm64/libCNoisemakerTint.a').stat().st_size,
                      'remoteSwiftPMDistribution': 'not qualified'}))
