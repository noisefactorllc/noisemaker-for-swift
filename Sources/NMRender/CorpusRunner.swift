import CryptoKit
import Foundation
import Metal
import Noisemaker

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct CorpusCapture {
    let size: RenderSize
    let frameCount: Int
    let sampledFrames: Set<Int>
    let timed: Bool
    let time: Double
    let delta: Double

    init(_ raw: [String: Any]) throws {
        let baseFields: Set<String> = ["size", "sample", "orientation", "resetState", "audioInput", "volumeInput"]
        let timedFields: Set<String> = ["frameTime", "runSeconds", "sampleEverySeconds", "sampleFrames"]
        let fixedFields: Set<String> = ["frames", "normalizedTime", "deltaTime"]
        let legacyFields: Set<String> = ["dslSha256", "externalInputs", "inputAssets", "seed"]
        let allowed = baseFields.union(raw["frameTime"] == nil ? fixedFields : timedFields)
            .union(raw["dslSha256"] == nil ? [] : legacyFields)
        guard Set(raw.keys).isSubset(of: allowed) else {
            throw GraphDiagnostic.unsupported("unknown corpus capture protocol field")
        }
        guard raw["orientation"] as? String == "top-down RGBA8 PNG" else {
            throw GraphDiagnostic.unsupported("corpus capture orientation")
        }
        let standardSample = raw["sample"] as? String == "WebGPU presented surface"
        let legacySample = raw["sample"] as? String == "presented surface after frame 8"
        guard standardSample || legacySample else {
            throw GraphDiagnostic.unsupported("corpus capture sample surface")
        }
        let freshState = raw["resetState"] as? Bool == true
        let legacyFreshState = raw["resetState"] as? String ==
            "clear pipeline writes; preserve host inputs; reset surfaces, frameIndex, lastTime and globals"
        guard freshState || legacyFreshState else {
            throw GraphDiagnostic.unsupported("corpus capture reset protocol")
        }
        if legacyFreshState {
            guard let inputs = raw["externalInputs"] as? [[String: Any]],
                  let assets = raw["inputAssets"] as? [[String: Any]] else {
                throw GraphDiagnostic.unsupported("corpus external input assets")
            }
            if let volume = raw["volumeInput"] as? [String: Any] {
                guard inputs.count == 1, assets.count == 1,
                      Set(inputs[0].keys) == ["id", "kind", "frame"],
                      inputs[0]["id"] as? String == volume["id"] as? String,
                      inputs[0]["kind"] as? String == "texture3d",
                      inputs[0]["frame"] as? Int == 0,
                      Set(assets[0].keys) == ["path", "sha256"],
                      assets[0]["path"] as? String == volume["assetPath"] as? String,
                      assets[0]["sha256"] as? String == volume["assetSha256"] as? String else {
                    throw GraphDiagnostic.unsupported("corpus external input assets")
                }
            } else if !inputs.isEmpty || !assets.isEmpty {
                throw GraphDiagnostic.unsupported("corpus external input assets")
            }
            if let seed = raw["seed"], !(seed is NSNull) {
                guard seed as? Int == 1 else {
                    throw GraphDiagnostic.unsupported("corpus external seed")
                }
            }
        }
        guard let dimensions = raw["size"] as? [Int], dimensions.count == 2 else {
            throw GraphDiagnostic.invalid("corpus capture lacks width and height")
        }
        size = try RenderSize(width: dimensions[0], height: dimensions[1])
        if let formula = raw["frameTime"] as? String {
            guard formula == "((frame + 1) / 600) % 1",
                  let runSeconds = raw["runSeconds"] as? Int,
                  (1...5).contains(runSeconds),
                  raw["sampleEverySeconds"] as? Int == 1,
                  standardSample, freshState,
                  let samples = raw["sampleFrames"] as? [Int], !samples.isEmpty,
                  samples.allSatisfy({ (1...(600 * runSeconds)).contains($0) }),
                  Set(samples).count == samples.count else {
                throw GraphDiagnostic.unsupported("corpus timed frame protocol")
            }
            timed = true
            sampledFrames = Set(samples).union((1...runSeconds).map { $0 * 600 })
            frameCount = runSeconds * 600
            time = 0
            delta = 0
        } else {
            guard let frames = raw["frames"] as? Int, (1...3_000).contains(frames),
                  let time = raw["normalizedTime"] as? Double, time.isFinite,
                  let delta = raw["deltaTime"] as? Double, delta.isFinite,
                  !legacySample || frames == 8 else {
                throw GraphDiagnostic.unsupported("corpus fixed frame protocol")
            }
            timed = false
            sampledFrames = [frames]
            frameCount = frames
            self.time = time
            self.delta = delta
        }
    }

    func state(at index: Int, inputs: AutomationInputs = AutomationInputs(),
               hostUniforms: [String: [String: GraphValue]] = [:]) -> FrameState {
        if timed {
            let normalized = (Double(index + 1) / 600).truncatingRemainder(dividingBy: 1)
            let previous = (Double(index) / 600).truncatingRemainder(dividingBy: 1)
            var delta = previous > 0 ? normalized - previous : 0
            if delta < 0 {
                delta = 1.0 / 60.0 / 10.0
            }
            return FrameState(time: normalized, delta: delta, frameIndex: UInt64(index),
                inputs: inputs, hostUniforms: hostUniforms)
        }
        return FrameState(time: time, delta: delta, frameIndex: UInt64(index),
            inputs: inputs, hostUniforms: hostUniforms)
    }
}

private func corpusOptions(_ raw: [String]) throws -> (URL, URL, URL?, [String], Bool) {
    var corpus: URL?, output: URL?, goldens: URL?, ids: [String] = []
    var compileOnly = false
    var index = 0
    while index < raw.count {
        switch raw[index] {
        case "--compile-only":
            guard !compileOnly else { throw GraphDiagnostic.invalid("duplicate --compile-only") }
            compileOnly = true
            index += 1
        case "--corpus", "--out-dir", "--goldens":
            guard index + 1 < raw.count else {
                throw GraphDiagnostic.invalid("--corpus and --out-dir require paths")
            }
            let path = URL(fileURLWithPath: raw[index + 1])
            if raw[index] == "--corpus" {
                guard corpus == nil else { throw GraphDiagnostic.invalid("duplicate --corpus") }
                corpus = path
            } else if raw[index] == "--out-dir" {
                guard output == nil else { throw GraphDiagnostic.invalid("duplicate --out-dir") }
                output = path
            } else {
                guard goldens == nil else { throw GraphDiagnostic.invalid("duplicate --goldens") }
                goldens = path
            }
            index += 2
        default:
            guard !raw[index].hasPrefix("--") else {
                throw GraphDiagnostic.invalid("unknown corpus option \(raw[index])")
            }
            ids.append(raw[index])
            index += 1
        }
    }
    guard let corpus, let output, Set(ids).count == ids.count else {
        throw GraphDiagnostic.invalid("usage: nm-render --corpus corpus.json --out-dir candidates [case-id ...]")
    }
    guard !compileOnly || goldens == nil else {
        throw GraphDiagnostic.invalid("--goldens applies only to Metal rendering")
    }
    return (corpus, output, goldens, ids, compileOnly)
}

private struct GoldenCases {
    let directory: URL
    let byID: [String: [String: Any]]
}

private struct GoldenAdmission {
    let maximumTextureDimension2D: Int
    let sourceFailed: Bool
}

private func absentOrEmptyArray(_ value: Any?) -> Bool {
    guard let value else { return true }
    guard let array = value as? [Any] else { return false }
    return array.isEmpty
}

private func verifyGoldenAdmission(_ goldens: GoldenCases?, caseID: String,
                                   sourceSHA: String, capture: [String: Any],
                                   assets: [[String: Any]]) throws -> GoldenAdmission? {
    guard let goldens else { return nil }
    guard let golden = goldens.byID[caseID], golden["id"] as? String == caseID,
          golden["sourceSha256"] as? String == sourceSHA,
          let goldenCapture = golden["capture"] as? [String: Any],
          let actualCapture = try? JSONSerialization.data(withJSONObject: capture, options: [.sortedKeys]),
          let expectedCapture = try? JSONSerialization.data(withJSONObject: goldenCapture, options: [.sortedKeys]),
          actualCapture == expectedCapture,
          golden["backend"] as? String == "WebGPU",
          let profile = golden["capabilityProfile"] as? [String: Any],
          let limit = profile["maxTextureDimension2D"] as? Int,
          (256...16_384).contains(limit) else {
        throw GraphDiagnostic.invalid("case \(caseID) golden source, capture, or capability profile differs")
    }
    if golden["status"] as? String == "ok" {
        return GoldenAdmission(maximumTextureDimension2D: limit, sourceFailed: false)
    }
    guard golden["status"] as? String == "fail",
          assets.isEmpty, capture["volumeInput"] == nil, capture["audioInput"] == nil,
          absentOrEmptyArray(capture["externalInputs"]),
          absentOrEmptyArray(capture["inputAssets"]),
          absentOrEmptyArray(golden["images"]),
          absentOrEmptyArray(golden["hostTextures"]),
          absentOrEmptyArray(golden["hostVolumes"]),
          golden["hostAudio"] == nil, golden["hostInputMode"] == nil,
          let error = golden["error"] as? String,
          error.range(of: "compilation failed", options: .caseInsensitive) != nil,
          error.range(of: "createTexture", options: .caseInsensitive) != nil,
          error.range(of: "height", options: .caseInsensitive) != nil,
          ["unsigned long", "GPUExtent3D", "invalid", "non-finite", "nonfinite", "integer", "not of type"]
              .contains(where: { error.range(of: $0, options: .caseInsensitive) != nil }) else {
        throw GraphDiagnostic.invalid("case \(caseID) failed golden is not an input-free texture-height refusal")
    }
    return GoldenAdmission(maximumTextureDimension2D: limit, sourceFailed: true)
}

private func loadGoldenCases(_ url: URL?, corpusData: Data) throws -> GoldenCases? {
    guard let url else { return nil }
    let data = try Data(contentsOf: url)
    guard let ledger = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          ledger["schemaVersion"] as? Int == 1,
          ledger["corpusSha256"] as? String == digest(corpusData),
          let cases = ledger["cases"] as? [[String: Any]] else {
        throw GraphDiagnostic.invalid("golden ledger schema or corpus SHA differs")
    }
    var byID: [String: [String: Any]] = [:]
    for item in cases {
        guard let id = item["id"] as? String, byID[id] == nil else {
            throw GraphDiagnostic.invalid("golden ledger has missing or repeated case id")
        }
        byID[id] = item
    }
    return GoldenCases(directory: url.deletingLastPathComponent(), byID: byID)
}

private func loadHostTextures(goldens: GoldenCases?, caseID: String,
                              sourceSHA: String, capture: [String: Any],
                              required: [String], device: MTLDevice,
                              sourceFailed: Bool, nativeOverlays: [String: OverlayPixels])
    throws -> ([String: MTLTexture], [[String: Any]]) {
    guard let goldens else {
        guard Set(required).isSubset(of: Set(nativeOverlays.keys)) else {
            throw GraphDiagnostic.missing("case \(caseID) requires WebGPU host texture captures")
        }
        var textures: [String: MTLTexture] = [:]
        var evidence: [[String: Any]] = []
        for id in required {
            let overlay = nativeOverlays[id]!
            textures[id] = try TextureInput.rgba8(device: device, pixels: overlay.rgba, size: overlay.size)
            evidence.append(["id": id, "frame": 0, "sha256": digest(overlay.rgba),
                "width": overlay.size.width, "height": overlay.size.height,
                "format": "rgba8unorm", "orientation": "top-down",
                "bytesPerRow": overlay.size.width * 4, "origin": "nativeCpuOverlay"])
        }
        return (textures, evidence)
    }
    guard let golden = goldens.byID[caseID],
          (golden["status"] as? String == "ok" ||
              (sourceFailed && golden["status"] as? String == "fail")),
          golden["id"] as? String == caseID,
          golden["sourceSha256"] as? String == sourceSHA,
          let goldenCapture = golden["capture"] as? [String: Any],
          let actualCapture = try? JSONSerialization.data(withJSONObject: capture, options: [.sortedKeys]),
          let expectedCapture = try? JSONSerialization.data(withJSONObject: goldenCapture, options: [.sortedKeys]),
          actualCapture == expectedCapture else {
        throw GraphDiagnostic.invalid("case \(caseID) golden source or capture differs")
    }
    if sourceFailed {
        guard required.isEmpty else {
            throw GraphDiagnostic.invalid("case \(caseID) failed golden requires host textures")
        }
        return ([:], [])
    }
    let entries: [[String: Any]]
    if let raw = golden["hostTextures"] {
        guard let parsed = raw as? [[String: Any]] else {
            throw GraphDiagnostic.invalid("case \(caseID) malformed golden hostTextures")
        }
        entries = parsed
    } else {
        guard required.isEmpty else {
            throw GraphDiagnostic.missing("case \(caseID) golden lacks hostTextures metadata")
        }
        entries = []
    }
    guard entries.count == required.count else {
        throw GraphDiagnostic.invalid("case \(caseID) host texture count differs from graph")
    }
    if entries.isEmpty { return ([:], []) }
    var textures: [String: MTLTexture] = [:]
    var evidence: [[String: Any]] = []
    for entry in entries {
        guard let id = entry["id"] as? String, required.contains(id), textures[id] == nil,
              let frame = entry["frame"] as? Int, frame == 0,
              let width = entry["width"] as? Int, width > 0,
              let height = entry["height"] as? Int, height > 0,
              width <= 16_384,
              height <= 16_384,
              width <= Int.max / 4 / height,
              width * height <= 64 * 1024 * 1024,
              entry["bytesPerRow"] as? Int == width * 4,
              entry["format"] as? String == "rgba8unorm",
              entry["orientation"] as? String == "top-down",
              let expectedSHA = entry["sha256"] as? String,
              expectedSHA.count == 64,
              expectedSHA.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let path = entry["path"] as? String, !path.isEmpty else {
            throw GraphDiagnostic.invalid("case \(caseID) malformed host texture metadata")
        }
        let file: URL
        if path.hasPrefix("/") {
            file = URL(fileURLWithPath: path)
        } else {
            let base = goldens.directory.standardizedFileURL
            let relative = base.appendingPathComponent(path).standardizedFileURL
            guard relative.path.hasPrefix(base.path + "/") else {
                throw GraphDiagnostic.invalid("case \(caseID) host texture path escapes golden directory")
            }
            file = relative
        }
        let bytes: Data
        if let overlay = nativeOverlays[id] {
            guard overlay.size.width == width, overlay.size.height == height else {
                throw GraphDiagnostic.invalid("case \(caseID) native overlay dimensions differ")
            }
            bytes = overlay.rgba
        } else {
            bytes = try Data(contentsOf: file)
        }
        guard bytes.count == width * height * 4,
              digest(bytes) == expectedSHA else {
            throw GraphDiagnostic.invalid("case \(caseID) host texture \(id) bytes or SHA differ")
        }
        let texture = try TextureInput.rgba8(device: device, pixels: bytes,
            size: RenderSize(width: width, height: height))
        textures[id] = texture
        evidence.append(["id": id, "frame": 0, "sha256": expectedSHA,
                         "width": width, "height": height,
                         "format": "rgba8unorm", "orientation": "top-down",
                         "bytesPerRow": width * 4,
                         "origin": nativeOverlays[id] == nil ? "referenceReplay" : "nativeCpuOverlay"])
    }
    guard Set(textures.keys) == Set(required) else {
        throw GraphDiagnostic.invalid("case \(caseID) host texture IDs differ from graph")
    }
    return (textures, evidence)
}

private func loadHostVolume(corpusURL: URL, goldens: GoldenCases?, caseID: String,
                            capture: [String: Any], required: [String], device: MTLDevice)
    throws -> ([String: MTLTexture], [[String: Any]]) {
    guard let metadata = capture["volumeInput"] as? [String: Any] else {
        guard capture["volumeInput"] == nil, required.isEmpty else {
            throw GraphDiagnostic.missing("case \(caseID) requires one declared host volume")
        }
        return ([:], [])
    }
    let fields: Set<String> = ["id", "assetPath", "assetSha256", "width", "height", "depth",
                               "format", "orientation", "bytesPerRow", "bytesPerImage",
                               "frame", "updatePolicy"]
    guard Set(metadata.keys) == fields,
          let id = metadata["id"] as? String, required == [id],
          let path = metadata["assetPath"] as? String,
          path.hasPrefix("parity/inputs/"), !path.contains(".."),
          let expectedSHA = metadata["assetSha256"] as? String,
          expectedSHA.count == 64,
          expectedSHA.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
          let width = metadata["width"] as? Int,
          let height = metadata["height"] as? Int,
          let depth = metadata["depth"] as? Int,
          width > 0, height > 0, depth > 0,
          width <= 2_048, height <= 2_048, depth <= 2_048,
          width <= Int.max / 4 / height,
          width * height <= Int.max / 4 / depth,
          width * height * depth <= 64 * 1024 * 1024,
          metadata["bytesPerRow"] as? Int == width * 4,
          metadata["bytesPerImage"] as? Int == width * height * 4,
          metadata["format"] as? String == "rgba8unorm",
          metadata["orientation"] as? String == "x-fastest-y-next-z-outermost",
          metadata["frame"] as? Int == 0,
          metadata["updatePolicy"] as? String == "static-before-frame-1" else {
        throw GraphDiagnostic.invalid("case \(caseID) host volume metadata differs from source protocol")
    }
    let projectRoot = corpusURL.deletingLastPathComponent().deletingLastPathComponent()
        .standardizedFileURL
    let asset = projectRoot.appendingPathComponent(path).standardizedFileURL
    guard asset.path.hasPrefix(projectRoot.path + "/") else {
        throw GraphDiagnostic.invalid("case \(caseID) host volume path escapes corpus root")
    }
    let bytes = try Data(contentsOf: asset)
    guard bytes.count == width * height * depth * 4,
          digest(bytes) == expectedSHA else {
        throw GraphDiagnostic.invalid("case \(caseID) host volume bytes or SHA differ")
    }
    if let goldens {
        guard let golden = goldens.byID[caseID],
              let entries = golden["hostVolumes"] as? [[String: Any]], entries.count == 1,
              let goldenSHA = entries[0]["sha256"] as? String,
              goldenSHA == expectedSHA,
              let goldenPath = entries[0]["path"] as? String else {
            throw GraphDiagnostic.invalid("case \(caseID) golden host volume proof is missing")
        }
        var goldenMetadata = entries[0]
        goldenMetadata.removeValue(forKey: "path")
        goldenMetadata.removeValue(forKey: "sha256")
        let sourceFields = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let capturedFields = try JSONSerialization.data(withJSONObject: goldenMetadata, options: [.sortedKeys])
        guard sourceFields == capturedFields,
              let goldenBytes = try? Data(contentsOf: URL(fileURLWithPath: goldenPath)),
              goldenBytes == bytes else {
            throw GraphDiagnostic.invalid("case \(caseID) golden host volume differs from tracked asset")
        }
    }
    let texture = try TextureInput.rgba8Volume(device: device, pixels: bytes,
                                               width: width, height: height, depth: depth)
    var evidence = metadata
    evidence["sha256"] = expectedSHA
    return ([id: texture], [evidence])
}

private func loadAudioInput(capture: [String: Any], assets: [[String: Any]])
    throws -> (AudioInputSnapshot?, [String: Any]?, Bool) {
    let audioAssets = assets.filter {
        ($0["path"] as? String)?.hasSuffix("/audio-v1.json") == true
    }
    guard let metadata = capture["audioInput"] as? [String: Any] else {
        guard capture["audioInput"] == nil, audioAssets.isEmpty else {
            throw GraphDiagnostic.invalid("audio sidecar lacks capture metadata")
        }
        return (nil, nil, false)
    }
    let plainArray = metadata["representation"] as? String == "plain-array"
    let expectedFields: Set<String> = ["assetPath", "assetSha256", "frame", "updatePolicy"]
    guard Set(metadata.keys) == expectedFields.union(plainArray ? ["representation"] : []),
          let path = metadata["assetPath"] as? String,
          let assetSHA = metadata["assetSha256"] as? String,
          metadata["frame"] as? Int == 0,
          metadata["updatePolicy"] as? String == "static-before-frame-1",
          audioAssets.count == 1,
          audioAssets[0]["path"] as? String == path,
          audioAssets[0]["sha256"] as? String == assetSHA,
          let text = audioAssets[0]["text"] as? String,
          digest(Data(text.utf8)) == assetSHA,
          let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          raw["schemaVersion"] as? Int == 1,
          raw["frame"] as? Int == 0,
          raw["updatePolicy"] as? String == "static-before-frame-1",
          raw["sourceAPI"] as? String == "AudioState.setWaveform/setSpectrum",
          raw["inputFormat"] as? String == "analyser-uint8",
          raw["shaderFormat"] as? String == "array<vec4<f32>,32>",
          raw["sampleCount"] as? Int == 128,
          raw["normalization"] as? String == "locked AudioState byte/255 rounded to float32" else {
        throw GraphDiagnostic.invalid("audio sidecar metadata or source format")
    }
    func samples(_ name: String) throws -> ([Float], String) {
        guard let values = raw["\(name)Bytes"] as? [Int], values.count == 128,
              values.allSatisfy({ (0...255).contains($0) }),
              let expected = raw["\(name)F32"] as? [String: Any],
              expected["path"] as? String == "audio-v1.\(name).f32le",
              expected["bytes"] as? Int == 512,
              let expectedSHA = expected["sha256"] as? String else {
            throw GraphDiagnostic.invalid("audio \(name) samples or hash metadata")
        }
        let normalized = values.map { Float(Double($0) / 255) }
        var packed = Data(capacity: 512)
        for value in normalized {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { packed.append(contentsOf: $0) }
        }
        guard digest(packed) == expectedSHA else {
            throw GraphDiagnostic.invalid("audio \(name) Float32 bytes differ from source oracle")
        }
        return (normalized, expectedSHA)
    }
    let (waveform, waveformSHA) = try samples("waveform")
    let (spectrum, spectrumSHA) = try samples("spectrum")
    let snapshot = AudioInputSnapshot(waveform: waveform, spectrum: spectrum)
    var evidence: [String: Any] = ["frame": 0, "assetPath": path,
        "assetSha256": assetSHA, "updatePolicy": "static-before-frame-1",
        "waveformF32Sha256": waveformSHA, "spectrumF32Sha256": spectrumSHA]
    if plainArray { evidence["representation"] = "plain-array" }
    return (snapshot, evidence, plainArray)
}

private func corpusAudioUniforms(graph: RenderGraph, snapshot: AudioInputSnapshot?,
                                 plainArray: Bool)
    throws -> [String: [String: GraphValue]] {
    var result: [String: [String: GraphValue]] = [:]
    for pass in graph.passes {
        guard let program = graph.programs[pass.program] else {
            throw GraphDiagnostic.missing("audio pass program \(pass.program)")
        }
        let names = ["audioWaveform", "audioSpectrum"].filter {
            program.resolvedWGSL.contains($0)
        }
        guard !names.isEmpty else { continue }
        guard let node = pass.raw.field("nodeId")?.stringValue else {
            throw GraphDiagnostic.invalid("audio pass \(pass.id) lacks node identity")
        }
        for name in names {
            let samples = name == "audioWaveform" ? snapshot?.waveform : snapshot?.spectrum
            // The corrected source binds AudioState's Float32Array and plain
            // arrays identically. Omitted audio retains the source's zero input.
            let bound = samples ?? [Float](repeating: 0, count: 128)
            guard bound.count == 128 else {
                throw GraphDiagnostic.invalid("audio requires 128 \(name) samples")
            }
            result[node, default: [:]][name] = .array(bound.map { .number(Double($0)) })
        }
    }
    guard !plainArray || !result.isEmpty else {
        throw GraphDiagnostic.invalid("plain-array audio case has no shader audio binding")
    }
    return result
}

private func prepareMeshes(graph: RenderGraph, assets: [[String: Any]],
                           device: MTLDevice) throws -> [String: MTLTexture] {
    let objAssets = assets.filter { ($0["path"] as? String)?.hasSuffix(".obj") == true }
    let meshNames = graph.externalTextureNames.filter {
        $0.range(of: #"^global_mesh[0-7]_(positions|normals|uvs)(?:_chain_[0-9]+)?$"#,
            options: .regularExpression) != nil
    }
    guard !meshNames.isEmpty else {
        guard objAssets.isEmpty else {
            throw GraphDiagnostic.unsupported("corpus OBJ asset has no mesh texture consumer")
        }
        return [:]
    }
    guard meshNames.allSatisfy({ $0.hasPrefix("global_mesh0_") }) else {
        throw GraphDiagnostic.unsupported("corpus uses more than the mesh0 host surface")
    }
    guard objAssets.count <= 1 else {
        throw GraphDiagnostic.invalid("corpus has multiple OBJ input assets")
    }
    let mesh: OBJMesh
    if let asset = objAssets.first, let text = asset["text"] as? String {
        mesh = try OBJMesh.parse(text)
    } else if graph.passes.contains(where: {
        $0.raw.field("effectKey")?.stringValue == "render.meshLoader"
    }) {
        mesh = try BuiltinMesh.sphere.load()
    } else {
        mesh = try OBJMesh.parse("")
    }
    return try MeshInput.prepare(device: device, graph: graph,
        meshes: ["mesh0": mesh])
}

func runCorpus(_ raw: [String]) throws {
    let (corpusURL, outputDirectory, goldenURL, requested, compileOnly) = try corpusOptions(raw)
    let corpusData = try Data(contentsOf: corpusURL)
    guard let corpus = try JSONSerialization.jsonObject(with: corpusData) as? [String: Any],
          corpus["schemaVersion"] as? Int == 1,
          let allCases = corpus["cases"] as? [[String: Any]] else {
        throw GraphDiagnostic.invalid("corpus schema or cases")
    }
    var seenIDs = Set<String>()
    for item in allCases {
        guard let id = item["id"] as? String, seenIDs.insert(id).inserted else {
            throw GraphDiagnostic.invalid("corpus case id is missing or repeated")
        }
    }
    let selected: [[String: Any]]
    if requested.isEmpty {
        selected = allCases
    } else {
        let byID = Dictionary(uniqueKeysWithValues: allCases.compactMap { item -> (String, [String: Any])? in
            guard let id = item["id"] as? String else { return nil }
            return (id, item)
        })
        selected = try requested.map { id in
            guard let item = byID[id] else { throw GraphDiagnostic.invalid("unknown corpus case \(id)") }
            return item
        }
    }
    let goldenCases = try loadGoldenCases(goldenURL, corpusData: corpusData)
    let baseRegistry = try EffectRegistry.bundled()
    let vertexWGSL = baseRegistry.defaultVertex.field("wgsl")?.stringValue
    let vertexEntry = baseRegistry.defaultVertex.field("entryPoint")?.stringValue
    let device = compileOnly ? nil : MTLCreateSystemDefaultDevice()
    guard compileOnly || (vertexWGSL != nil && vertexEntry != nil && device != nil) else {
        throw GraphDiagnostic.missing("bundled vertex program or native Metal device")
    }
    try FileManager.default.createDirectory(at: outputDirectory,
        withIntermediateDirectories: true)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    var runtimeEnvironment: [String: Any] = [
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "executableSha256": digest(try Data(contentsOf: executable)),
        "architecture": "arm64"
    ]
    if let device {
        runtimeEnvironment["device"] = ["name": device.name,
            "registryID": String(device.registryID), "hasUnifiedMemory": device.hasUnifiedMemory,
            "maxBufferLength": device.maxBufferLength]
    }
    var records: [[String: Any]] = []
    for item in selected {
        guard let id = item["id"] as? String,
              let source = item["source"] as? String,
              let sourceSHA = item["sourceSha256"] as? String else {
            throw GraphDiagnostic.invalid("corpus case identity or source")
        }
        autoreleasepool {
            var record: [String: Any] = ["id": id, "sourceSha256": sourceSHA,
                                          "backend": "Metal", "status": "fail",
                                          "hostTextures": [], "hostVolumes": [],
                                          "nativeCpuEffects": [], "runtimeEnvironment": runtimeEnvironment]
            defer { records.append(record) }
            do {
            guard !id.hasPrefix("/"), id.split(separator: "/").allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            }) else { throw GraphDiagnostic.invalid("unsafe corpus case id \(id)") }
            guard digest(Data(source.utf8)) == sourceSHA else {
                throw GraphDiagnostic.invalid("corpus source SHA differs for \(id)")
            }
            guard let assets = item["assets"] as? [[String: Any]] else {
                throw GraphDiagnostic.invalid("case \(id) assets")
            }
            for asset in assets {
                guard let text = asset["text"] as? String,
                      let expected = asset["sha256"] as? String,
                      digest(Data(text.utf8)) == expected else {
                    throw GraphDiagnostic.invalid("case \(id) asset SHA differs")
                }
            }
            var goldenAdmission: GoldenAdmission?
            if !compileOnly {
                guard let captureRaw = item["capture"] as? [String: Any] else {
                    throw GraphDiagnostic.invalid("case \(id) capture")
                }
                goldenAdmission = try verifyGoldenAdmission(goldenCases, caseID: id,
                    sourceSHA: sourceSHA, capture: captureRaw, assets: assets)
                if let goldenAdmission {
                    record["capabilityProfile"] = ["maxTextureDimension2D":
                        goldenAdmission.maximumTextureDimension2D]
                }
            }
            var registry = baseRegistry
            let portable = assets.filter { ($0["path"] as? String)?.hasSuffix(".portable.json") == true }
            if portable.count == 1 {
                guard let definition = portable[0]["text"] as? String,
                      assets.allSatisfy({ asset in
                          guard let path = asset["path"] as? String else { return false }
                          return path.hasSuffix(".portable.json") || path.hasSuffix(".wgsl")
                      }) else {
                    throw GraphDiagnostic.unsupported("case \(id) mixed Portable and external assets")
                }
                var shaders: [(String, String)] = []
                var seenPrograms = Set<String>()
                for asset in assets where (asset["path"] as? String)?.hasSuffix(".wgsl") == true {
                    guard let path = asset["path"] as? String,
                          let text = asset["text"] as? String else {
                        throw GraphDiagnostic.invalid("case \(id) malformed WGSL asset")
                    }
                    let parts = URL(fileURLWithPath: path).lastPathComponent.split(separator: ".")
                    guard parts.count >= 3, let program = parts.dropLast().last,
                          seenPrograms.insert(String(program)).inserted else {
                        throw GraphDiagnostic.invalid("case \(id) duplicate or unnamed WGSL asset")
                    }
                    shaders.append((String(program), text))
                }
                try registry.registerPortable(definitionJSON: Data(definition.utf8),
                    orderedShaderSources: shaders)
            } else if !assets.isEmpty && !compileOnly &&
                      !assets.allSatisfy({ asset in
                          guard let path = asset["path"] as? String else { return false }
                          let audio = (item["capture"] as? [String: Any])?["audioInput"]
                              as? [String: Any]
                          return path.hasSuffix(".obj") || path.hasSuffix(".midi.json") ||
                              path == (audio?["assetPath"] as? String)
                      }) {
                throw GraphDiagnostic.unsupported("case \(id) external input assets require native input support")
            } else if portable.count > 1 {
                throw GraphDiagnostic.invalid("case \(id) duplicate Portable definitions")
            }
            let compiler = NoisemakerCompiler(registry: registry)
            // The source demo applies ProgramState controls before its first
            // rendered frame. Keep the compile-only stage path source-exact.
            var graph: RenderGraph
            if compileOnly {
                graph = try compiler.compile(source: source)
            } else {
                graph = try compiler.compileForHost(source: source)
            }
            var seen = Set<String>(), effects: [String] = []
            for pass in graph.passes {
                if let key = pass.raw.field("effectKey")?.stringValue,
                   seen.insert(key).inserted { effects.append(key) }
            }
            record["effects"] = effects
            if compileOnly {
                record["stage"] = "graph"
                record["status"] = "ok"
                return
            }
            guard let captureRaw = item["capture"] as? [String: Any] else {
                throw GraphDiagnostic.invalid("case \(id) capture")
            }
            if let captureSHA = captureRaw["dslSha256"] as? String,
               captureSHA != sourceSHA {
                throw GraphDiagnostic.invalid("case \(id) capture DSL SHA differs")
            }
            let capture = try CorpusCapture(captureRaw)
            let (audioSnapshot, audioEvidence, plainArrayAudio) = try loadAudioInput(
                capture: captureRaw, assets: assets)
            if let audioEvidence { record["hostAudio"] = audioEvidence }
            let audioHostUniforms = try corpusAudioUniforms(
                graph: graph, snapshot: audioSnapshot, plainArray: plainArrayAudio)
            guard let device, let queue = device.makeCommandQueue(),
                  let vertexWGSL, let vertexEntry else {
                throw GraphDiagnostic.missing("Metal corpus command queue")
            }
            let nativeMeshTextures = try prepareMeshes(graph: graph, assets: assets,
                device: device)
            let midiAssets = assets.filter {
                ($0["path"] as? String)?.hasSuffix(".midi.json") == true
            }
            guard midiAssets.count <= 1 else {
                throw GraphDiagnostic.invalid("case \(id) has duplicate MIDI sidecars")
            }
            let midiSnapshot: MIDIInputSnapshot?
            if let midi = midiAssets.first {
                guard graph.externalTextureNames.contains("midiNoteGrid"),
                      let text = midi["text"] as? String,
                      let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      Set(object.keys) == ["messages"],
                      let messages = object["messages"] as? [[Int]] else {
                    throw GraphDiagnostic.invalid("case \(id) MIDI sidecar has no grid consumer or valid messages")
                }
                midiSnapshot = try MIDIGrid.snapshot(messages: messages)
            } else {
                midiSnapshot = nil
            }
            let volumeName = (captureRaw["volumeInput"] as? [String: Any])?["id"] as? String
            let volumeRequired = graph.textures.filter { texture in
                texture.is3D && texture.key == volumeName && graph.passes.contains { pass in
                    pass.inputs.contains { $0.value.stringValue == texture.key }
                }
            }.map(\.key)
            let hostRequired = graph.externalTextureNames.filter {
                nativeMeshTextures[$0] == nil && $0 != "midiNoteGrid" &&
                    !volumeRequired.contains($0)
            }
            let nativeOverlays = try BuiltinOverlay.prepare(graph: graph, size: capture.size)
            let (replayedTextures, hostEvidence) = try loadHostTextures(
                goldens: goldenCases, caseID: id, sourceSHA: sourceSHA,
                capture: captureRaw, required: hostRequired,
                device: device, sourceFailed: goldenAdmission?.sourceFailed == true,
                nativeOverlays: nativeOverlays)
            let (hostVolumes, volumeEvidence) = try loadHostVolume(
                corpusURL: corpusURL, goldens: goldenCases, caseID: id,
                capture: captureRaw, required: volumeRequired, device: device)
            // The source host publishes media dimensions with ProgramState.setValue
            // before frame one; the compiled graph still carries 1024x1024.
            for media in graph.mediaSteps where media.effect == "synth.media" {
                guard let texture = replayedTextures[media.textureId] else {
                    throw GraphDiagnostic.missing("case \(id) media texture \(media.textureId)")
                }
                graph = try graph.updatedParameter(stepIndex: media.stepIndex,
                    name: "imageSize", value: .array([
                        .number(Double(texture.width)), .number(Double(texture.height))
                    ]), registry: compiler.registry)
            }
            let maximumTextureDimension2D = goldenAdmission?.maximumTextureDimension2D
            let renderer = try NoisemakerRenderer(device: device, graph: graph,
                size: capture.size, defaultVertexWGSL: vertexWGSL,
                vertexEntryPoint: vertexEntry, registry: compiler.registry,
                maximumTextureDimension2D: maximumTextureDimension2D)
            record["capabilityProfile"] = ["maxTextureDimension2D": renderer.maximumTextureDimension2D]
            var externalTextures = nativeMeshTextures
            externalTextures.merge(replayedTextures) { _, replayed in replayed }
            externalTextures.merge(hostVolumes) { _, volume in volume }
            record["hostTextures"] = hostEvidence
            record["hostVolumes"] = volumeEvidence
            if !hostEvidence.isEmpty {
                record["hostInputMode"] = nativeOverlays.isEmpty ? "referenceReplay"
                    : (nativeOverlays.count == hostEvidence.count ? "nativeCpuOverlay" : "mixed")
            }
            record["nativeCpuEffects"] = effects.filter {
                ["filter.fibers", "filter.scratches", "filter.strayHair"].contains($0)
            }
            if !volumeEvidence.isEmpty { record["hostInputMode"] = "sourceAuthoredVolume" }
            if !nativeMeshTextures.isEmpty,
               effects.contains("render.meshLoader") {
                record["nativeCpuEffects"] = (record["nativeCpuEffects"] as? [String] ?? []) + ["render.meshLoader"]
            }
            var images: [[String: Any]] = []
            var effectiveAudioHashes = Set<String>()
            for index in 0..<capture.frameCount {
                let frame = index + 1
                if let png = try renderFrame(renderer, queue: queue,
                    frame: capture.state(at: index,
                        inputs: AutomationInputs(audio: audioSnapshot, midi: midiSnapshot),
                        hostUniforms: audioHostUniforms),
                    capture: capture.sampledFrames.contains(frame),
                    externalTextures: externalTextures,
                    onEncoded: { lease in
                        for data in lease.audioBindingData {
                            effectiveAudioHashes.insert(digest(data))
                        }
                    }) {
                    let relative = "\(id).frame\(frame).png"
                    let destination = outputDirectory.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try png.write(to: destination, options: .atomic)
                    images.append(["frame": frame, "path": relative, "sha256": digest(png)])
                }
            }
            if audioSnapshot != nil {
                guard effectiveAudioHashes.count == 1,
                      let hash = effectiveAudioHashes.first else {
                    throw GraphDiagnostic.invalid("audio binding was absent or changed across frames")
                }
                record["audioBindingEffectiveSha256"] = hash
            }
            guard Set(images.compactMap { $0["frame"] as? Int }) == capture.sampledFrames,
                  images.count == capture.sampledFrames.count else {
                throw GraphDiagnostic.invalid("case \(id) did not capture every scheduled frame")
            }
            record["status"] = "ok"
            record["images"] = images
            } catch {
                record["error"] = String(describing: error)
                if let incomplete = error as? CompilerIncomplete { record["stage"] = incomplete.stage }
                else if error is LexerError { record["stage"] = "lex" }
                else if error is ParserError || error is ParserIncomplete { record["stage"] = "parse" }
                else if error is GraphDiagnostic { record["stage"] = "graph" }
            }
        }
        if compileOnly {
            if records.count % 250 == 0 {
                try writeCorpusLedger(records: records, corpusData: corpusData,
                    selectedCount: selected.count, outputDirectory: outputDirectory,
                    compileOnly: compileOnly)
                print("compiled \(records.count)/\(selected.count)")
            }
        } else {
            // A large sweep must retain every completed case even if a later
            // render fails or the process is interrupted.
            try writeCorpusLedger(records: records, corpusData: corpusData,
                selectedCount: selected.count, outputDirectory: outputDirectory,
                compileOnly: compileOnly)
            print("candidate \(id): \(records.last?["status"] ?? "fail")")
        }
    }
    try writeCorpusLedger(records: records, corpusData: corpusData,
        selectedCount: selected.count, outputDirectory: outputDirectory,
        compileOnly: compileOnly)
    print("candidates \(records.count) written to \(outputDirectory.path)")
}

private func writeCorpusLedger(records: [[String: Any]], corpusData: Data,
                               selectedCount: Int, outputDirectory: URL,
                               compileOnly: Bool) throws {
    var ledger: [String: Any] = ["schemaVersion": 1,
        "corpusSha256": digest(corpusData), "expected": selectedCount,
        "compileOnly": compileOnly, "cases": records]
    if let path = ProcessInfo.processInfo.environment["NM_QUALIFICATION_FINGERPRINT"] {
        ledger["qualificationFingerprintSha256"] = digest(try Data(contentsOf: URL(fileURLWithPath: path)))
    }
    let data = try JSONSerialization.data(withJSONObject: ledger,
        options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outputDirectory.appendingPathComponent("candidates.json"), options: .atomic)
}
