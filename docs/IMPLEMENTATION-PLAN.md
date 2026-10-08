# Noisemaker for Swift implementation plan

## 1. Goal and execution boundary

Build the Swift compiler and direct Metal renderer described in [the architecture](../ARCHITECTURE.md) and [porting guide](../PORTING-GUIDE.md). The macOS Apple Silicon prototype has completed the locked compiler and full rendering gates under operator authorization. The source exporter, translator, native compiler, Metal graph executor, host inputs, MetalKit integration and lifetime checks are implemented. The 2,899-case compiler differential (17,394 stage hashes), 106 CPU tests and 76 native Metal tests pass. Full same-run rendering passes on Apple M2/macOS 14.8.3: 2,877 exact cases, 22 uninformative cases, zero failures/skips/missing cases, and informative evidence for all 210 effects. See the README for authority, fingerprints and remaining issue links. Public distribution, performance qualification and physical iOS qualification remain incomplete.

Write a failing behavior/ABI fixture, verify that failure, implement the smallest coherent change, and run the relevant regression set for each task. Review evidence before increasing scope. Use the existing default-branch checkout; remote publication and automation setup are separate decisions.

## 2. Review focus

| Failure condition | Expected behavior | Owning task |
|---|---|---|
| WGSL compiles but MSL bindings/options differ | Binding and numeric probes detect wrong output | 1–2 |
| Swift layout is legal but wrong for shader ABI | GPU echo tests fail on offsets/stride | 2 |
| A golden with no structure is counted as parity | Grader reports the case uninformative | 2, 5 |
| Swift matches a WebGPU golden that diverges from WebGL2 | Divergence is fixed upstream; the lock moves; Swift is not bent to the defect | 5 |
| Output/uniform storage reused while in flight | Delayed-consumer tests expose reuse; leases prevent it | 3, 6 |
| Graph replacement or device error destroys active state | Last good graph remains usable; precise error returned | 3, 6 |
| Package only works beside upstream or on simulator | Clean consumer and physical device gates fail | 1, 7 |

## 3. Ordered tasks

### Task 1. Establish source export and translator feasibility

**Proposed files:** `Package.swift`, `parity/reference.json`, `scripts/test`, `Sources/CNoisemakerTint/include/NoisemakerTint.h`, `Sources/CNoisemakerTint/NoisemakerTint.cpp`, `Tests/NoisemakerTests/TranslatorTests.swift`, `tools/export-reference.mjs`.

**Interface:** a small C ABI takes WGSL bytes, stage/entry point, binding table and options; returns owned MSL bytes, diagnostics and metadata with an explicit free operation. Development exporter consumes the locked authority (`NM_REFERENCE_ROOT` at the commit in `parity/reference.json`, or a clone of that commit); it is not a runtime dependency.

- [x] Pin the authority in `parity/reference.json`; export catalog inventory, representative graphs, stage dumps and capture protocols independently from that commit.
- [x] Probe the actual installed Swift/Xcode SDK and Metal device; select and document minimum compiler/deployment versions only after API availability checks.
- [x] Translate solid, one resource-heavy WGSL stage and one compute WGSL filter using reviewed Tint code, with explicit bindings and ownership tests.
- [ ] Measure the define-variant space of the locked catalog. Compare runtime translation for everything against precompiled MSL for the catalog plus runtime translation for Portable effects, on package size, cold start and iOS viability; record the decision with its numbers.
- [ ] Build a minimal clean SwiftPM consumer and a physical iOS/iPadOS translation probe; measure toolchain complexity, binary size and startup cost. A failed mobile probe leaves that target unqualified without blocking honest macOS-only progress.
- [x] Audit licenses and dependency footprint before importing translator code. Record exact generation inputs for reproducibility, without freezing product builds around failures.
- [x] Run `swift test --filter TranslatorTests` once the proposed target exists; require a real device test in addition to host-only tests. Start `scripts/test` with the GPU-free checks available so far.

**Acceptance:** native Swift can obtain valid MSL via the C ABI, free all outputs safely, and build the selected package form. Unresolved mobile/toolchain limitations remain explicit.

### Task 2. Render a golden graph and prove buffer layout

**Proposed files:** `Sources/Noisemaker/Graph/{RenderGraph,GraphValue,Diagnostic}.swift`, `Sources/Noisemaker/Runtime/{ShaderCompiler,UniformWriter,MetalBackend}.swift`, `Sources/NMRender/main.swift`, `Tests/NoisemakerTests/{SolidGPU,UniformLayout}Tests.swift`, `parity/batch-golden.mjs`, `parity/compare.py`.

**Interface:** renderer initialization accepts `MTLDevice`, graph and size; shader compiler produces Metal functions plus tested resource/layout metadata; golden minting renders the same case on upstream WebGPU with the backend asserted in the page and grades the presented surface.

- [x] Make comparison reject wrong colors, a flipped 257×129 marker, incorrect dimensions, missing output and invalid alpha, and report a pass on a structureless golden as uninformative.
- [x] Render upstream-exported solid through Tint, Metal library creation and a floating-point texture on the actual GPU as a smoke test.
- [ ] Add GPU echo tests for scalar, vec3, array, matrix, bool and mixed-field layout; compare against upstream uniform interpretation.
- [ ] Read back through a completion-synchronized staging path and compare final and intermediate outputs separately.
- [x] Implement `swift run nm-render --graph .build/reference/cases/marker.json --out .build/parity-marker/candidate.png`; grade it against a WebGPU golden minted in the same run.

Current evidence: the presented marker passes with maximum channel error 0 and SSIM 1.0 on Apple M4. Mixed scalar/vector/matrix/array numeric ABI echo passes on Metal; broader upstream uniform-interpretation coverage remains open. Golden capture records both raw backing and post-presentation surfaces.

**Acceptance:** matching marker/coordinate/ABI fixtures on informative goldens and deliberate negative tests; the solid smoke test is not parity evidence; no claim from pipeline creation alone.

### Task 3. Implement graph execution and completion lifetimes

**Proposed files:** `Sources/Noisemaker/Runtime/{TexturePool,SurfaceManager,PassEncoder,FrameState,OutputLease,FrameSubmission,NoisemakerRenderer}.swift`, `Tests/NoisemakerTests/{RuntimeGPU,LifetimeGPU}Tests.swift`.

**Interface:** `encode(frame:into:) -> OutputLease`, convenience `render(frame:) -> FrameSubmission`, and frame-boundary resize/reset as defined in architecture section 2.2.

- [ ] Add multipass blur, distinguishable MRT outputs, repeat loops, sampled feedback traces, mixed texture formats and dimensions.
- [ ] Implement graph-ordered render/blit/compute encoding, hazard-aware resources, exact load/store/blend/depth state, persistent state and descriptor-keyed pooling.
- [ ] Choose render versus compute from the WGSL entry points as `webgpu.js` does, and dispatch the catalog's compute WGSL filters with storage buffers, each with its own GPU fixture.
- [ ] Implement geometry/points/billboards and Portable volume textures with individual GPU fixtures.
- [ ] Submit delayed consumers and multiple bounded in-flight frames; assert uniforms and leased outputs cannot be overwritten or recycled early.
- [ ] Test wrong-device command buffers, uncommitted/out-of-order encode requests, injected allocation errors, resize during in-flight work and failed graph replacement.
- [ ] Run `swift test --filter RuntimeGPU` and `swift test --filter LifetimeGPU` with Metal validation enabled on a capable native host.

Current evidence: blur, compute-buffer conversion, isolated MRT and fractional-coordinate sampling have same-run presented-output comparisons and GPU tests of intermediate textures. Borrowed and convenience submission paths have native lifetime regressions, including three in-flight slots, delayed consumers, abandoned commands, cross-queue rejection and unretained references after partial failures. Surface binding transactions match 16 locked-upstream two-frame traces; Global and ordinary persistent feedback have native GPU persistence/reset regressions. Mesh triangle rendering, including custom OBJ input, has exact WebGPU parity; point rendering has source-bound selected-case evidence; the complete 2,899-case rendering sweep now passes on Apple M2.

**Acceptance:** pass/resource semantics and completion behavior agree with fixture contracts; no CPU frame-loop wait or readback is required.

### Task 4. Port the native Swift frontend

**Proposed files:** `Sources/Noisemaker/Compiler/{Lexer,Parser,Validator,Expander,ResourceAllocator,Normalizer,ExpressionEvaluator,NoisemakerCompiler}.swift`, `Sources/Noisemaker/Catalog/EffectRegistry.swift`, `Tests/NoisemakerTests/CompilerTests.swift`, `tools/check-stages.mjs`.

**Interface:** `NoisemakerCompiler.compile(source:) throws -> RenderGraph`; ordered typed diagnostics preserve upstream stage/source information.

- [x] Specify tagged values, missing/null behavior, ordered objects and exact step indexing with failing fixtures.
- [x] Test UTF-16 code-unit lines, columns and offsets, and `hashSource` (signed 32-bit, base 36) on ASCII and non-ASCII source.
- [x] Port lexer, parser, validator, expander and allocation in order; compare each stage with independent upstream dumps before the next.
- [x] Cover enums, aliases, defaults, expressions, defines, nested chains, surfaces, uniform aliases, scoped parameters and `mediaSteps`.
- [ ] Test reference-supported input, malformed input, and reference refusals as distinct classes; unsupported claimed features fail completeness.
- [x] Run the compiler tests, source-stage exporter, and full `CorpusStageParityTests` differential through `scripts/test`; render native-produced graphs in the GPU suite.

Current evidence: native lexer/parser tests compare 26 lexical cases and 69 parser cases with independently executed locked upstream stages, including diagnostics and strict/default subchain behavior. Validation, expansion, allocation and native graph generation now match all 2,899 pinned corpus cases. The tracked `CorpusStageParityTests` gate checks 17,394 exact hashes across lexing and the five compiler stages; runtime capability checks remain separate.

**Acceptance:** stage equivalence and identical graph behavior with no JavaScript runtime in the shipping package.

### Task 5. Generate and qualify all shader/catalog variants

**Proposed files:** `tools/import-catalog.mjs`, `tools/generate-coverage.mjs`, `Sources/Noisemaker/Resources/`, `Tests/NoisemakerTests/CatalogTests.swift`, `scripts/parity-summary`, `parity/sweep.py`, `parity/{programs,coverage,portable,timed,curated}/`.

**Interface:** catalog generation preserves upstream definition/WGSL identity; variant compiler consumes complete source/define/stage/binding/options keys and produces traceable pipelines; `scripts/parity-summary` mints WebGPU goldens and renders candidates in the same run and prints the family `PARITY-SUMMARY` line.

- [x] Import the shared corpus (shared programs, curated programs, timed tier, Portable cases) and upstream `parity-case.json` programs; generate the coverage corpus from the locked definitions and add its freshness check to `scripts/test`.
- [x] Generate assets twice and compare hashes; prove oracle generation does not use candidate assets.
- [ ] Port by runtime dependency: simple sources/filters, noise/mixers, stateful passes, geometry and remaining special cases.
- [ ] Add integer/half/derivative/numerical fixtures and deterministic automation traces; inspect translator settings when outputs differ.
- [ ] When a difference traces to a WebGPU-versus-WebGL2 divergence, capture the WebGL2 frame for that case, fix the WGSL upstream toward WebGL2, and move the authority lock; the case stays failing until then.
- [x] Run `scripts/parity-summary`; missing fixtures, skips, errors, timeouts, unsupported and uninformative cases stay visible, and the exit status fails until every effect has informative evidence.

**Acceptance:** `PARITY-SUMMARY` reports zero near, fail, skip and missing cases, and `effects_evidenced` equals `effects`, at the locked authority; drift or stale evidence fails the gate.

### Task 6. Complete embedding, Portable effects and input integration

**Proposed files:** `Sources/Noisemaker/Runtime/{ExternalInputs,Parameters,TextInput,MeshInput,PortableEffects}.swift`, `Sources/NoisemakerMetalKit/NoisemakerViewRenderer.swift`, `Examples/MetalViewer/`, `Tests/NoisemakerTests/{HostInput,Portable,RecoveryGPU}Tests.swift`.

**Interface:** host-fed textures and snapshots, live parameters, output leases, `NoisemakerCompiler.registerEffect` for Portable effects, plus an optional MTKView adapter separate from the core renderer.

- [ ] Test per-step media isolation, orientation/alpha, fixed-font text, mesh UV/normals, and audio/MIDI snapshots against reference fixtures.
- [x] Register Portable effects at run time, translate and render their WGSL, and refuse one without a WGSL program with a diagnostic.
- [x] Present GPU output through MetalKit without CPU readback; test physical-pixel resizing and a temporarily unavailable drawable.
- [ ] Exercise invalid DSL, failed shader compilation, graph replacement, reset and view teardown while GPU work remains in flight.
- [x] Run 100 compile/render/resize/dispose cycles with bounded owned resources, completed command buffers and retained downstream consumers.

**Acceptance:** a real app can embed, resize, reconfigure, show errors and recover while preserving input/output ownership and avoiding live-frame stalls.

### Task 7. Package and qualify Apple targets

**Proposed files:** `Tests/PackageConsumer/`, `tools/package-check.sh`, package resources and required license notices; Apple example target settings established by the feasibility probe.

- [x] Build/test a clean macOS consumer without sibling checkouts, Node, Rust or runtime network fetches.
- [x] Run `scripts/test` and `scripts/parity-summary`, plus the lifetime, recovery and integration gates, on Apple Silicon macOS.
- [ ] Qualify iOS/iPadOS on physical Metal devices, recording compiler/SDK/deployment floors, memory limits and translator viability; report simulators separately.
- [ ] Only add Intel/AMD Mac or other Apple-platform support claims after the same evidence exists there.
- [ ] Benchmark cold/warm shader compilation, CPU/GPU frame cost, memory and in-flight behavior for the architecture's workload matrix.
- [ ] Verify package resources and notices, binary asset handling, and absence of private paths, credentials and generated run output.

**Acceptance:** clean package consumption and complete evidence for each claimed platform. A source-compiling but unrendered platform stays unqualified. Publication and store submission are separate work.
