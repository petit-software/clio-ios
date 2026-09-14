import Foundation

public enum QualityTier: String, Codable, Sendable, CaseIterable {
    case fast
    case balanced
    case best

    public var label: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .best: return "Best quality"
        }
    }
}

public enum ModelLanguages: String, Codable, Sendable {
    case english
    case multilingual

    public var label: String {
        switch self {
        case .english: return "English only"
        case .multilingual: return "Multilingual"
        }
    }
}

/// One downloadable model.
///
/// `id` is the folder name inside the Hugging Face repo, which is also the
/// folder name we install it under — one identifier, no mapping table.
public struct CatalogModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var repo: String
    /// The matching `openai/whisper-*` repo, whose tokenizer WhisperKit needs.
    /// The CoreML model folders do not carry one, so we install it alongside —
    /// otherwise the first transcription reaches for the network, which the
    /// whole point of this app is not to do.
    public var tokenizerRepo: String?
    public var approximateBytes: Int64
    public var tier: QualityTier
    public var languages: ModelLanguages
    public var note: String?

    public init(id: String, displayName: String, repo: String,
                tokenizerRepo: String? = nil,
                approximateBytes: Int64, tier: QualityTier,
                languages: ModelLanguages, note: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.repo = repo
        self.tokenizerRepo = tokenizerRepo
        self.approximateBytes = approximateBytes
        self.tier = tier
        self.languages = languages
        self.note = note
    }
}

/// The list of models we offer.
///
/// Copied from the Mac app: same ids, same repo, same Hugging Face layout,
/// so a model that works there works here. Resolution order: a
/// `models.json` in Application Support (a future refresh, or a developer
/// pointing at a different catalog), then the built-in constant. The
/// bundle is not consulted — the Mac app ships a models.json so a CDN
/// refresh has somewhere to land; on the phone the constant is enough
/// until that exists.
public enum ModelCatalog {

    public static func load(
        overrideURL: URL = AppPaths.supportDirectory
            .appendingPathComponent("models.json")
    ) -> [CatalogModel] {
        if let models = decode(contentsOf: overrideURL) { return models }
        return builtIn
    }

    static func decode(contentsOf url: URL) -> [CatalogModel]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CatalogModel].self, from: data)
    }

    /// Sizes are measured from the repo, not copied from a spec. The
    /// quantized variants are what ship: `distil-whisper_distil-large-v3`
    /// unquantized is 1.5 GB, the `_594MB` one is the one anybody means.
    public static let builtIn: [CatalogModel] = [
        CatalogModel(
            id: "openai_whisper-tiny",
            displayName: "Whisper Tiny",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-tiny",
            approximateBytes: 77_000_000,
            tier: .fast,
            languages: .multilingual,
            note: "Smallest download. Good for checking everything works."),
        CatalogModel(
            id: "openai_whisper-small_216MB",
            displayName: "Whisper Small",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-small",
            approximateBytes: 217_000_000,
            tier: .fast,
            languages: .multilingual,
            note: "The one to start with. Quick on any recent iPhone."),
        CatalogModel(
            id: "distil-whisper_distil-large-v3_594MB",
            displayName: "Distil Large v3",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-large-v3",
            approximateBytes: 595_000_000,
            tier: .balanced,
            languages: .english,
            note: "Fast and accurate."),
        CatalogModel(
            id: "openai_whisper-large-v3_turbo_954MB",
            displayName: "Whisper Large v3 Turbo",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-large-v3",
            approximateBytes: 1_053_000_000,
            tier: .best,
            languages: .multilingual,
            note: "Needs a Pro-class phone."),
    ]

    /// Small, not Distil Large as on the Mac: a phone has less memory and
    /// the recordings are as likely to be Dutch as English. Distil Large
    /// is one tap away for anyone who wants it.
    public static let defaultModelID = "openai_whisper-small_216MB"
}
