# {{NM_PROGRAM_NAME}}

This Swift package renders your Noisedeck program on the GPU of an Apple silicon Mac. `engine/` is the Swift package of [Noisemaker for Swift](https://github.com/noisefactorllc/noisemaker-for-swift): the Noisemaker DSL compiler written in Swift, the effect catalog with its WGSL shaders, the Tint shader translator that turns WGSL into Metal Shading Language, and a renderer that runs the program with Metal. `nm-render` compiles `program.dsl` and writes a PNG image.

## Requirements

- **A Mac with Apple silicon and macOS 14 or later.** The engine links two prebuilt static libraries in `engine/Artifacts/`, the Tint translator and a Skia raster library, and both are built for macOS on arm64 only. An Intel Mac cannot build the package.
- **Swift 6.0 or later.** Xcode 16 or later includes it. The Command Line Tools are enough without Xcode: `xcode-select --install` installs them. `swift --version` shows the version you have.

The package has no dependencies to download. The build compiles only the files in this folder, so it works without a network connection.

## Build

Unzip this folder and open a terminal in it. Build the renderer once:

```sh
swift build -c release --package-path engine --product nm-render
```

SwiftPM writes the build to `engine/.build/`. On an Apple M2 with macOS 14 and Swift 6.0, the first build took about two minutes. The renderer is `engine/.build/release/nm-render`, and its effect catalog and meshes are in `engine/.build/release/Noisemaker_Noisemaker.bundle` beside it. If you copy `nm-render` somewhere else, copy that bundle into the same folder. Without it, `nm-render` stops with `Fatal error: could not load resource bundle`.

## Render it

```sh
engine/.build/release/nm-render --dsl program.dsl --out out.png --width 512 --height 512
```

The command writes a 512×512 `out.png` the way Noisedeck shows it. Paths are relative to your working directory. `--dsl`, `--out`, `--width` and `--height` are required.

Two options set the moment that is rendered:

- `--time T` is the point in the program's loop, as a fraction of the loop from 0 to 1. The default is 0, the start of the loop; `--time 0.5` is the middle.
- `--frames N` renders N frames, from 1 to 4096, and writes the last one. The default is 1. Every frame runs the whole program once at the same `--time`, so feedback, simulation and particle effects advance from one frame to the next while the time stays the same. A program that builds up over time needs more frames.

For example, this renders 8 frames a quarter of the way into the loop:

```sh
engine/.build/release/nm-render --dsl program.dsl --out out.png --width 512 --height 512 --time 0.25 --frames 8
```

## What it cannot render

Noisedeck exports the program, not the media, text or devices it ran with, and `nm-render` has no option to supply them.

- **Text.** A program with a `text()` step stops with `nm-render: Missing graph resource: external textures ["textTex_step_1"]` (the step number varies) and exit status 1.
- **Media.** A program with a `media()` step stops the same way, naming `imageTex`.
- **Meshes.** A `meshLoader()` step draws the built-in sphere. `nm-render` cannot load an OBJ file of your own.
- **MIDI and audio.** There is no live MIDI or audio input.

The `fibers()`, `scratches()` and `strayHair()` overlays need no input: `nm-render` draws them itself.

## Exit status

`nm-render` exits with status 0 when it wrote the image. It exits with status 1 and prints a message that starts with `nm-render:` on standard error for every other result: a command-line mistake, a program file it cannot read, a program that does not compile, or a missing text or media input. A copy of `nm-render` without its resource bundle crashes instead (see Build).

## Using the engine in your own app

`engine/` is an ordinary Swift package. Add it to your app as a local package dependency. SwiftPM names a local package after its folder, so the package name is `engine`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "path/to/this/folder/engine")],
    targets: [
        .executableTarget(name: "MyApp", dependencies: [
            .product(name: "Noisemaker", package: "engine"),
            .product(name: "NoisemakerMetalKit", package: "engine"), // optional MTKView adapter
        ]),
    ]
)
```

This renders a program into a Metal texture:

```swift
import Metal
import Noisemaker

let compiler = try NoisemakerCompiler()
let graph = try compiler.compileForHost(source: "search synth\nnoise(seed: 1).write(o0)\nrender(o0)\n")

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue(),
      let command = queue.makeCommandBuffer() else { fatalError("This example needs a Metal device") }

let renderer = try NoisemakerRenderer(device: device, graph: graph,
                                      size: try RenderSize(width: 512, height: 512))
let output = try renderer.encode(frame: FrameState(time: 0.5, delta: 1.0 / 600, frameIndex: 300),
                                 into: command)
command.commit()
command.waitUntilCompleted()
// output.texture is an MTLTexture (rgba16Float) holding the frame.
```

`NoisemakerViewRenderer` in `NoisemakerMetalKit` shows a program in an `MTKView`. Your app supplies the text, media and mesh textures that `nm-render` cannot, through `externalTextures`. <https://github.com/noisefactorllc/noisemaker-for-swift> documents the API.

## What's inside

| Path | What it is |
| --- | --- |
| `program.dsl` | Your program's source, exactly as it was in Noisedeck. |
| `engine/Package.swift` | The package manifest. |
| `engine/Sources/NMRender/` | The command-line renderer. |
| `engine/Sources/Noisemaker/` | The compiler, the Metal renderer and the effect catalog with its built-in meshes. |
| `engine/Sources/NoisemakerMetalKit/` | The optional `MTKView` adapter. |
| `engine/Sources/NMViewer/` | A small preview window built on the adapter (`nm-viewer`). |
| `engine/Artifacts/` | The prebuilt Tint translator and Skia raster libraries for macOS on arm64. |
| `engine/Tests/` | A placeholder that the manifest's test target needs. The test suites are not included. |
| `noisedeck-export.json` | What was exported, when, and from which port commit. |
| `LICENSES/` | Licenses for everything shipped here and built from it. |

You can delete `engine/.build/` at any time; the next build takes longer.

## Effects used by this program

{{NM_EFFECT_LIST}}

## Editing it

Replace `program.dsl` with another Noisemaker program and run the same render command. The build is already done, so only the render repeats.

Noisedeck exported this program against Noisemaker `{{NM_ENGINE_VERSION}}`. The engine here is a separate implementation, tested for pixel parity against the Noisemaker revision it pins; `authority.commit` in `engine/Sources/Noisemaker/Resources/catalog.json` names that revision. An effect added to Noisemaker after it is not in this catalog, and a program that uses one does not compile.

## License

The Noisemaker engine and this port are MIT licensed: `LICENSES/noisemaker-MIT.txt` and `LICENSES/noisemaker-for-swift-LICENSE.txt`. The prebuilt libraries in `engine/Artifacts/` are compiled from third-party code, and the build links them into `nm-render`: Tint, from Dawn (BSD 3-Clause, `LICENSES/Dawn-LICENSE.txt`), with Abseil (Apache 2.0, `LICENSES/abseil-cpp-Apache-2.0.txt`) and SPIRV-Headers (`LICENSES/SPIRV-Headers-LICENSE.txt`), and Skia (BSD 3-Clause, `LICENSES/Skia-LICENSE.txt`). Your program and the imagery it renders are yours.
