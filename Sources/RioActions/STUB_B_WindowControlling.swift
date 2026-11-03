import Foundation

// THROWAWAY (builder B): the pinned protocol so the executor compiles. Builder C owns the real
// declaration in WindowControlling.swift; the lead deletes this file at merge.
@MainActor protocol WindowControlling {
    func apply(_ command: WindowCommand) -> RioActionResult
}
