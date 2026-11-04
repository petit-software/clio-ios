import Foundation

/// Which model writes titles and summaries.
public enum SummaryModelChoice: Codable, Equatable, Hashable, Sendable {
    /// Apple's, through Foundation Models: iOS 26 and Apple Intelligence.
    case apple
    /// A downloaded language model, by its catalog id, run by MLX.
    case local(id: String)
}

/// A downloaded model, run on the phone. What `MLXSummaryEngine` is behind;
/// the core knows the protocol so the router and the tests do not need
/// MLX linked.
public protocol LocalSummaryEngine: AnyObject, Sendable {
    /// Whether this device can run any downloaded model.
    var deviceSupport: LanguageModelSupport.Verdict { get }
    /// Load the model if it is not loaded and write the title and notes
    /// with the shared prompt. `keepLoaded` is Settings' "Keep models in
    /// memory": on, the model stays for the next summary; off, the memory
    /// is given back as soon as the words are in.
    func summarize(_ request: SummaryRequest, using model: InstalledModel,
                   keepLoaded: Bool) async throws -> TranscriptSummary
    func unload() async
}

/// One engine in front of two: Apple's model and a downloaded one. Reads
/// `Settings.summaryModel` on every call, so a change in Settings takes
/// effect on the next summary — and keeps that choice pointing at a model
/// that can run, the way `CaptureController.reconcileActiveModel` does for
/// Whisper: a chosen model that was deleted falls back to Apple's; Apple's
/// being unavailable with a downloaded model installed picks that one.
///
/// Every request reaches whichever engine it is routed to whole, so both
/// build their prompt from the same `SummaryPrompt`.
public final class SummaryRouter: SummaryEngine, @unchecked Sendable {
    public let apple: any SummaryEngine
    public let local: (any LocalSummaryEngine)?
    public let settings: SettingsStore
    public let languageModels: ModelManager

    public init(apple: any SummaryEngine,
                local: (any LocalSummaryEngine)?,
                settings: SettingsStore,
                languageModels: ModelManager) {
        self.apple = apple
        self.local = local
        self.settings = settings
        self.languageModels = languageModels
    }

    enum Route: Equatable {
        case apple
        case local(InstalledModel)
        case none(reason: String)

        var availability: SummaryAvailability {
            if case .none(let reason) = self { return .unavailable(reason: reason) }
            return .available
        }
    }

    /// Apple's answer as of the last check, for the row in Settings that
    /// has no await to make. `.unavailable("Checking…")` until one has run.
    @MainActor public private(set) var appleAvailability: SummaryAvailability = .unavailable(reason: "Checking…")

    public var availability: SummaryAvailability {
        get async {
            let appleAvailability = await apple.availability
            return await resolve(appleAvailability: appleAvailability).availability
        }
    }

    public func summarize(_ request: SummaryRequest) async throws -> TranscriptSummary {
        let appleAvailability = await apple.availability
        switch await resolve(appleAvailability: appleAvailability) {
        case .apple:
            return try await apple.summarize(request)
        case .local(let model):
            guard let local else { throw SummaryEngineError.unavailable(Self.noLocalEngine) }
            let keep = await MainActor.run { settings.settings.keepModelInMemory }
            return try await local.summarize(request, using: model, keepLoaded: keep)
        case .none(let reason):
            throw SummaryEngineError.unavailable(reason)
        }
    }

    static let noLocalEngine = "Downloaded models cannot run in this build."

    /// What a downloaded model needs of this device, if there is an engine
    /// to run one at all.
    public var deviceSupport: LanguageModelSupport.Verdict {
        local?.deviceSupport ?? .unsupported(reason: Self.noLocalEngine)
    }

    /// Whether a catalog model can be used here: the device, then the
    /// memory. For the rows in Settings.
    @MainActor
    public func support(for model: CatalogModel) -> LanguageModelSupport.Verdict {
        if case .unsupported = deviceSupport { return deviceSupport }
        return LanguageModelSupport.fits(model)
    }

    /// The stored choice, checked against what is there, and corrected
    /// when it points at nothing that can run.
    @MainActor
    func resolve(appleAvailability: SummaryAvailability) -> Route {
        self.appleAvailability = appleAvailability
        switch settings.settings.summaryModel {
        case .local(let id):
            if let installed = languageModels.installedModel(id: id) {
                return route(to: installed)
            }
            // Gone: Apple's if it is there, otherwise another downloaded one.
            if appleAvailability.isAvailable {
                settings.settings.summaryModel = .apple
                return .apple
            }
            if let other = firstUsableLocal() {
                settings.settings.summaryModel = .local(id: other.id)
                return route(to: other)
            }
            let name = languageModels.displayName(for: id)
            return .none(reason: "\(name) is not downloaded. Download it in Settings ▸ Models.")

        case .apple:
            if appleAvailability.isAvailable { return .apple }
            if let model = firstUsableLocal() {
                settings.settings.summaryModel = .local(id: model.id)
                return route(to: model)
            }
            let reason = appleAvailability.reason ?? "Apple Intelligence is not available."
            if case .supported = deviceSupport {
                return .none(reason: reason + " A downloaded model can write them instead: Settings ▸ Models.")
            }
            return .none(reason: reason)
        }
    }

    @MainActor
    private func route(to installed: InstalledModel) -> Route {
        if let entry = languageModels.catalog.first(where: { $0.id == installed.id }) {
            if case .unsupported(let reason) = support(for: entry) { return .none(reason: reason) }
        } else if case .unsupported(let reason) = deviceSupport {
            return .none(reason: reason)
        }
        return .local(installed)
    }

    @MainActor
    private func firstUsableLocal() -> InstalledModel? {
        languageModels.installed.first { installed in
            guard let entry = languageModels.catalog.first(where: { $0.id == installed.id }) else {
                return deviceSupport.isSupported
            }
            return support(for: entry).isSupported
        }
    }
}

/// Stands in for MLX in tests and previews: records what it was asked and
/// answers like the stub summary engine does, naming the model.
public actor StubLocalSummaryEngine: LocalSummaryEngine {
    public nonisolated let deviceSupport: LanguageModelSupport.Verdict
    private let failure: Error?
    public private(set) var lastRequest: SummaryRequest?
    public private(set) var lastModel: InstalledModel?
    public private(set) var lastKeepLoaded: Bool?
    public private(set) var unloadCount = 0

    public init(deviceSupport: LanguageModelSupport.Verdict = .supported, failure: Error? = nil) {
        self.deviceSupport = deviceSupport
        self.failure = failure
    }

    public func summarize(_ request: SummaryRequest, using model: InstalledModel,
                          keepLoaded: Bool) async throws -> TranscriptSummary {
        lastRequest = request
        lastModel = model
        lastKeepLoaded = keepLoaded
        if let failure { throw failure }
        let words = request.transcript.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return TranscriptSummary(
            title: "[Stub] " + words.prefix(3).joined(separator: " "),
            summary: "[Clio stub] \(words.count) words summarised by \(model.displayName).")
    }

    public func unload() async { unloadCount += 1 }
}
