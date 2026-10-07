# Noisemaker for Swift

## 1. Status

Early implementation of the planned Swift compiler and Metal renderer. The first source-export and WGSL-to-MSL translation components now build: a Swift library wraps Tint through a C ABI, and native Metal tests exercise the translated shaders. There is no native DSL compiler, graph renderer, demo, or release yet.

## 2. Intended result

A Swift Package will expose the Polymorphic DSL compiler, GPU render-graph runtime, and effect catalog. Applications will receive Metal textures for their own rendering or use a small optional MetalKit adapter. The effect pipeline remains on the GPU; Swift performs compilation and orchestration.

The first qualification target is macOS on Apple Silicon. iOS/iPadOS device qualification is a subsequent stage of this port. Intel/AMD Macs and other Apple platforms require separate evidence before support is claimed. Swift and deployment-version floors will be chosen from actual compiler/API probes in the first implementation milestone, rather than invented here.

## 3. Documents

- [Architecture](ARCHITECTURE.md): native runtime, shader strategy, graph contract, qualification, and sources.
- [Porting guide](PORTING-GUIDE.md): WGSL-to-MSL translation, resource binding, Swift semantics, and Metal lifetimes.
- [Implementation plan](docs/IMPLEMENTATION-PLAN.md): ordered work packages, proposed paths/interfaces, and acceptance checks.

## 4. First milestone

The next rendering milestone is to run upstream-exported graphs on a real Metal device, using WGSL translated to MSL through a small Tint C interface with explicit binding metadata: a solid color as a smoke test, then the 257×129 asymmetric marker as the first parity gate against an upstream WebGPU golden minted in the same run. A solid color is not parity evidence: the family grader counts a golden with no structure as uninformative. This qualifies the shader/runtime seam before expanding the Swift compiler.

## 5. Repository state

Private development repository under `noisefactorllc`, with default branch `main`. This repository remains private until the port is ready to use and the operator explicitly authorizes a public release. The translator and initial shader/ABI probes are implemented; the complete port and any release remain unqualified. The existing scheduled port audits discover live `noisemaker-for-*` repositories, including private repositories they can access. This repository has no CI, release, or deployment workflows. The architecture and plan still describe future compiler/runtime APIs. The commands below exercise the implemented translator feasibility package. Binary distribution remains an implementation gate.

## 6. Development checks

Use an Apple Silicon Mac, Swift 6 or newer, Python 3, CMake 3.22 or newer, Ninja, Git and Node.js. Full Xcode is required for the XCTest suites; Command Line Tools alone can build the library and the isolated consumer. The package declares macOS 14 as its initial deployment floor. Native GPU probes have been exercised on an Apple M4 with macOS 26.5 and Xcode's Swift 6.3.2; translation and consumer compilation also run on an M2 with macOS 14.8.3 and Swift 6.0.3. These probes do not qualify the full port on either OS.

```sh
python3 tools/build-tint.py
swift build
scripts/test
MTL_DEBUG_LAYER=1 scripts/test-metal
python3 tools/package-check.py
```

The bootstrap fetches the reviewed Dawn/Tint dependency revisions from `tools/tint/dawn.json`, checks their source identities, and builds a local macOS-arm64 static XCFramework under `.build/tint`. Run it before opening the package in an IDE or resolving it as a dependency. This is a local feasibility package, not a published remote SwiftPM binary product. The consumer check copies only the Swift library and generated translator artifact into an isolated package; translation itself uses no Node, Rust, sibling checkout, or network access. Dependency notices are in `tools/tint/LICENSE-*.txt`.

The test entrypoints export the authority locked in `parity/reference.json`. Set `NM_REFERENCE_ROOT` to a clean checkout at that commit to use local sources; otherwise the exporter fetches the locked sources into a temporary archive. Generated graphs, stage dumps, shader sources, capture protocols and source hashes stay under `.build/reference`. Unknown or altered authority inputs fail verification. Define counts describe declared samples, not every accepted numeric literal.

`scripts/test` runs exporter and translator checks without needing a GPU. `scripts/test-metal` runs native shader-library, solid-color, asymmetric grain-copy and storage-length tests; a missing Metal device fails. These are shader/ABI probes, not same-run WebGPU-versus-Metal parity. The solid is explicitly uninformative as parity evidence. No `scripts/parity-summary` exists yet, because the native DSL compiler and full rendering path do not exist.

## 7. Contributing

See the Noise Factor [contributing policy](https://github.com/noisefactorllc/.github/blob/main/CONTRIBUTING.md) and [Code of Conduct](https://github.com/noisefactorllc/.github/blob/main/CODE_OF_CONDUCT.md).

## 8. License and trademark

MIT (see [LICENSE](LICENSE)). Use of the Noisemaker and Noise Factor names in derivative products is subject to the [Trademark Policy](TRADEMARK.md).

Copyright © 2026 Noise Factor LLC
