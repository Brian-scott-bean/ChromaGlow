// BuildMetadata.swift
// ChromaGlow — IOS-OPS-001A
//
// Pure bundle-backed build identity. Optional Git keys are injected in a later
// build step (IOS-OPS-001B); absent keys must never crash or block UI.

import Foundation

struct BuildMetadata: Equatable {
    static let unknownValue = "Unknown"

    let marketingVersion: String
    let buildNumber: String
    let commitSHA: String?
    let branchName: String?
    let buildTimestamp: String?
    let isDirty: Bool?

    static var current: BuildMetadata {
        BuildMetadata(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        marketingVersion = Self.nonEmptyString(
            infoDictionary["CFBundleShortVersionString"]
        ) ?? Self.unknownValue

        buildNumber = Self.nonEmptyString(
            infoDictionary["CFBundleVersion"]
        ) ?? Self.unknownValue

        commitSHA = Self.nonEmptyString(
            infoDictionary["ChromaGlowGitCommit"]
        )

        branchName = Self.nonEmptyString(
            infoDictionary["ChromaGlowGitBranch"]
        )

        buildTimestamp = Self.nonEmptyString(
            infoDictionary["ChromaGlowBuildTimestamp"]
        )

        if let rawDirty = Self.nonEmptyString(
            infoDictionary["ChromaGlowGitDirty"]
        )?.lowercased() {
            switch rawDirty {
            case "1", "true":
                isDirty = true
            case "0", "false":
                isDirty = false
            default:
                isDirty = nil
            }
        } else {
            isDirty = nil
        }
    }

    var shortCommitSHA: String? {
        guard let commitSHA else { return nil }
        return String(commitSHA.prefix(8))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }

        let trimmed = string.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return trimmed.isEmpty ? nil : trimmed
    }
}
