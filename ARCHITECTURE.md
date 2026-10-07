# Noisemaker for Swift architecture

## 1. Purpose and status

This is a planned, independent GPU port of Noisemaker's shader engine and Polymorphic DSL. The intended deliverable is an embeddable library with a native compiler, GPU render-graph executor, effect catalog, example host, and source-bound parity harness. It is not a port of the classic CPU renderer.

Status: planning documents only. There is no implementation, package, working API, measured performance, or qualified platform. All API signatures, source layouts, and commands below are proposed contracts. Repository creation does not qualify any effect or platform.

The scope is the current upstream shader engine: compiler stages, effect definitions, shader programs, resource allocation, runtime state, host inputs, user-defined Portable effects, and output textures. Full catalog parity is the destination; incremental milestones do not reduce that destination. Derive the denominator from the upstream commit in the authority lock (section 4) at each qualification run, never from a count written into a document.

## 2. Selected architecture and alternatives

Select a native Swift DSL frontend and direct Metal graph executor. Preserve the upstream WGSL as source authority and translate it to Metal Shading Language (MSL) with Tint through a narrow C ABI. Mint goldens on upstream WebGPU, which runs the same WGSL; WebGL2 remains Noisemaker's reference backend and decides any disagreement between the two (section 4). The existing Rust GPU port takes the same route (WGSL through Tint, WebGPU goldens) and contains a Tint shim and Metal option/binding work worth studying, but its renderer and historical parity claims are not inherited by this port. [Rust GPU port](../noisemaker-for-rust-gpu/README.md), [Tint C interface](../noisemaker-for-rust-gpu/crates/noisemaker-tint/shim/nm_tint.h), [Dawn and Tint](https://dawn.googlesource.com/dawn/+/HEAD/README.md).

This makes the application-facing compiler, resource management and rendering native Swift/Metal, with a C/C++ shader translation dependency. Do not describe it as a pure-Swift implementation. No Rust, wgpu, browser, or JavaScript runtime is required in the proposed shipping path.

Hand-translating the complete catalog to MSL would reduce translation-tool dependency but create a second shader implementation and recurring drift work. Offline-only MSL generation cannot be the whole design, because Portable effects supply WGSL at run time. It can still remove most translation work from the shipping path: task 1 measures the define-variant space of the locked catalog and compares two packagings, runtime translation for everything versus precompiled MSL for the catalog with runtime translation only for Portable effects. Choose from measured package size, startup cost and iOS viability. Either way the Tint route requires an early package-size, licensing, SwiftPM/C++ integration, and Apple-device feasibility gate. The Tint revision is a dependency pin, which Worker Elves may not move, so translator upgrades remain human-led work.

### 2.1 Proposed package layout

| Target/path | Responsibility |
|---|---|
| `Sources/Noisemaker/Compiler/` | Swift compiler stages and expression semantics |
| `Sources/Noisemaker/Graph/` | Typed values, graph schema, descriptors and diagnostics |
| `Sources/Noisemaker/Runtime/` | Metal resources, frame state, pass encoding and submission |
| `Sources/Noisemaker/Resources/` | Generated catalog and preserved WGSL |
| `Sources/CNoisemakerTint/` | Narrow C ABI around the required Tint translation code |
| `Sources/NoisemakerMetalKit/` | Optional view/presentation adapter |
| `Sources/NMRender/` | macOS parity/export command-line host |
| `scripts/test`, `scripts/parity-summary` | Family check entrypoints (section 4) |
| `Tests/` and `parity/` | Compiler, ABI, GPU and package tests; shared corpus, golden minting and grading |
| `tools/` | Development-only catalog export and shader tooling |

The core imports Metal and Foundation. AppKit/UIKit/SwiftUI/MetalKit belong in optional host targets. A caller-supplied `MTLDevice` fixes resource ownership to one device; offscreen rendering does not require a view.

### 2.2 Proposed public contract

`NoisemakerCompiler.compile(source: String) throws -> RenderGraph` performs native compilation. `NoisemakerCompiler.registerEffect(_ effect: PortableEffect) throws` registers a user-defined Portable effect (definition plus WGSL programs), validated as upstream `effect-validator.js` validates it. `NoisemakerRenderer(device: MTLDevice, graph: RenderGraph, size: RenderSize) throws` validates and prepares a graph. The renderer is confined to a documented serial executor; mutable graph/GPU state is not implicitly thread-safe.

`encode(frame: FrameState, into: MTLCommandBuffer) throws -> OutputLease` encodes without committing or waiting. `OutputLease.texture` is a Metal texture on the renderer's device; the lease retains output resources until the host has completed its downstream GPU use. The command buffer must belong to the same device. A separate convenience `render(frame:) throws -> FrameSubmission` owns submission, bounded in-flight capacity, and completion/error reporting. `setParameter(stepIndex:name:value:)`, `setInput(binding:texture:)`, `resize(to:)`, and `reset()` take effect at documented frame boundaries.

`FrameState` carries explicit time, delta time, frame index, audio/MIDI snapshots, and external input identity. `RenderSize` uses physical pixels. Concurrent uncommitted frame encodes or cross-queue use without an explicit synchronization contract are rejected. Feedback updates are ordered; successful CPU encoding alone does not prove successful GPU execution.

### 2.3 Shader compilation and ABI

Preserve upstream WGSL inputs and definition data. Translation consumes the fully assembled WGSL variant, chosen entry point/stage, backend options, and an explicit `(group,binding,resource kind) → Metal slot` table. It emits MSL, diagnostics, entry-point identity, binding/layout metadata, workgroup requirements, and provenance. Validate buffer offsets/strides with GPU probes; Swift memory layout must never be guessed from source field names.

Upstream `webgpu.js` chooses the pipeline kind from the WGSL entry points: a shader with `@compute` and no `@fragment` compiles as compute, even when its definition declares an ordinary pass. Several catalog filters (for example `crt`, `degauss` and `grain`) ship compute WGSL with storage buffers on that basis. The Metal executor must make the same decision and dispatch those shaders as `webgpu.js` does.

Use Metal library/pipeline compilation after translation. Apple's API supports creating a library from MSL source; packaged precompiled variants can reduce startup work after equivalence is proven. Cache keys cover assembled source, entry point, stage, defines, translator identity/options, device capabilities, and pipeline formats/state. [Apple shader libraries](https://developer.apple.com/documentation/metal/shader-libraries).

Do not paste MSL dumped from the Rust renderer into the package: it may carry wgpu-specific argument slots, generated immediate data, and device workarounds. Port the required contract explicitly and validate it. Translator memory ownership, errors, thread safety, availability of source compilation, deployment floors, and packaging for Apple devices are task-1 gates.

### 2.4 Metal execution and resource lifetime

Translate each graph descriptor to an exact Metal format/usage/storage choice. Preserve float precision, filtering, layers, mip levels, 3D type, and required access. No catalog definition sets `is3D` today; volume textures come from Portable effects, which may declare them. Only the backends themselves create cube textures, so cube textures stay out of scope until the authority uses them. Validate format combinations and limits against the actual device; do not infer support from the OS name. [Apple Metal capability tables](https://developer.apple.com/metal/capabilities/).

Encode ordered render/compute/blit passes with explicit attachments, load/store actions, blend factors, viewport/scissor, depth/cull state, primitive mode, and uniforms. Qualify each compute shader the catalog uses with its own fixture. Resource hazards, ping-pong, repeat loops, and feedback state follow upstream; implicit host API ordering cannot replace graph semantics.

Pool transient textures by complete descriptor and GPU completion lifetime. Persistent feedback and borrowed output leases are not available for reuse. Keep frame uniforms/uploads alive through completion; use a bounded ring instead of overwriting a buffer still in flight. GPU-to-CPU inspection uses a staging/readback path with correct row alignment and completion synchronization. `waitUntilCompleted` is acceptable in explicit test/export tools, not a default live-frame loop.

Prepare replacement graphs and resize resources before activation, retire old resources after their GPU work completes, and preserve the last good graph on compilation or allocation failure. Keep final display conversion separate from linear intermediates and establish orientation/pixel centers from fixtures.

## 3. Compiler and graph contract

The implementation seam is upstream `shaders/src/runtime/compiler.js::compileGraph`: DSL → lexer → parser → validator → expander → resource allocation → render graph → GPU execution. A development-only JavaScript exporter supplies golden graphs before the native compiler exists. The shipping library must compile DSL without Node.js, a browser, a subprocess, or a remote service.

Preserve graph `id`, `source`, ordered `passes`, `programs`, `allocations`, `textures`, `renderSurface`, and `mediaSteps`. Maps need an explicit portable encoding. Normalize only specified representation differences and `compiledAt`; never discard semantically relevant fields to obtain equality. Record the normalizer version. The Qt normalized graph schema is a starting reference, not a substitute for inspecting current upstream fields.

Preserve pass inputs/outputs, shader identity, defines, uniform layouts and values, dimensions, repeat counts, blend factors, clear behavior, draw mode, attachment order, step indices, uniform aliases, and scoped parameters. Unknown fields with execution meaning must fail validation rather than disappear. Preserve stable diagnostic codes and source spans where upstream supplies them.

Use explicit tagged values for missing, null, booleans, numbers, strings, arrays, objects, enums, and expressions. Preserve reference numeric semantics and object iteration requirements. Upstream counts source positions in UTF-16 code units: lexer lines, columns and offsets index the JavaScript string, and `hashSource` (the graph `id`) folds `charCodeAt` values into a signed 32-bit integer printed in base 36, sign included. Swift `String` indexes by grapheme cluster, so hash and compute positions over `source.utf16`, and test with non-ASCII source. Export reference results separately for lexing, parsing, validation, expansion, allocation, and graph normalization. Never execute DSL text with a host-language evaluator. Dynamic expressions need a dedicated implementation of the reference-supported semantics; an unimplemented expression is an explicit compatibility failure.

A malformed replacement program must not destroy the last working graph. Compile, validate capabilities, and prepare new resources before activation. A failure returns a diagnostic containing its stage, effect/program, source location where available, and original backend error. A Portable effect that supplies no WGSL program is unsupported on this port and fails registration with a diagnostic.

## 4. Source and parity method

The authority is the upstream Noisemaker commit pinned in `parity/reference.json` (repository and commit), as in the sibling ports. `NM_REFERENCE_ROOT` may name a checkout at that commit; otherwise the tools clone the pinned commit. Record the revision, dirty status, relevant content hashes, browser build, reference backend, adapter, capture configuration, case list, and candidate source identity with each result. A revision without content verification is insufficient when local changes exist. Move the lock forward deliberately, with fresh evidence; the scheduled port audits report the distance between the lock and upstream head.

The oracle and candidate must not both consume a stale candidate-generated catalog. Export the oracle directly from the locked commit, regenerate the candidate catalog independently, and compare inventories and definitions before comparing output. Source changes invalidate affected evidence. The lock must not hide drift from current upstream or route around a failing product gate.

Use the family entrypoints. `scripts/test` runs every check that needs no GPU against the locked authority: catalog and corpus freshness, compiler stage parity, translator ABI tests that need no device, Portable registration, and the harness unit tests. `scripts/parity-summary` runs the sweep fresh (goldens minted by the reference engine in the same run, candidates rendered from DSL by this port's own compiler, every case graded) and prints one `PARITY-SUMMARY` JSON line with `expected`, `executed`, `exact`, `strict`, `near`, `defer`, `skip`, `fail`, `missing`, `uninformative`, `effects` and `effects_evidenced`. It exits 0 only when no case is near, failing, skipped or missing and every catalog effect has informative exact or strict evidence of its own. Automated gap closure reads this line, so do not substitute a differently shaped report. [Reference definition](../noisemaker-for-rust-gpu/scripts/parity-summary).

Mint goldens on the upstream WebGPU backend, as the Rust GPU port does: the reference engine renders each case in its demo page in Chromium, and the presented surface is the golden. This port executes the same WGSL, so a WebGPU golden separates translation and runtime defects from GLSL-versus-WGSL source differences that this port cannot fix locally. WebGL2 is Noisemaker's reference backend, and upstream WebGPU must match it. When a Swift difference or a suspect golden traces to a WebGPU-versus-WebGL2 divergence, capture the WebGL2 frame for that case, fix the WGSL upstream toward WebGL2, and move the authority lock to the fix. Never change Swift to reproduce a WebGPU divergence, and never switch a case's golden to whichever backend the candidate happens to match.

Two capture traps apply. A Shade `BrowserSession` renders WebGL2 until `setBackend()` changes it, so assert the active backend inside the page before each capture; the backend a tool was asked for is not proof of the backend it ran. Upstream WebGPU surfaces store rows bottom-first and `readPixels` returns them as stored, so grade the presented surface, never a raw WebGPU readback.

Start from the corpus the sibling ports share rather than a new fixture set: the shared fixture programs (`parity/programs`), the generated coverage corpus of every effect with its defaults, each value of each choice parameter and each flipped boolean (`parity/coverage`), user Portable effects (`parity/portable`), the timed tier for every effect that evolves across frames (`parity/timed`), and the sibling ports' curated programs (`parity/curated`). Include upstream's per-effect `parity-case.json` programs. Port-specific microfixtures (markers, buffer layout, MRT, completion lifetimes) sit beside the shared corpus, not in place of it.

Each case fixes DSL, effect parameters and defines, seed, dimensions, time, delta time, frame count, reset state, input assets and hashes, and capture orientation/color conversion. Stateful effects require sequential frame traces and declared warm-up/sample frames; a single attractive still is insufficient. Use asymmetric corner markers and odd dimensions to detect orientation and row-stride errors. Use raw float samples for internal texture checks and lossless PNGs for comparable final output.

Each case lands in exactly one family bucket. Exact means identical pixels. Strict means maximum absolute channel difference ≤ 2.001 in 8-bit units and global SSIM ≥ 0.98, with matching dimensions and alpha. A pass on a golden with no structure (one colour over more than 99% of the pixels, or luminance standard deviation below one 8-bit level) is uninformative and never parity evidence. Unsupported cases, unavailable runners, both engines refusing a claimed-supported case, and skipped cases never count as passes or shrink the denominator. Keep near and other relaxed categories out of full-parity totals; never widen tolerances to make a port pass. Compiler equivalence, native shader compilation, finite output, package integrity, rendered parity, and platform qualification are separate results.

The fixture matrix covers every effect and declared mode, parameter boundaries, compile-time variants, chains, external inputs, resize, repeat, feedback, MRT, points/billboards, mesh/depth, compute WGSL, Portable effects including volume textures, deterministic automation, and errors.

GPU qualification uses actual compatible hardware and the actual target runtime. CPU-only CI may validate syntax, catalog generation, graph equivalence, and reports; it cannot qualify rendering. Scheduled graphics work must use a capability-matched host broker. A job container's missing graphics device is not evidence that fleet GPU access is absent. No fleet jobs, intake recipes, or scheduling are created by this planning task.

## 5. Qualification sequence and risks

1. Real macOS Metal device, Swift/Tint ABI and package feasibility, including the packaging comparison in section 2.
2. Golden-graph solid smoke test, then asymmetric markers, MRT, uniform layout, and completion lifetimes.
3. Multipass, feedback, repeats, geometry, the catalog's compute WGSL, and Portable volume textures.
4. Native Swift compiler and full effect catalog against same-run WebGPU goldens.
5. MetalKit embedding, clean package consumer, and physical iOS/iPadOS qualification.

High-risk areas are WGSL/MSL numeric differences, translator options, resource-slot remapping, Swift buffer alignment, in-flight reuse, WebGPU-versus-Metal clip/texture conventions, UTF-16 source positions, and packaging a C++ translator for Apple devices. A simulator build or successful `swift test` without a GPU is not device qualification.

New effects, editor UI, network services, Core Image reimplementation, non-Metal rendering, export-site publication, and fleet enrollment are outside the initial implementation. Public distribution and store submission are separate work. Input capture and app permissions stay with the host, while reference-compatible input processing remains in the library scope.

## 6. Performance and distribution

Measure cold translation, Metal compilation, pipeline-cache reuse, CPU encode cost, GPU execution time, readback, allocations, and in-flight memory separately at 256×256, 512×512, 1920×1080, and an odd-sized target. Use generators, multipass filters, simulations and geometry. Record device, OS, compiler, translator, source and exact frame protocol; no unmeasured frame-rate promise belongs in the README.

Propose a Swift Package with isolated C/C++ translation support, plus a macOS render tool and optional MetalKit integration. The first packaging probe determines whether source or reviewed binary distribution of the translation target is practical on each intended platform. Test a clean consumer without sibling checkouts, Node, Rust or runtime downloads. Audit upstream/Tint/transitive notices before importing code. Do not select an old build to evade failing parity or deployment gates.

## 7. Source references

Read upstream `shaders/src/lang/`, `shaders/src/runtime/{compiler,expander,resources,pipeline,external-input,effect-validator,registry}.js`, `shaders/src/runtime/backends/webgpu.js`, and each effect's `definition.js` and `wgsl/` directory before translating a subsystem. Relative links below assume sibling checkouts; they are engineering references, not shipping package dependencies.

- [Upstream graph compiler](../noisemaker/shaders/src/runtime/compiler.js)
- [Upstream pipeline](../noisemaker/shaders/src/runtime/pipeline.js)
- [Upstream WebGPU backend](../noisemaker/shaders/src/runtime/backends/webgpu.js)
- [Family parity entrypoint and buckets](../noisemaker-for-rust-gpu/scripts/parity-summary)
- [Rust GPU parity method and WebGPU golden minting](../noisemaker-for-rust-gpu/README.md#parity)
- [Coverage corpus generator](../noisemaker-for-rust-gpu/tools/generate-coverage.mjs)
- [Qt architecture](../noisemaker-for-qt/ARCHITECTURE.md)
- [Qt graph normalization contract](../noisemaker-for-qt/docs/GRAPH-JSON-SCHEMA.md)
- [Godot implementation plan](../noisemaker-for-godot/docs/IMPLEMENTATION-PLAN.md)

Sibling documentation records its own historical decisions. Reconfirm them against current source; do not inherit old completion claims, hard-coded catalog counts, blanket texture formats, or host assumptions.

Additional implementation references:

- [Rust Metal/Tint binding integration](../noisemaker-for-rust-gpu/crates/noisemaker-gpu/src/backend/tint.rs)
- [Rust Tint ownership and options contract](../noisemaker-for-rust-gpu/crates/noisemaker-tint/shim/nm_tint.h)
- [Apple Metal documentation](https://developer.apple.com/documentation/metal)
- [Apple Metal textures](https://developer.apple.com/documentation/metal/textures)
