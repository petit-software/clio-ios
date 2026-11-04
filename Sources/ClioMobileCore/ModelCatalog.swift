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
    /// About how much memory the model takes to run — weights, cache and
    /// working room — for a language model, so a phone that cannot hold it
    /// is told so before the download rather than by being killed after.
    /// Nil for a Whisper model, which Core ML pages as it likes.
    public var memoryBytes: Int64?

    public init(id: String, displayName: String, repo: String,
                tokenizerRepo: String? = nil,
                approximateBytes: Int64, tier: QualityTier,
                languages: ModelLanguages, note: String? = nil,
                memoryBytes: Int64? = nil) {
        self.id = id
        self.displayName = displayName
        self.repo = repo
        self.tokenizerRepo = tokenizerRepo
        self.approximateBytes = approximateBytes
        self.tier = tier
        self.languages = languages
        self.note = note
        self.memoryBytes = memoryBytes
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

/// The language models offered for titles and summaries on a phone without
/// Apple Intelligence — or by choice on one with it. MLX models from the
/// mlx-community repos on Hugging Face: 4-bit weights, config and tokenizer
/// at the root of each repo, loaded and run on the GPU by `MLXSummaryEngine`.
///
/// Two, deliberately: a small one that fits a phone with 4 GB and stays
/// close to the transcript, and the one to start with. Gemma 3 1B was
/// tried and dropped — it invented a currency, added headings it was told
/// not to and answered Dutch in English; see docs/plan.md, milestone 7.
/// Sizes are the repos' own, measured. The memory figures are the GPU's
/// peak on a Mac for a standard summary, rounded up with room for the rest
/// of the process; the figure that matters is read on a phone, see
/// AGENTS.md. Both are Apache 2.0.
public enum LanguageModelCatalog {
    public static let builtIn: [CatalogModel] = [
        CatalogModel(
            id: "Qwen3-0.6B-4bit",
            displayName: "Qwen3 0.6B",
            repo: "mlx-community/Qwen3-0.6B-4bit",
            approximateBytes: 351_000_000,
            tier: .fast,
            languages: .multilingual,
            note: "Smallest; fits a phone with 4 GB. Stays close to the words said, summarizes little. Apache 2.0.",
            memoryBytes: 1_200_000_000),
        CatalogModel(
            id: "Qwen3-1.7B-4bit",
            displayName: "Qwen3 1.7B",
            repo: "mlx-community/Qwen3-1.7B-4bit",
            approximateBytes: 984_000_000,
            tier: .balanced,
            languages: .multilingual,
            note: "The one to start with. Real summaries, English and Dutch. Apache 2.0.",
            memoryBytes: 2_300_000_000),
    ]

    public static let defaultModelID = "Qwen3-1.7B-4bit"
}
