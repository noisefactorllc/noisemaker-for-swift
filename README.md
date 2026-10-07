# Noisemaker for Swift

## 1. Status

Planned GPU port of Noisemaker with a native Swift compiler and Metal renderer. This repository currently contains guiding documents only. No Swift package, shader library, demo, or release exists yet.

## 2. Intended result

A Swift Package will expose the Polymorphic DSL compiler, GPU render-graph runtime, and effect catalog. Applications will receive Metal textures for their own rendering or use a small optional MetalKit adapter. The effect pipeline remains on the GPU; Swift performs compilation and orchestration.

The first qualification target is macOS on Apple Silicon. iOS/iPadOS device qualification is a subsequent stage of this port. Intel/AMD Macs and other Apple platforms require separate evidence before support is claimed. Swift and deployment-version floors will be chosen from actual compiler/API probes in the first implementation milestone, rather than invented here.

## 3. Documents

- [Architecture](ARCHITECTURE.md): native runtime, shader strategy, graph contract, qualification, and sources.
- [Porting guide](PORTING-GUIDE.md): WGSL-to-MSL translation, resource binding, Swift semantics, and Metal lifetimes.
- [Implementation plan](docs/IMPLEMENTATION-PLAN.md): ordered work packages, proposed paths/interfaces, and acceptance checks.

## 4. First milestone

Run upstream-exported graphs on a real Metal device, using WGSL translated to MSL through a small Tint C interface with explicit binding metadata: a solid color as a smoke test, then the 257×129 asymmetric marker as the first parity gate against an upstream WebGPU golden minted in the same run. A solid color is not parity evidence: the family grader counts a golden with no structure as uninformative. This qualifies the shader/runtime seam before expanding the Swift compiler.

## 5. Repository state

Created as a local repository with default branch `main`. Planning does not authorize implementation, remote creation, publication, release automation, or Worker Elves enrollment. Creating the `noisefactorllc` remote enrolls the port: the scheduled port audits select every live repository named `noisemaker-for-*` and record one missing from their rotation as an inventory blocker. Create the remote only when the operator decides the port enters that rotation. Commands and APIs in the documents are proposals, not working quick-start instructions. Dependency, licensing and binary-distribution decisions remain implementation gates.
