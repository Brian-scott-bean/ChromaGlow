// BuildMetadataTests.swift
// ChromaGlow — IOS-OPS-001A

import XCTest
@testable import HueHome

final class BuildMetadataTests: XCTestCase {

    func testReadsValidVersionAndBuild() {
        let metadata = BuildMetadata(infoDictionary: [
            "CFBundleShortVersionString": "0.9.0",
            "CFBundleVersion": "21",
        ])
        XCTAssertEqual(metadata.marketingVersion, "0.9.0")
        XCTAssertEqual(metadata.buildNumber, "21")
    }

    func testUnknownWhenVersionBuildMissing() {
        let metadata = BuildMetadata(infoDictionary: [:])
        XCTAssertEqual(metadata.marketingVersion, BuildMetadata.unknownValue)
        XCTAssertEqual(metadata.buildNumber, BuildMetadata.unknownValue)
    }

    func testUnknownForEmptyStrings() {
        let metadata = BuildMetadata(infoDictionary: [
            "CFBundleShortVersionString": "",
            "CFBundleVersion": "",
        ])
        XCTAssertEqual(metadata.marketingVersion, BuildMetadata.unknownValue)
        XCTAssertEqual(metadata.buildNumber, BuildMetadata.unknownValue)
    }

    func testUnknownForWhitespaceOnlyStrings() {
        let metadata = BuildMetadata(infoDictionary: [
            "CFBundleShortVersionString": "   ",
            "CFBundleVersion": "\n\t",
        ])
        XCTAssertEqual(metadata.marketingVersion, BuildMetadata.unknownValue)
        XCTAssertEqual(metadata.buildNumber, BuildMetadata.unknownValue)
    }

    func testUnknownForNonStringValues() {
        let metadata = BuildMetadata(infoDictionary: [
            "CFBundleShortVersionString": 42,
            "CFBundleVersion": true,
        ])
        XCTAssertEqual(metadata.marketingVersion, BuildMetadata.unknownValue)
        XCTAssertEqual(metadata.buildNumber, BuildMetadata.unknownValue)
    }

    func testReadsOptionalCommitSHA() {
        let metadata = BuildMetadata(infoDictionary: [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "ChromaGlowGitCommit": "acd5409df4bec75e92fa1ee7597b1ff25794e9d6",
        ])
        XCTAssertEqual(metadata.commitSHA, "acd5409df4bec75e92fa1ee7597b1ff25794e9d6")
    }

    func testShortCommitSHAIsEightCharacters() {
        let metadata = BuildMetadata(infoDictionary: [
            "ChromaGlowGitCommit": "acd5409df4bec75e92fa1ee7597b1ff25794e9d6",
        ])
        XCTAssertEqual(metadata.shortCommitSHA, "acd5409d")
    }

    func testAbsentOptionalGitMetadata() {
        let metadata = BuildMetadata(infoDictionary: [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ])
        XCTAssertNil(metadata.commitSHA)
        XCTAssertNil(metadata.shortCommitSHA)
        XCTAssertNil(metadata.branchName)
        XCTAssertNil(metadata.buildTimestamp)
        XCTAssertNil(metadata.isDirty)
    }

    func testDirtyParsesOne() {
        let metadata = BuildMetadata(infoDictionary: ["ChromaGlowGitDirty": "1"])
        XCTAssertEqual(metadata.isDirty, true)
    }

    func testDirtyParsesTrue() {
        let metadata = BuildMetadata(infoDictionary: ["ChromaGlowGitDirty": "TRUE"])
        XCTAssertEqual(metadata.isDirty, true)
    }

    func testDirtyParsesZeroAsClean() {
        let metadata = BuildMetadata(infoDictionary: ["ChromaGlowGitDirty": "0"])
        XCTAssertEqual(metadata.isDirty, false)
    }

    func testDirtyParsesFalseAsClean() {
        let metadata = BuildMetadata(infoDictionary: ["ChromaGlowGitDirty": "false"])
        XCTAssertEqual(metadata.isDirty, false)
    }

    func testUnknownDirtyStringIsNil() {
        let metadata = BuildMetadata(infoDictionary: ["ChromaGlowGitDirty": "maybe"])
        XCTAssertNil(metadata.isDirty)
    }

    func testShortSHAWithoutCrashingWhenShorterThanEight() {
        let metadata = BuildMetadata(infoDictionary: ["ChromaGlowGitCommit": "abc"])
        XCTAssertEqual(metadata.shortCommitSHA, "abc")
    }
}
