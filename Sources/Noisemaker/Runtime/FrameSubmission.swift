import Foundation
import Metal

public enum RenderSubmissionError: Error, Equatable, CustomStringConvertible {
    case capacityExceeded
    case uncommittedFrame
    case differentCommandQueue

    public var description: String {
        switch self {
        case .capacityExceeded: return "All three frame submission slots are in flight"
        case .uncommittedFrame: return "Commit or discard the previous frame before encoding another"
        case .differentCommandQueue: return "A renderer must use one command queue for ordered GPU execution"
        }
    }
}

/// An already-committed frame. Keep its output lease until downstream GPU use completes.
/// Reading a texture on the CPU requires successful command-buffer completion.
public final class FrameSubmission {
    public let output: OutputLease
    public let commandBuffer: MTLCommandBuffer
    init(output: OutputLease, commandBuffer: MTLCommandBuffer) {
        self.output = output
        self.commandBuffer = commandBuffer
    }
}

extension NoisemakerRenderer {
    /// Submit without waiting. Three incomplete submissions exhaust capacity;
    /// retry after a completion rather than blocking the application's frame loop.
    public func render(frame: FrameState = .zero) throws -> FrameSubmission {
        try frameCoordinator.reserveSubmission()
        do {
            let queue = try frameCoordinator.submissionQueue(device: device)
            guard let command = queue.makeCommandBuffer() else {
                throw GraphDiagnostic.missing("Metal frame command buffer")
            }
            let output: OutputLease
            do { output = try encode(frame: frame, into: command) }
            catch {
                frameCoordinator.discard(command)
                throw error
            }
            let coordinator = frameCoordinator
            command.addCompletedHandler { _ in coordinator.releaseSubmission() }
            command.commit()
            return FrameSubmission(output: output, commandBuffer: command)
        } catch {
            frameCoordinator.releaseSubmission()
            throw error
        }
    }
}

// NoisemakerRenderer is confined to the caller's serial executor. This small
// state object is additionally locked because Metal invokes completion handlers
// on its own threads. Resource objects are retained, never mutated by callbacks.
final class FrameCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: MTLCommandQueue?
    private weak var previousCommand: MTLCommandBuffer?
    private var inFlight = 0

    func beginEncode(_ command: MTLCommandBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        if let queue, queue !== command.commandQueue { throw RenderSubmissionError.differentCommandQueue }
        if let previousCommand, previousCommand.status == .notEnqueued || previousCommand.status == .enqueued {
            throw RenderSubmissionError.uncommittedFrame
        }
        queue = command.commandQueue
        previousCommand = command
    }

    func discard(_ command: MTLCommandBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if previousCommand === command { previousCommand = nil }
    }

    func submissionQueue(device: MTLDevice) throws -> MTLCommandQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue { return queue }
        guard let created = device.makeCommandQueue() else { throw GraphDiagnostic.missing("Metal frame command queue") }
        queue = created
        return created
    }

    func reserveSubmission() throws {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < 3 else { throw RenderSubmissionError.capacityExceeded }
        inFlight += 1
    }

    func releaseSubmission() {
        lock.lock()
        defer { lock.unlock() }
        inFlight -= 1
    }

    static func keepAlive(_ resources: [AnyObject], through command: MTLCommandBuffer) {
        let retained = RetainedResources(resources)
        command.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
    }
}

private final class RetainedResources: @unchecked Sendable {
    let resources: [AnyObject]
    init(_ resources: [AnyObject]) { self.resources = resources }
}
