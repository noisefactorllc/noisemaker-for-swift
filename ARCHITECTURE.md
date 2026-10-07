# Noisemaker for Swift architecture

## 1. Purpose and status

This is a planned, independent GPU port of Noisemaker's shader engine and Polymorphic DSL. The intended deliverable is an embeddable library with a native compiler, GPU render-graph executor, effect catalog, example host, and source-bound parity harness. It is not a port of the classic CPU renderer.

Status on 2026-10-07: planning documents only. There is no implementation, package, working API, measured performance, or qualified platform. All API signatures, source layouts, and commands below are proposed contracts. Repository creation does not qualify any effect or platform.

The scope is the current upstream shader engine: compiler stages, effect definitions, shader programs, resource allocation, runtime state, host inputs, and output textures. Full catalog parity is the destination; incremental milestones do not reduce that destination. Derive the denominator from the selected upstream source at each qualification run, rather than treating the inventory observed here as a permanent count.

## 2. Selected architecture and alternatives

Select a native Swift DSL frontend and direct Metal graph executor. Preserve the upstream WGSL as source authority and translate it to Metal Shading Language (MSL) with Tint through a narrow C ABI. Use upstream WebGPU as the primary rendered oracle. The existing Rust GPU port contains a Tint shim and Metal option/binding work worth studying, but its renderer and historical parity claims are not inherited by this port. [Rust GPU port](../noisemaker-for-rust-gpu/README.md), [Tint C interface](../noisemaker-for-rust-gpu/crates/noisemaker-tint/shim/nm_tint.h), [Dawn and Tint](https://dawn.googlesource.com/dawn/+/HEAD/README.md).

This makes the application-facing compiler, resource management and rendering native Swift/Metal, with a C/C++ shader translation dependency. Do not describe it as a pure-Swift implementation. No Rust, wgpu, browser, or JavaScript runtime is required in the proposed shipping path.

Hand-translating the complete catalog to MSL would reduce translation-tool dependency but create a second shader implementation and recurring drift work. Offline-only MSL generation would simplify runtime packaging but cannot be assumed to cover arbitrary source/define variants. It is useful for catalog prewarming, not a justification to omit runtime variants. The chosen Tint route requires an early package-size, licensing, SwiftPM/C++ integration, and Apple-device feasibility gate.

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
| `Tests/` and `parity/` | Compiler, ABI, GPU, package and oracle tests |
| `tools/` | Development-only catalog export and shader tooling |

The core imports Metal and Foundation. AppKit/UIKit/SwiftUI/MetalKit belong in optional host targets. A caller-supplied `MTLDevice` fixes resource ownership to one device; offscreen rendering does not require a view.

### 2.2 Proposed public contract

`NoisemakerCompiler.compile(source: String) throws -> RenderGraph` performs native compilation. `NoisemakerRenderer(device: MTLDevice, graph: RenderGraph, size: RenderSize) throws` validates and prepares a graph. The renderer is confined to a documented serial executor; mutable graph/GPU state is not implicitly thread-safe.

`encode(frame: FrameState, into: MTLCommandBuffer) throws -> OutputLease` encodes without committing or waiting. `OutputLease.texture` is a Metal texture on the renderer's device; the lease retains output resources until the host has completed its downstream GPU use. The command buffer must belong to the same device. A separate convenience `render(frame:) throws -> FrameSubmission` owns submission, bounded in-flight capacity, and completion/error reporting. `setParameter(stepIndex:name:value:)`, `setInput(binding:texture:)`, `resize(to:)`, and `reset()` take effect at documented frame boundaries.

`FrameState` carries explicit time, delta time, frame index, audio/MIDI snapshots, and external input identity. `RenderSize` uses physical pixels. Concurrent uncommitted frame encodes or cross-queue use without an explicit synchronization contract are rejected. Feedback updates are ordered; successful CPU encoding alone does not prove successful GPU execution.

### 2.3 Shader compilation and ABI

Preserve upstream WGSL inputs and definition data. Translation consumes the fully assembled WGSL variant, chosen entry point/stage, backend options, and an explicit `(group,binding,resource kind) → Metal slot` table. It emits MSL, diagnostics, entry-point identity, binding/layout metadata, workgroup requirements, and provenance. Validate buffer offsets/strides with GPU probes; Swift memory layout must never be guessed from source field names.

Use Metal library/pipeline compilation after translation. Apple's API supports creating a library from MSL source; packaged precompiled variants can reduce startup work after equivalence is proven. Cache keys cover assembled source, entry point, stage, defines, translator identity/options, device capabilities, and pipeline formats/state. [Apple shader libraries](https://developer.apple.com/documentation/metal/shader-libraries).

Do not paste MSL dumped from the Rust renderer into the package: it may carry wgpu-specific argument slots, generated immediate data, and device workarounds. Port the required contract explicitly and validate it. Translator memory ownership, errors, thread safety, availability of source compilation, deployment floors, and packaging for Apple devices are task-1 gates.

### 2.4 Metal execution and resource lifetime

Translate each graph descriptor to an exact Metal format/usage/storage choice. Preserve float precision, filtering, layers, mip levels, 3D/cube type, and required access. Validate format combinations and limits against the actual device; do not infer support from the OS name. [Apple Metal capability tables](https://developer.apple.com/metal/capabilities/).

Encode ordered render/compute/blit passes with explicit attachments, load/store actions, blend factors, viewport/scissor, depth/cull state, primitive mode, and uniforms. Use graph-declared compute passes only after their requirements are inventoried and qualified. Resource hazards, ping-pong, repeat loops, and feedback state follow upstream; implicit host API ordering cannot replace graph semantics.

Pool transient textures by complete descriptor and GPU completion lifetime. Persistent feedback and borrowed output leases are not available for reuse. Keep frame uniforms/uploads alive through completion; use a bounded ring instead of overwriting a buffer still in flight. GPU-to-CPU inspection uses a staging/readback path with correct row alignment and completion synchronization. `waitUntilCompleted` is acceptable in explicit test/export tools, not a default live-frame loop.

Prepare replacement graphs and resize resources before activation, retire old resources after their GPU work completes, and preserve the last good graph on compilation or allocation failure. Keep final display conversion separate from linear intermediates and establish orientation/pixel centers from fixtures.

## 3. Compiler and graph contract

The implementation seam is upstream `shaders/src/runtime/compiler.js::compileGraph`: DSL → lexer → parser → validator → expander → resource allocation → render graph → GPU execution. A development-only JavaScript exporter supplies golden graphs before the native compiler exists. The shipping library must compile DSL without Node.js, a browser, a subprocess, or a remote service.

Preserve graph `id`, `source`, ordered `passes`, `programs`, `allocations`, `textures`, `renderSurface`, and `mediaSteps`. Maps need an explicit portable encoding. Normalize only specified representation differences and `compiledAt`; never discard semantically relevant fields to obtain equality. Record the normalizer version. The Qt normalized graph schema is a starting reference, not a substitute for inspecting current upstream fields.

Preserve pass inputs/outputs, shader identity, defines, uniform layouts and values, dimensions, repeat counts, blend factors, clear behavior, draw mode, attachment order, step indices, uniform aliases, and scoped parameters. Unknown fields with execution meaning must fail validation rather than disappear. Preserve stable diagnostic codes and source spans where upstream supplies them.

Use explicit tagged values for missing, null, booleans, numbers, strings, arrays, objects, enums, and expressions. Preserve reference numeric semantics, object iteration requirements, and source hashing. Export reference results separately for lexing, parsing, validation, expansion, allocation, and graph normalization. Never execute DSL text with a host-language evaluator. Dynamic expressions need a dedicated implementation of the reference-supported semantics; an unimplemented expression is an explicit compatibility failure.

A malformed replacement program must not destroy the last working graph. Compile, validate capabilities, and prepare new resources before activation. A failure returns a diagnostic containing its stage, effect/program, source location where available, and original backend error.

## 4. Source and parity method

Use the upstream Noisemaker checkout through `NM_REFERENCE_ROOT` as read-only behavioral authority. Record its revision, dirty status, relevant content hashes, browser build, selected reference backend, adapter, capture configuration, fixture manifest, and candidate source identity. A revision without content verification is insufficient when local changes exist. The hashes in section 7 identify files read for this plan; they are neither dependency pins nor a qualification run.

The oracle and candidate must not both consume a stale candidate-generated catalog. Export the oracle directly from upstream, regenerate the candidate catalog independently, and compare inventories and definitions before comparing output. Source changes invalidate affected evidence. A saved oracle revision may reproduce a test but must not hide drift from current upstream or route around a failing product gate.

Each case fixes DSL, effect parameters and defines, seed, dimensions, time, delta time, frame count, reset state, input assets and hashes, and capture orientation/color conversion. Stateful effects require sequential frame traces and declared warm-up/sample frames; a single attractive still is insufficient. Use asymmetric corner markers and odd dimensions to detect orientation and row-stride errors. Use raw float samples for internal texture checks and lossless PNGs for comparable final output.

Report expected cases, executed cases, exact passes, strict tolerance passes, mismatches, errors, timeouts, unsupported cases, skips, and missing fixtures separately. Unsupported cases, unavailable runners, both engines refusing a claimed-supported case, and skipped cases never count as passes or shrink the denominator. Compiler equivalence, native shader compilation, finite output, package integrity, rendered parity, and platform qualification are separate results.

For the first rendered gate, propose the existing Qt strict comparison bar: maximum absolute channel error ≤ 2.001 in 8-bit units and SSIM ≥ 0.98, plus dimensions and alpha checks. Verify the comparator and its metric definition against current family tooling before adoption. Report byte equality separately. This is a proposed initial numerical contract, not evidence that either new port meets it. Keep diagnostic relaxed/chaotic categories out of full-parity pass totals; never widen tolerances to make a port pass.

The fixture matrix includes every effect and declared mode, parameter boundaries, compile-time variants, chains, external inputs, resize, repeat, feedback, MRT, points/billboards, mesh/depth, volume/cubemap behavior, deterministic automation, and errors. Where reference backends disagree, preserve both outputs and explain the selected authority; do not choose whichever makes a candidate pass.

GPU qualification uses actual compatible hardware and the actual target runtime. CPU-only CI may validate syntax, catalog generation, graph equivalence, and reports; it cannot qualify rendering. Scheduled graphics work must use a capability-matched host broker. A job container's missing graphics device is not evidence that fleet GPU access is absent. No fleet jobs, intake recipes, or scheduling are created by this planning task.

## 5. Qualification sequence and risks

1. Real macOS Metal device, Swift/Tint ABI and package feasibility.
2. Golden-graph solid, asymmetric textures, MRT, uniform layout, and completion lifetimes.
3. Multipass, feedback, repeats, geometry/volume, compute where required.
4. Native Swift compiler and full effect catalog against WebGPU.
5. MetalKit embedding, clean package consumer, and physical iOS/iPadOS qualification.

High-risk areas are WGSL/MSL numeric differences, translator options, resource-slot remapping, Swift buffer alignment, in-flight reuse, WebGPU-versus-Metal clip/texture conventions, and runtime compiler packaging. A simulator build or successful `swift test` without a GPU is not device qualification.

New effects, editor UI, network services, Core Image reimplementation, non-Metal rendering, export-site publication, and fleet enrollment are outside the initial implementation. Public distribution and store submission are separate work. Input capture and app permissions stay with the host, while reference-compatible input processing remains in the library scope.

## 6. Performance and distribution

Measure cold translation, Metal compilation, pipeline-cache reuse, CPU encode cost, GPU execution time, readback, allocations, and in-flight memory separately at 256×256, 512×512, 1920×1080, and an odd-sized target. Use generators, multipass filters, simulations and geometry. Record device, OS, compiler, translator, source and exact frame protocol; no unmeasured frame-rate promise belongs in the README.

Propose a Swift Package with isolated C/C++ translation support, plus a macOS render tool and optional MetalKit integration. The first packaging probe determines whether source or reviewed binary distribution of the translation target is practical on each intended platform. Test a clean consumer without sibling checkouts, Node, Rust or runtime downloads. Audit upstream/Tint/transitive notices before importing code. Do not select an old build to evade failing parity or deployment gates.

## 7. Evidence and source references

The local planning review on 2026-10-07 observed 210 `definition.js` files, 301 GLSL files, and 309 WGSL files under upstream `shaders/effects`. These are file inventory counts, not rendered coverage or a count of runnable pass variants. They can change before implementation.

| Upstream file | SHA-256 of inspected local bytes |
|---|---|
| `shaders/src/runtime/compiler.js` | `9a66ca9b7871450b8d3d6776bfb2d38e5ca00925e04270b48b82a92bb96cc3da` |
| `shaders/src/runtime/pipeline.js` | `f71ef923a404a9aca6df39f1fd3a916ef0ade5efbcc0ec076228a1b57d08898d` |
| `shaders/src/runtime/backends/webgl2.js` | `951ce0245fefaa29dda4dffe3e6fe0835773aa2a6f0e6889825676c772da894c` |
| `shaders/src/runtime/backends/webgpu.js` | `238faf45ea76e1b5f424ac11ea998cb1ca9a510b3d309abb71d19f4d003d4a11` |

Read upstream `shaders/src/lang/`, `shaders/src/runtime/{compiler,expander,resources,pipeline,external-input}.js`, the selected backend, and `shaders/effects/**/definition.js` before translating a subsystem. Relative links below assume sibling checkouts; they are engineering references, not shipping package dependencies.

- [Upstream graph compiler](../noisemaker/shaders/src/runtime/compiler.js)
- [Upstream pipeline](../noisemaker/shaders/src/runtime/pipeline.js)
- [Qt architecture](../noisemaker-for-qt/ARCHITECTURE.md)
- [Qt graph normalization contract](../noisemaker-for-qt/docs/GRAPH-JSON-SCHEMA.md)
- [Godot implementation plan](../noisemaker-for-godot/docs/IMPLEMENTATION-PLAN.md)

Sibling documentation records its own historical decisions. Reconfirm them against current source; do not inherit old completion claims, hard-coded catalog counts, blanket texture formats, or host assumptions.


Additional implementation references:

- [Rust Metal/Tint binding integration](../noisemaker-for-rust-gpu/crates/noisemaker-gpu/src/backend/tint.rs)
- [Rust Tint ownership and options contract](../noisemaker-for-rust-gpu/crates/noisemaker-tint/shim/nm_tint.h)
- [Apple Metal documentation](https://developer.apple.com/documentation/metal)
- [Apple Metal textures](https://developer.apple.com/documentation/metal/textures)
