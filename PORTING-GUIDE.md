# Noisemaker for Swift porting guide

## 1. Source authority

Use upstream WGSL and the WebGPU backend as primary numerical/execution authority, with [the architecture](ARCHITECTURE.md) defining the proposed native package. Inspect GLSL/WebGL2 only to diagnose a reference discrepancy, not to silently change authority per fixture. Preserve original WGSL bytes and regenerate definitions from the same observed source.

Study the Rust GPU port's Tint shim as a source-level reference. Reuse requires license review and explicit ownership of the copied translator interface. Do not import the Rust renderer, its wgpu slot assignments, its historical pass counts, or unverified fallback paths as Swift support.

## 2. Translation and numerical behavior

Assemble the exact WGSL variant before translation: defines, substitutions, stage entry point, overrides and shader source identity all belong in provenance. Record the Tint revision/options and generated MSL hash. Require deterministic translation for identical inputs.

Map each binding by group, index and resource kind; allocate buffer, texture and sampler slots independently. Reflect uniform/storage layouts and any translator-required immediate data, including storage lengths and depth-related constants. Match every stage's resource map, including vertex texture fetches. Reject unknown binding types with a stage/program diagnostic.

Test integer overflow, negative modulo, bit casts, half packing, texture addressing, matrix layout and derivatives. Record fast-math settings on both candidate and oracle. Do not reflexively enable aggressive optimization or assume disabling it guarantees parity. Where rounding affects discontinuous algorithms, retain explicit failing cases instead of widening global thresholds.

The C ABI returns owned output buffers with a matching release function, explicit lengths/status, and diagnostics. Swift must free success and error outputs exactly once. Do not pass Swift strings with assumed lifetimes to deferred C++ work. Test malformed WGSL and concurrent compilation according to the chosen serialization contract.

## 3. Swift compiler and data representation

Use a tagged `GraphValue` enum rather than untyped `Any` for null, booleans, numbers, strings, arrays and ordered objects. Missing fields remain distinct from null. Use `Double` where the reference uses JavaScript numbers; convert to shader scalar types only at the declared uniform boundary.

Keep source locations, diagnostic codes, aliases, defaults, enums, step indices, scoped parameters, `mediaSteps`, and insertion-order semantics. Swift dictionaries are not a substitute for an explicit serialized ordering contract. Normalize maps and `compiledAt` identically in oracle and candidate, leaving execution data intact.

Implement dynamic expressions as a dedicated parser/evaluator for reference semantics. Do not translate DSL directly into executable Swift or add JavaScriptCore as a shortcut. Current upstream refusal cases need separate classification; they do not prove implemented feature support.

## 4. Metal ABI, coordinates and formats

Do not `memcpy` arbitrary Swift structs into shader buffers. Build layout-aware writers with explicit offsets, stride and alignment; prove vec3 padding, arrays, matrices, booleans, signed/unsigned scalars and mixed fields using GPU echo tests.

Determine texture orientation, pixel centers, viewport mapping, clipping/depth range and matrix conventions from upstream WebGPU and asymmetric fixtures. Separate texture-order capture from presented output. Avoid global guessed flips and per-effect shader patches.

Match descriptor formats and linear/sRGB boundaries. Float intermediates, alpha, blend factors, depth comparison, culling and attachment load/store behavior must agree with the reference. Preserve data outside the display range until the specified capture boundary. Validate each MRT format combination on the real device; Metal feature-family membership alone is not rendered proof.

## 5. Synchronization and ownership

The proposed `encode` API borrows the caller's same-device command buffer and does not commit it. The host controls submission and downstream use. An `OutputLease` protects its texture through the final consumer's GPU completion, not merely through CPU return from `encode`. Test delayed consumers and command-buffer failures.

The convenience submitter caps in-flight frames and reuses uniform/upload storage only after completion. Serialize feedback frames or use proven per-frame state dependencies. Reject out-of-order/uncommitted frame use rather than allowing an implicit race. Reconfiguration must retire old textures/pipelines only after outstanding work releases them.

Read private GPU textures through a suitable blit/readback path. Honor row alignment and synchronize completion; qualify shared/managed-memory details separately on each device class if supported. CPU readback and PNG encoding are diagnostic/export operations, never mandatory for embedding or presentation.

## 6. Inputs, packaging and validation

The host supplies media textures, mesh/text data, and deterministic audio/MIDI state. Preserve texture ownership and per-step input names. Camera and microphone permissions, device selection, application UI and capture scheduling belong to the host. Images remain binary assets or GPU textures; saved/shared programs contain references, not image strings in JSON.

Compile and test the package on a clean consumer. Verify all catalog/shader resources are discoverable through package resource APIs, and the translation dependency needs neither sibling checkouts nor runtime downloads. Maintain separate evidence for source-build viability, shader compilation, rendered parity, MetalKit integration, and physical iOS/iPadOS operation.

Use architecture section 4's full-denominator reporting. GPU validation errors, stale provenance, missing outputs, NaN/Inf failures, mismatches, absent cases and timeouts remain visible. A package that compiles on an untested device is not a qualified package for that device.
