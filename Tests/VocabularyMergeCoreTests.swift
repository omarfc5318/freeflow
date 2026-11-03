import Foundation

enum VocabularyMergeCoreTests {
    static func run() {
        testUntouchedBufferKeepsCurrent()
        testEditedBufferKeepsLearnedWords()
        testEditedBufferStillHonorsDeletions()
        testLearnedWordAlreadyTypedIsNotDuplicated()
        testEmptiedBufferKeepsOnlyLearnedWords()
        testEditWithoutLearningWritesBuffer()
    }

    private static func testUntouchedBufferKeepsCurrent() {
        let result = VocabularyMergeCore.commit(buffer: "Alpha, Beta", base: "Alpha, Beta", current: "Alpha, Beta,\nSupabase")
        TestSupport.expectEqual(result, "Alpha, Beta,\nSupabase")
    }

    private static func testEditedBufferKeepsLearnedWords() {
        let result = VocabularyMergeCore.commit(buffer: "Alpha, Beta, Gamma", base: "Alpha, Beta", current: "Alpha, Beta,\nSupabase")
        TestSupport.expectEqual(VocabularyMergeCore.entries(in: result), ["Alpha", "Beta", "Gamma", "Supabase"])
    }

    private static func testEditedBufferStillHonorsDeletions() {
        let result = VocabularyMergeCore.commit(buffer: "Alpha", base: "Alpha, Beta", current: "Alpha, Beta,\nSupabase")
        TestSupport.expectEqual(VocabularyMergeCore.entries(in: result), ["Alpha", "Supabase"])
    }

    private static func testLearnedWordAlreadyTypedIsNotDuplicated() {
        let result = VocabularyMergeCore.commit(buffer: "Alpha, supabase", base: "Alpha", current: "Alpha,\nSupabase")
        TestSupport.expectEqual(VocabularyMergeCore.entries(in: result), ["Alpha", "supabase"])
    }

    private static func testEmptiedBufferKeepsOnlyLearnedWords() {
        let result = VocabularyMergeCore.commit(buffer: "", base: "Alpha", current: "Alpha,\nSupabase")
        TestSupport.expectEqual(result, "Supabase")
    }

    private static func testEditWithoutLearningWritesBuffer() {
        let result = VocabularyMergeCore.commit(buffer: "Alpha, Delta\n", base: "Alpha", current: "Alpha")
        TestSupport.expectEqual(result, "Alpha, Delta")
    }
}
