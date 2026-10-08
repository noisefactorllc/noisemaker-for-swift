# Noisemaker for Swift

## 1. Status

The macOS Apple Silicon prototype passes the complete locked catalog parity gate. The package contains a native Swift DSL compiler, bundled effect catalog, Tint-to-MSL translation, a direct Metal graph runtime, and an optional MetalKit viewer. The complete 2,899-case compiler corpus matches 17,394 pinned source stage hashes. The CPU suite passes 106 tests and the native Metal suite passes 76 tests on Apple M2, including resource ownership, queued submissions, partial-write history, sampled 3D inputs, parameter updates, and recovery. Timed CLI regressions verify complete sample schedules, source-order automation arithmetic, and delta time at loop boundaries. The same-run WebGPU/Metal sweep executes 2,899 cases: 2,877 exact, 22 uninformative, zero failures, skips or missing cases, and informative evidence for all 210 effects. Public release and other Apple targets remain unqualified.

## 2. Intended result

A Swift Package will expose the Polymorphic DSL compiler, GPU render-graph runtime, and effect catalog. Applications will receive Metal textures for their own rendering or use a small optional MetalKit adapter. The effect pipeline remains on the GPU; Swift performs compilation and orchestration.

The first qualification target is macOS on Apple Silicon. iOS/iPadOS device qualification is a subsequent stage of this port. Intel/AMD Macs and other Apple platforms require separate evidence before support is claimed. The current package requires Swift 6 and macOS 14, established through native toolchain and device checks.

## 3. Documents

- [Architecture](ARCHITECTURE.md): native runtime, shader strategy, graph contract, qualification, and sources.
- [Porting guide](PORTING-GUIDE.md): WGSL-to-MSL translation, resource binding, Swift semantics, and Metal lifetimes.
- [Implementation plan](docs/IMPLEMENTATION-PLAN.md): ordered work packages, proposed paths/interfaces, and acceptance checks.

## 4. Rendering qualification

The first same-run parity gate passes on Apple M4: the 257×129 asymmetric marker has maximum channel error 0 and SSIM 1.0 against upstream WebGPU. The oracle copies the actual GPUCanvasContext texture after CanvasSink presentation; it also records the backing texture separately. This caught and fixed a vertical presentation mismatch that a comparison of backing textures alone would have missed. `nm-render` applies the presentation conversion when writing PNG; `OutputLease.texture` remains the raw graph output.

The same-run blur and compute probes pass within one channel value; the isolated two-attachment MRT and fractional-coordinate sampler probes are exact. A deliberate linear-sampler mutation fails with maximum channel error 96, confirming that the sampler gate detects filtering differences. These targeted fixtures supplement the complete catalog gate described below. The solid color remains a smoke test. The grader rejects missing output, incorrect dimensions, invalid alpha, color errors, and flips. Uninformative goldens remain visible and do not count as effect parity evidence. Native builtin and custom OBJ mesh rendering have exact presented-output comparisons. The 100-cycle compile/render/resize/dispose test passes with Metal validation and retained downstream consumers. Runtime features are accepted incrementally with explicit errors for unsupported semantics.

The complete prototype gate passes on Apple M2, macOS 14.8.3, Swift 6.0.3, against authority `2601e738df2463aa8b765afde3a7554d2a6d0170`. Run `run.PQfM82Oo` captures 4,420 presented PNG samples per backend across 2,899 cases, including all 170 timed cases. Results are 2,877 exact and 22 uninformative, with zero near, deferred, skipped, failed, missing or refused cases; all 210 effects have informative evidence. Uninformative cases do not count toward effect evidence. The qualification fingerprint is `66e53ccb3fe637502e58fe9eaa060430ee0230f45b3e2a3b5598139a5edf3a32`, unchanged after capture and grading; the native executable SHA-256 is `7be08228847a94169c7d533178573dc5c4e3b61e6c38721e7ca2144dc380d1d4`. Run artifacts remain under `.build/parity-full/run.PQfM82Oo` and are not packaged.

Remaining tracked gaps include [capture cancellation](https://github.com/noisefactorllc/noisemaker-for-swift/issues/12), [upstream explicit-entry-point storage-texture binding](https://github.com/noisefactorllc/noisemaker/issues/320), and [upstream external-upload test backend selection](https://github.com/noisefactorllc/noisemaker/issues/321). Portable storage-texture coverage currently qualifies the tested single-output numeric-dispatch 3D subset. The full sweep asserts actual WebGPU; the separate external-upload test's WebGL2 fallback is not WebGPU evidence. Performance qualification, physical iOS/iPadOS, Intel/AMD Macs and public distribution remain separate gates.

## 5. Repository state

Private development repository under `noisefactorllc`, with default branch `main`. This repository remains private until the port is ready to use and the operator explicitly authorizes a public release. The native compiler and substantial Metal runtime paths are implemented; the complete locked corpus passes on the measured Apple M2 host, while public release and other platforms remain unqualified. The existing scheduled port audits discover live `noisemaker-for-*` repositories, including private repositories they can access. The macOS CI workflow runs CPU/package checks. It does not claim GPU qualification or publish a release. The architecture and plan distinguish implemented compiler/runtime paths from the remaining qualification gates. The commands below exercise the current development package. The package includes the audited local macOS-arm64 translator artifact; public distribution remains a separate gate.

## 6. Development checks

Use an Apple Silicon Mac, Swift 6 or newer, Python 3, CMake 3.22 or newer, Ninja, Git and Node.js. The suites use Swift Testing and run with the Swift 6 Command Line Tools. GPU tests require a native Metal device. The package declares macOS 14 as its initial deployment floor. Native GPU probes have been exercised on an Apple M4 with macOS 26.5 and Xcode's Swift 6.3.2; translation and consumer compilation also run on an M2 with macOS 14.8.3 and Swift 6.0.3. The complete corpus gate above qualifies the measured M2 prototype; the M4 probes alone do not qualify that platform.

```sh
python3 tools/build-tint.py
python3 tools/build-raster.py
swift build
scripts/test
MTL_DEBUG_LAYER=1 scripts/test-metal
python3 tools/package-check.py
```

The package carries macOS-arm64 static XCFrameworks at `Artifacts/CNoisemakerTint.xcframework` and `Artifacts/CNoisemakerRaster.xcframework`. The raster artifact uses pinned Skia through a narrow C ABI for the native `fibers`, `scratches`, and `strayHair` overlays. Its rebuild verifies the source archive or canonical source tree, GN tool, license, and nine Canvas pixel oracles; source and build intermediates stay in `.build/skia`. Raster dependency notices and pins are in `tools/raster/` and `tools/raster.json`. The optional rebuild command fetches the reviewed Dawn/Tint dependency revisions from `tools/tint/dawn.json`, verifies their source identities, and uses `.build/tint` for intermediate build files. The packaged artifact supports local SwiftPM consumption without rebuilding Tint or fetching runtime dependencies. It is not a published remote SwiftPM binary product. The consumer check copies package sources, both artifacts, and their notices into an isolated package and verifies native overlay generation, translation, and a completed Metal frame with pixel readback. Package execution uses no Node, Rust, sibling checkout, or network access. Dependency notices are in `tools/tint/LICENSE-*.txt`.

The test entrypoints export the authority locked in `parity/reference.json`. Set `NM_REFERENCE_ROOT` to a clean checkout at that commit to use local sources; otherwise the exporter fetches the locked sources into a temporary archive. Generated graphs, stage dumps, shader sources, capture protocols and source hashes stay under `.build/reference`. Unknown or altered authority inputs fail verification. Define counts describe declared samples, not every accepted numeric literal.

`scripts/test` checks source/catalog/corpus freshness, all compiler-stage hashes, automation snapshots, CPU input geometry, uniform layout, surface binding, translator behavior, and grader integrity without needing a GPU. `scripts/test-metal` runs native graph/shader, uniform echo and lifetime tests; a missing Metal device fails. Lifetime tests exercise retained outputs, three bounded submissions, rejected unordered or cross-queue encoding, abandoned commands, and unretained command buffers after renderer release or partial encoding failure.

To repeat the presented marker comparison on a native WebGPU/Metal host:

```sh
NM_REFERENCE_ROOT=/path/to/locked/noisemaker scripts/parity-marker
NM_REFERENCE_ROOT=/path/to/locked/noisemaker scripts/parity-graph-probes
```

The authority root needs the matching Playwright browser dependencies. It may be a clean locked checkout or an exact source archive verified against the recorded source manifest. Outputs and provenance stay in `.build/parity-marker` and `.build/parity-graph-probes`. The graph probe command runs blur, compute, MRT and sampler cases by default. `scripts/parity-summary` runs the complete corpus, mints fresh WebGPU references, renders native candidates, and fails on missing, near, failed, or refused cases and until every effect has informative strict or exact evidence. A selected-case invocation reports `PARITY-PROBE`; it cannot qualify the complete family.

## 7. Contributing

See the Noise Factor [contributing policy](https://github.com/noisefactorllc/.github/blob/main/CONTRIBUTING.md) and [Code of Conduct](https://github.com/noisefactorllc/.github/blob/main/CODE_OF_CONDUCT.md).

## 8. License and trademark

MIT (see [LICENSE](LICENSE)). Use of the Noisemaker and Noise Factor names in derivative products is subject to the [Trademark Policy](TRADEMARK.md).

Copyright © 2026 Noise Factor LLC
