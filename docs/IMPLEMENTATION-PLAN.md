# Noisemaker for Swift implementation plan

## 1. Goal and execution boundary

Build the Swift compiler and direct Metal renderer described in [the architecture](../ARCHITECTURE.md) and [porting guide](../PORTING-GUIDE.md). This is a proposal, not an executed plan. Source paths, commands and APIs below are planned. Implementation begins only when requested by the operator.

Write a failing behavior/ABI fixture, verify that failure, implement the smallest coherent change, and run the relevant regression set for each task. Review evidence before increasing scope. Use the existing default-branch checkout; remote publication and automation setup are separate decisions.

## 2. Review focus

| Failure condition | Expected behavior | Owning task |
|---|---|---|
| WGSL compiles but MSL bindings/options differ | Binding and numeric probes detect wrong output | 1–2 |
| Swift layout is legal but wrong for shader ABI | GPU echo tests fail on offsets/stride | 2 |
| Output/uniform storage reused while in flight | Delayed-consumer tests expose reuse; leases prevent it | 3, 6 |
| Graph replacement or device error destroys active state | Last good graph remains usable; precise error returned | 3, 6 |
| Package only works beside upstream or on simulator | Clean consumer and physical device gates fail | 1, 7 |

## 3. Ordered tasks

### Task 1. Establish source export and translator feasibility

**Proposed files:** `Package.swift`, `Sources/CNoisemakerTint/include/NoisemakerTint.h`, `Sources/CNoisemakerTint/NoisemakerTint.cpp`, `Tests/NoisemakerTests/TranslatorTests.swift`, `tools/export-reference.mjs`, `parity/cases.json`.

**Interface:** a small C ABI takes WGSL bytes, stage/entry point, binding table and options; returns owned MSL bytes, diagnostics and metadata with an explicit free operation. Development exporter consumes `NM_REFERENCE_ROOT`; it is not a runtime dependency.

- [ ] Export current catalog inventory, representative graphs, stage dumps and capture protocols independently from upstream.
- [ ] Probe the actual installed Swift/Xcode SDK and Metal device; select and document minimum compiler/deployment versions only after API availability checks.
- [ ] Translate solid and one resource-heavy WGSL stage using reviewed Tint code, with explicit bindings and ownership tests.
- [ ] Build a minimal clean SwiftPM consumer and a physical iOS/iPadOS translation probe; measure toolchain complexity, binary size and startup cost. A failed mobile probe leaves that target unqualified without blocking honest macOS-only progress.
- [ ] Audit licenses and dependency footprint before importing translator code. Record exact generation inputs for reproducibility, without freezing product builds around failures.
- [ ] Run `swift test --filter TranslatorTests` once the proposed target exists; require a real device test in addition to host-only tests.

**Acceptance:** native Swift can obtain valid MSL via the C ABI, free all outputs safely, and build the selected package form. Unresolved mobile/toolchain limitations remain explicit.

### Task 2. Render a golden graph and prove buffer layout

**Proposed files:** `Sources/Noisemaker/Graph/{RenderGraph,GraphValue,Diagnostic}.swift`, `Sources/Noisemaker/Runtime/{ShaderCompiler,UniformWriter,MetalBackend}.swift`, `Sources/NMRender/main.swift`, `Tests/NoisemakerTests/{SolidGPU,UniformLayout}Tests.swift`, `parity/compare.py`.

**Interface:** renderer initialization accepts `MTLDevice`, graph and size; shader compiler produces Metal functions plus tested resource/layout metadata.

- [ ] Make comparison reject wrong colors, a flipped 257×129 marker, incorrect dimensions, missing output and invalid alpha.
- [ ] Render upstream-exported solid through Tint, Metal library creation and a floating-point texture on the actual GPU.
- [ ] Add GPU echo tests for scalar, vec3, array, matrix, bool and mixed-field layout; compare against upstream uniform interpretation.
- [ ] Read back through a completion-synchronized staging path and compare final and intermediate outputs separately.
- [ ] Implement `swift run nm-render --graph parity/fixtures/solid.graph.json --out parity/out/solid.png`; run the strict comparator against independently captured WebGPU output.

**Acceptance:** matching solid/coordinate/ABI fixtures and deliberate negative tests; no claim from pipeline creation alone.

### Task 3. Implement graph execution and completion lifetimes

**Proposed files:** `Sources/Noisemaker/Runtime/{TexturePool,SurfaceManager,PassEncoder,FrameState,OutputLease,FrameSubmission,NoisemakerRenderer}.swift`, `Tests/NoisemakerTests/{RuntimeGPU,LifetimeGPU}Tests.swift`.

**Interface:** `encode(frame:into:) -> OutputLease`, convenience `render(frame:) -> FrameSubmission`, and frame-boundary resize/reset as defined in architecture section 2.2.

- [ ] Add multipass blur, distinguishable MRT outputs, repeat loops, sampled feedback traces, mixed texture formats and dimensions.
- [ ] Implement graph-ordered render/blit/compute encoding, hazard-aware resources, exact load/store/blend/depth state, persistent state and descriptor-keyed pooling.
- [ ] Implement geometry/points/billboards, volume/cubemap paths and catalog-required compute behavior with individual GPU fixtures.
- [ ] Submit delayed consumers and multiple bounded in-flight frames; assert uniforms and leased outputs cannot be overwritten or recycled early.
- [ ] Test wrong-device command buffers, uncommitted/out-of-order encode requests, injected allocation errors, resize during in-flight work and failed graph replacement.
- [ ] Run `swift test --filter RuntimeGPU` and `swift test --filter LifetimeGPU` with Metal validation enabled on a capable native host.

**Acceptance:** pass/resource semantics and completion behavior agree with fixture contracts; no CPU frame-loop wait or readback is required.

### Task 4. Port the native Swift frontend

**Proposed files:** `Sources/Noisemaker/Compiler/{Lexer,Parser,Validator,Expander,ResourceAllocator,Normalizer,ExpressionEvaluator,NoisemakerCompiler}.swift`, `Sources/Noisemaker/Catalog/EffectRegistry.swift`, `Tests/NoisemakerTests/CompilerTests.swift`, `tools/check-stages.mjs`.

**Interface:** `NoisemakerCompiler.compile(source:) throws -> RenderGraph`; ordered typed diagnostics preserve upstream stage/source information.

- [ ] Specify tagged values, missing/null behavior, ordered objects, exact step indexing and source hash semantics with failing fixtures.
- [ ] Port lexer, parser, validator, expander and allocation in order; compare each stage with independent upstream dumps before the next.
- [ ] Cover enums, aliases, defaults, expressions, defines, nested chains, surfaces, uniform aliases, scoped parameters and `mediaSteps`.
- [ ] Test reference-supported input, malformed input, and reference refusals as distinct classes; unsupported claimed features fail completeness.
- [ ] Run `swift test --filter CompilerTests` and `node tools/check-stages.mjs --reference "$NM_REFERENCE_ROOT"`; render native-produced graphs with task 3's GPU suite.

**Acceptance:** stage equivalence and identical graph behavior with no JavaScript runtime in the shipping package.

### Task 5. Generate and qualify all shader/catalog variants

**Proposed files:** `tools/import-catalog.mjs`, `Sources/Noisemaker/Resources/`, `Tests/NoisemakerTests/CatalogTests.swift`, `parity/{run.mjs,report.py}`.

**Interface:** catalog generation preserves upstream definition/WGSL identity; variant compiler consumes complete source/define/stage/binding/options keys and produces traceable pipelines.

- [ ] Derive the full effect/mode/define/parameter inventory from current upstream; include host inputs, stage variants, simulations, geometry and volumes.
- [ ] Generate assets twice and compare hashes; prove oracle generation does not use candidate assets.
- [ ] Port by runtime dependency: simple sources/filters, noise/mixers, stateful passes, geometry, volumes and remaining special cases.
- [ ] Add integer/half/derivative/numerical fixtures and deterministic automation traces; inspect translator settings when outputs differ.
- [ ] Run `node parity/run.mjs --all` and `python3 parity/report.py --require-complete`; fail missing fixtures, skips, errors, timeouts and unsupported cases without hiding them from totals.

**Acceptance:** current full inventory is accounted for with separate exact/strict/mismatch counts; drift or stale evidence fails the gate.

### Task 6. Complete embedding and input integration

**Proposed files:** `Sources/Noisemaker/Runtime/{ExternalInputs,Parameters,TextInput,MeshInput}.swift`, `Sources/NoisemakerMetalKit/NoisemakerViewRenderer.swift`, `Examples/MetalViewer/`, `Tests/NoisemakerTests/{HostInput,RecoveryGPU}Tests.swift`.

**Interface:** host-fed textures and snapshots, live parameters, output leases, plus an optional MTKView adapter separate from the core renderer.

- [ ] Test per-step media isolation, orientation/alpha, fixed-font text, mesh UV/normals, and audio/MIDI snapshots against reference fixtures.
- [ ] Present GPU output through MetalKit without CPU readback; test physical-pixel resizing and a temporarily unavailable drawable.
- [ ] Exercise invalid DSL, failed shader compilation, graph replacement, reset and view teardown while GPU work remains in flight.
- [ ] Run 100 compile/render/resize/dispose cycles with bounded owned resources, completed command buffers and retained downstream consumers.

**Acceptance:** a real app can embed, resize, reconfigure, show errors and recover while preserving input/output ownership and avoiding live-frame stalls.

### Task 7. Package and qualify Apple targets

**Proposed files:** `Tests/PackageConsumer/`, `tools/package-check.sh`, package resources and required license notices; Apple example target settings established by the feasibility probe.

- [ ] Build/test a clean macOS consumer without sibling checkouts, Node, Rust or runtime network fetches.
- [ ] Run full compiler, catalog, rendered, lifetime, recovery and integration gates on Apple Silicon macOS.
- [ ] Qualify iOS/iPadOS on physical Metal devices, recording compiler/SDK/deployment floors, memory limits and translator viability; report simulators separately.
- [ ] Only add Intel/AMD Mac or other Apple-platform support claims after the same evidence exists there.
- [ ] Benchmark cold/warm shader compilation, CPU/GPU frame cost, memory and in-flight behavior for the architecture's workload matrix.
- [ ] Verify package resources and notices, binary asset handling, and absence of private paths, credentials and generated run output.

**Acceptance:** clean package consumption and complete evidence for each claimed platform. A source-compiling but unrendered platform stays unqualified. Publication and store submission are separate work.
