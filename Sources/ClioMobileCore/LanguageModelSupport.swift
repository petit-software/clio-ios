import Foundation
#if canImport(Metal)
import Metal
#endif
#if os(iOS)
import os
#endif

/// Whether this device can run a downloaded language model, answered from
/// what the device has rather than what it is called: a GPU of a family
/// MLX's kernels need, and enough memory left to this process for the
/// weights and their working room. A phone is a phone by its chip and its
/// memory, not by the word Pro.
public enum LanguageModelSupport {

    public enum Verdict: Equatable, Sendable {
        case supported
        case unsupported(reason: String)

        public var isSupported: Bool { self == .supported }

        public var reason: String? {
            if case .unsupported(let reason) = self { return reason }
            return nil
        }
    }

    /// The device, without regard to any model. MLX runs its kernels on
    /// Metal and wants the Apple7 GPU family — the A14 and later, the M1
    /// and later. There is no Metal of that kind on the simulator.
    public static func device() -> Verdict {
        #if targetEnvironment(simulator)
        return .unsupported(reason: "Downloaded models do not run on the simulator.")
        #elseif canImport(Metal)
        guard let gpu = MTLCreateSystemDefaultDevice() else {
            return .unsupported(reason: "This device has no GPU a downloaded model can run on.")
        }
        guard gpu.supportsFamily(.apple7) else {
            return .unsupported(reason: "This phone's chip is too old to run a downloaded model.")
        }
        return .supported
        #else
        return .unsupported(reason: "Downloaded models need Metal.")
        #endif
    }

    /// How much more memory this process may take right now. iOS answers
    /// exactly, against the limit it will kill the app at; on a Mac the
    /// machine's memory stands in.
    public static func availableMemory() -> Int64 {
        #if os(iOS)
        return Int64(os_proc_available_memory())
        #else
        return Int64(ProcessInfo.processInfo.physicalMemory)
        #endif
    }

    /// Whether a model's estimated footprint fits in what is available.
    public static func fits(_ model: CatalogModel,
                            available: Int64 = availableMemory()) -> Verdict {
        guard let needed = model.memoryBytes else { return .supported }
        guard available >= needed else {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .memory
            return .unsupported(
                reason: "\(model.displayName) needs about \(formatter.string(fromByteCount: needed)) "
                    + "of free memory; this phone has \(formatter.string(fromByteCount: available)) right now.")
        }
        return .supported
    }

    /// Both questions, the device's first.
    public static func verdict(for model: CatalogModel) -> Verdict {
        if case .unsupported = device() { return device() }
        return fits(model)
    }
}
