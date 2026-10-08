#!/usr/bin/env python3
"""Verify the bootstrapped macOS package in an isolated local SwiftPM consumer."""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-only', action='store_true',
                    help='Compile the consumer without executing it; provides no Metal runtime evidence')
args = parser.parse_args()

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'tools/verify-artifact.py')], check=True)
artifact = root / 'Artifacts/CNoisemakerTint.xcframework'
if not artifact.is_dir():
    raise SystemExit('Run python3 tools/build-tint.py before checking the package')
with tempfile.TemporaryDirectory(prefix='noisemaker-consumer-') as temporary:
    workspace = Path(temporary)
    package = workspace / 'Noisemaker'
    package.mkdir()
    shutil.copy2(root / 'Package.swift', package / 'Package.swift')
    shutil.copy2(root / 'LICENSE', package / 'LICENSE')
    (package / 'tools/tint').mkdir(parents=True)
    for name in ['dawn', 'abseil-cpp', 'spirv-headers']:
        notice = f'LICENSE-{name}.txt'
        shutil.copy2(root / 'tools/tint' / notice, package / 'tools/tint' / notice)
    shutil.copytree(root / 'Sources', package / 'Sources')
    # Preserve the manifest test target without carrying authority exports or sibling sources.
    (package / 'Tests/NoisemakerTests').mkdir(parents=True)
    (package / 'Tests/NoisemakerTests/ConsumerFixture.swift').write_text('import Noisemaker\n')
    shutil.copytree(artifact, package / 'Artifacts/CNoisemakerTint.xcframework')
    copied_files = sorted(path for path in package.rglob('*') if path.is_file())
    copied_manifest = [(path.relative_to(package).as_posix(), hashlib.sha256(path.read_bytes()).hexdigest())
                       for path in copied_files]
    snapshot_sha256 = hashlib.sha256(json.dumps(copied_manifest, separators=(',', ':')).encode()).hexdigest()
    print(json.dumps({'copiedPackageSnapshotSha256': snapshot_sha256,
                      'copiedPackageFiles': len(copied_manifest),
                      'scope': 'isolated package copy before SwiftPM build'}, sort_keys=True), flush=True)
    consumer = workspace / 'Consumer'
    (consumer / 'Sources/Probe').mkdir(parents=True)
    (consumer / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Probe", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Noisemaker")],
    targets: [.executableTarget(name: "Probe", dependencies: [.product(name: "Noisemaker", package: "Noisemaker"),
        .product(name: "NoisemakerMetalKit", package: "Noisemaker")],
        linkerSettings: [.linkedFramework("AppKit")])])
''')
    (consumer / 'Sources/Probe/main.swift').write_text('''import Foundation
import AppKit
import Metal
import Noisemaker
import NoisemakerMetalKit
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
let compiler = try NoisemakerCompiler()
let graph = try compiler.compile(source: "search synth\\nsolid(color: [0.2, 0.6, 0.9]).write(o0)\\nrender(o0)\\n")
precondition(graph.passes.count == 2)
precondition(graph.source.contains("solid"))
for mesh in BuiltinMesh.allCases { let loaded = try mesh.load(); precondition(loaded.vertexCount > 0) }
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let command = queue.makeCommandBuffer() else { fatalError("Native Metal required") }
let size = try RenderSize(width: 17, height: 9)
let renderer = try NoisemakerRenderer(device: device, graph: graph, size: size)
let output = try renderer.encode(into: command)
command.commit()
command.waitUntilCompleted()
precondition(command.status == .completed)
precondition(output.texture.pixelFormat == .rgba16Float)
let rowBytes = 256
let staging = device.makeBuffer(length: rowBytes * size.height, options: .storageModeShared)!
let readback = queue.makeCommandBuffer()!
let blit = readback.makeBlitCommandEncoder()!
blit.copy(from: output.texture, sourceSlice: 0, sourceLevel: 0,
    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
    sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
    to: staging, destinationOffset: 0, destinationBytesPerRow: rowBytes,
    destinationBytesPerImage: rowBytes * size.height)
blit.endEncoding()
readback.commit()
readback.waitUntilCompleted()
precondition(readback.status == .completed)
let expected: [Float] = [0.2, 0.6, 0.9, 1]
for y in 0..<size.height {
    for x in 0..<size.width {
        for c in 0..<4 {
            let bits = staging.contents().load(fromByteOffset: y * rowBytes + x * 8 + c * 2, as: UInt16.self)
            precondition(abs(Float(Float16(bitPattern: bits)) - expected[c]) < 0.001)
        }
    }
}

print("CONSUMER-PASS native_passes=\\(graph.passes.count) dawn=\\(result.dawnRevision) cold_ms=\\(cold * 1000) warm_ms=\\(warmTime * 1000) msl_bytes=\\(result.source.utf8.count)")
''')
    environment = {key: value for key, value in os.environ.items() if not key.startswith('NM_')}
    command = (['swift', 'build', '--package-path', str(consumer), '--configuration', 'release', '--product', 'Probe']
               if args.build_only else
               ['swift', 'run', '--package-path', str(consumer), '--configuration', 'release', 'Probe'])
    subprocess.run(command, env=environment, check=True)
    executable = consumer / '.build/release/Probe'
    print(json.dumps({'consumer': ('isolated SwiftPM consumer compilation only; Metal execution unqualified'
                                  if args.build_only else
                                  'isolated SwiftPM package, catalog and seven meshes, native compiler, Tint, MetalKit module, completed Metal frame and pixel readback'),
                      'metalExecuted': not args.build_only,
                      'executableBytes': executable.stat().st_size,
                      'archiveBytes': (artifact / 'macos-arm64/libCNoisemakerTint.a').stat().st_size,
                      'copiedPackageSnapshotSha256': snapshot_sha256,
                      'publication': 'local verification only'}))
