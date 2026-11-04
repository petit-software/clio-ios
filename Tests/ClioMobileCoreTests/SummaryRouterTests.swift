import Foundation
import Testing
@testable import ClioMobileCore

private let transcript = """
    The migration ran clean on staging this morning. Two flaky tests in the \
    payment suite, both timing related, and nobody has looked at the onboarding \
    copy yet, so that is on me for tomorrow before the review.
    """

/// The router in front of Apple's model and a downloaded one: which one a
/// request goes to, and how the stored choice follows what can run.
@Suite("Summary router")
struct SummaryRouterTests {

    @MainActor private var qwen: InstalledModel { ModelManager.simulatedInstalled("Qwen3-0.6B-4bit") }

    @MainActor
    private func make(choice: SummaryModelChoice = .apple,
                      apple: SummaryAvailability = .available,
                      installed: [InstalledModel] = [],
                      device: LanguageModelSupport.Verdict = .supported)
        -> (SummaryRouter, StubSummaryEngine, StubLocalSummaryEngine, SettingsStore) {
        var settings = Settings()
        settings.summaryModel = choice
        let store = SettingsStore.simulating(settings)
        let appleEngine = StubSummaryEngine(availability: apple, latency: .milliseconds(5))
        let local = StubLocalSummaryEngine(deviceSupport: device)
        let router = SummaryRouter(apple: appleEngine, local: local, settings: store,
                                   languageModels: .simulating(installed: installed, layout: .languageModel))
        return (router, appleEngine, local, store)
    }

    @Test("Apple's model by default, with the request passed whole")
    func appleByDefault() async throws {
        let (router, apple, local, _) = await make()
        #expect(await router.availability == .available)
        let request = SummaryRequest(transcript: transcript, language: "en",
                                     preferences: SummaryPreferences(noteType: .meeting))
        _ = try await router.summarize(request)
        #expect(await apple.lastRequest == request)
        #expect(await local.lastRequest == nil)
    }

    @Test("A chosen downloaded model gets the request, and the same preferences")
    @MainActor
    func localByChoice() async throws {
        let qwen = qwen
        let (router, apple, local, _) = make(choice: .local(id: qwen.id), installed: [qwen])
        #expect(await router.availability == .available)
        let request = SummaryRequest(transcript: transcript, language: "nl",
                                     preferences: SummaryPreferences(format: .bullets, length: .brief))
        let summary = try await router.summarize(request)
        #expect(await local.lastRequest == request)
        #expect(await local.lastModel == qwen)
        #expect(await apple.lastRequest == nil)
        #expect(summary.summary.contains("Qwen3 0.6B"))
    }

    @Test("No Apple Intelligence and a model downloaded: the choice moves to the model")
    @MainActor
    func fallsForwardToLocal() async throws {
        let qwen = qwen
        let (router, _, local, store) = make(
            apple: .unavailable(reason: "This phone does not support Apple Intelligence."),
            installed: [qwen])
        #expect(await router.availability == .available)
        _ = try await router.summarize(SummaryRequest(transcript: transcript, language: "en"))
        #expect(await local.lastModel == qwen)
        #expect(store.settings.summaryModel == .local(id: qwen.id))
    }

    @Test("No Apple Intelligence and nothing downloaded: the reason says what to do")
    func nothingToRunOn() async throws {
        let (router, _, _, _) = await make(
            apple: .unavailable(reason: "This phone does not support Apple Intelligence."))
        let availability = await router.availability
        #expect(availability.isAvailable == false)
        #expect(availability.reason?.contains("downloaded model") == true)
        await #expect(throws: SummaryEngineError.self) {
            try await router.summarize(SummaryRequest(transcript: transcript, language: "en"))
        }

        // A device that cannot run one is not told to download one.
        let (old, _, _, _) = await make(
            apple: .unavailable(reason: "This phone does not support Apple Intelligence."),
            device: .unsupported(reason: "This phone's chip is too old to run a downloaded model."))
        #expect(await old.availability.reason?.contains("downloaded model can write") == false)
    }

    @Test("A chosen model that was deleted falls back to Apple's, or to another model")
    @MainActor
    func deletedModelFallsBack() async throws {
        let qwen = qwen
        let (router, apple, _, store) = make(choice: .local(id: "gone"))
        _ = try await router.summarize(SummaryRequest(transcript: transcript, language: "en"))
        #expect(await apple.lastRequest != nil)
        #expect(store.settings.summaryModel == .apple)

        let (other, _, local, store2) = make(
            choice: .local(id: "gone"),
            apple: .unavailable(reason: "Off."), installed: [qwen])
        _ = try await other.summarize(SummaryRequest(transcript: transcript, language: "en"))
        #expect(await local.lastModel == qwen)
        #expect(store2.settings.summaryModel == .local(id: qwen.id))

        let (none, _, _, _) = make(choice: .local(id: "gone"), apple: .unavailable(reason: "Off."))
        #expect(await none.availability.reason?.contains("not downloaded") == true)
    }

    @Test("A model the phone cannot hold is refused with the reason, not loaded")
    @MainActor
    func unsupportedDevice() async throws {
        let qwen = qwen
        let (router, _, local, _) = make(
            choice: .local(id: qwen.id), installed: [qwen],
            device: .unsupported(reason: "Downloaded models do not run on the simulator."))
        let availability = await router.availability
        #expect(availability.reason == "Downloaded models do not run on the simulator.")
        await #expect(throws: SummaryEngineError.self) {
            try await router.summarize(SummaryRequest(transcript: transcript, language: "en"))
        }
        #expect(await local.lastRequest == nil)
    }
}
