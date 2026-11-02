import Foundation

@main
struct FreeFlowTests {
    static func main() async {
        await AppContextServiceTests.run()
        await ContextCaptureTests.run()
        await LLMAPITransportTests.run()
        TemperatureCapabilityCacheTests.run()
        ModelConfigurationTests.run()
        RecordingCaptureTimingTests.run()
        RecordingTimerPreferenceTests.run()
        OriginalFieldInsertionPreferenceTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        LLMCooldownManagerTests.run()
        PostProcessingServiceTests.run()
        TranscriptionErrorPresentationCoreTests.run()
        TranscriptTextCoreTests.run()
        CorrectionLearningCoreTests.run()
        FeatureCoreTests.run()
        TranscriptionRequestCoreTests.run()
        HandsFreeUndoContextTests.run()
        TeddyBearTests.run()
        TeddyMomentTests.run()
        AppTextInsertionCoreTests.run()
        AppTextInsertionDispatchTests.run()
        await TranscriptionServiceTests.run()
        await APIConfigurationDraftTests.run()
        print("FreeFlowTests passed")
    }
}
