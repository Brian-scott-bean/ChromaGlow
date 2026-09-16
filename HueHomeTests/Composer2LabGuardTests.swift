// Composer2LabGuardTests.swift
// ChromaGlow — Composer 2 lab. Source-shape guards: the experiment stays
// inside its folders, never trips the Phase-1 vocabulary guards, never
// reads a clock or the system random source in its core, keeps protocol
// words out of the user's sight, and is fully registered in the project.

import XCTest
@testable import HueHome

final class Composer2LabGuardTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(under relative: String) throws -> [URL] {
        let root = repoRoot.appendingPathComponent(relative)
        let e = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [URL] = []
        for case let url as URL in e where url.pathExtension == "swift" { files.append(url) }
        XCTAssertFalse(files.isEmpty, "no sources under \(relative) — an empty scan proves nothing")
        return files.sorted { $0.path < $1.path }
    }

    private func source(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private var composer2Dirs: [String] { ["HueHome/Core/Composer2", "HueHome/UI/Composer2"] }

    func testNoPhaseOneVocabularyInTheLab() throws {
        let forbidden = ["Composer2BridgeIdentity", "Composer2GroupIdentity", "Composer2GroupScope",
                         "Composer2ConfigurationIdentity", "Composer2Producer", "Composer2Transport",
                         "Composer2Counter", "Composer2SessionIdentity", "Composer2Contention",
                         "Composer2Resolution", "Composer2StopScope", "Composer2Registration",
                         "Composer2RESTLightIdentity", "Composer2ConsumerTarget", "Composer2ConsumerTransportState",
                         "Composer2IntentRequest", "Composer2StopRequest", "Composer2ConsumerRequest",
                         "Composer2Evidence", "Composer2ObservedState", "Composer2Resolver", "Composer2Flag",
                         "Flag" + "Store"]
        var scanned = 0
        for dir in composer2Dirs {
            for file in try swiftFiles(under: dir) {
                scanned += 1
                let text = try source(file)
                for token in forbidden where text.contains(token) {
                    XCTFail("\(file.lastPathComponent) names the Phase-1 vocabulary \(token)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 30)
    }

    func testCoreUsesNoClocksOrSystemRandom() throws {
        // `Date()` is a clock read; `Date(timeIntervalSince1970:)` is a constant.
        let forbidden = ["Date()", "Date.now", "CACurrentMediaTime", "SystemRandomNumberGenerator", ".random(",
                         "Hasher(", "hashValue", "DispatchTime", "ProcessInfo"]
        for file in try swiftFiles(under: "HueHome/Core/Composer2") where file.lastPathComponent != "Composer2Store.swift" {
            let text = try source(file)
            for token in forbidden where text.contains(token) {
                XCTFail("\(file.lastPathComponent) uses \(token) — the engine must be a pure function of its inputs")
            }
        }
    }

    func testEveryLabFileIsRegisteredInTheProject() throws {
        let pbx = try source(repoRoot.appendingPathComponent("HueHome.xcodeproj/project.pbxproj"))
        var checked = 0
        for dir in composer2Dirs {
            for file in try swiftFiles(under: dir) {
                checked += 1
                XCTAssertTrue(pbx.contains("/* \(file.lastPathComponent) in Sources */"),
                              "\(file.lastPathComponent) is not compiled — run add_composer2_files.rb")
            }
        }
        for file in try swiftFiles(under: "HueHomeTests") where file.lastPathComponent.hasPrefix("Composer2Lab") {
            checked += 1
            XCTAssertTrue(pbx.contains("/* \(file.lastPathComponent) in Sources */"),
                          "\(file.lastPathComponent) is not a test-target member — it would never run")
        }
        XCTAssertGreaterThan(checked, 40)
    }

    func testNoProtocolWordsInLabUserFacingStrings() throws {
        let banned = ["REST", "DTLS", "mirek", "channel", "Channel", "gamut", "Gamut", "\"Onset\""]
        for file in try swiftFiles(under: "HueHome/UI/Composer2") {
            let text = try source(file)
            for (n, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                guard line.contains("\"") else { continue }
                for match in line.matches(of: /"[^"\\]*"/) {
                    let literal = String(match.output)
                    for word in banned where literal.contains(word) {
                        XCTFail("\(file.lastPathComponent):\(n + 1) user-facing literal \(literal) contains \(word)")
                    }
                }
            }
        }
    }

    func testNoBarePrintInTheLab() throws {
        for dir in composer2Dirs {
            for file in try swiftFiles(under: dir) {
                let text = try source(file)
                for (n, line) in text.components(separatedBy: .newlines).enumerated()
                where line.contains("print(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    XCTFail("\(file.lastPathComponent):\(n + 1) prints to the console")
                }
            }
        }
    }

    func testNoTakeoverQuestionsAskedByTheLab() throws {
        let unattended = ["foreignTakeoverPreflight(", "resolveForeignTakeover(", "resolveStudioHandoff(",
                          "entertainmentActivity(onBridge:", "studioStopHandler", "activeEffectEntries"]
        // The Now Playing registry is reached only through the gateway adapter.
        let registryOnlyInGateway = ["addActiveEffect(", "removeActiveEffect(", "composer2StopHandler"]
        for dir in composer2Dirs {
            for file in try swiftFiles(under: dir) {
                let text = try source(file)
                if file.lastPathComponent != "Composer2LiveGateway.swift" {
                    for token in registryOnlyInGateway {
                        XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) reaches the registry directly: \(token)")
                    }
                }
                for token in unattended where text.contains(token) {
                    XCTFail("\(file.lastPathComponent) reaches into \(token)")
                }
            }
        }
    }

    func testHooksInExistingFilesAreExactlyAsDesigned() throws {
        let engine = try source(repoRoot.appendingPathComponent("HueHome/UI/Studio/CompositionEngine.swift"))
        XCTAssertTrue(engine.contains("protocol CompositionFrameSource: AnyObject"))
        XCTAssertTrue(engine.contains("@ObservationIgnored var frameSource: (any CompositionFrameSource)? = nil"))
        XCTAssertEqual(engine.components(separatedBy: "params.frameSource").count - 1, 1, "render consults the source exactly once")

        let audio = try source(repoRoot.appendingPathComponent("HueHome/Core/Audio/AudioAnalysisEngine.swift"))
        XCTAssertTrue(audio.contains("case composer2Preview"))

        let studio = try source(repoRoot.appendingPathComponent("HueHome/UI/Studio/StudioView.swift"))
        let mounts = studio.components(separatedBy: "Composer2EntryCard(").count - 1
        XCTAssertEqual(mounts, 1, "Studio mounts the entry card exactly once")
        let bodyStart = try XCTUnwrap(studio.range(of: "var body: some View {"))
        let gridStart = try XCTUnwrap(studio.range(of: "private func composerGrid(deckIndex: Int)"))
        let mount = try XCTUnwrap(studio.range(of: "Composer2EntryCard("))
        XCTAssertTrue(mount.lowerBound > gridStart.lowerBound, "the card lives in composerGrid, outside body")
        XCTAssertTrue(gridStart.lowerBound > bodyStart.lowerBound)
    }

    func testTheLabAddsNothingElseToExistingSources() throws {
        // The only pre-existing production files the experiment may touch.
        let allowed: Set<String> = ["CompositionEngine.swift", "AudioAnalysisEngine.swift", "StudioView.swift",
                                    "UnifiedOrchestrator.swift"]
        for dir in ["HueHome/Core", "HueHome/UI"] {
            for file in try swiftFiles(under: dir) where !file.path.contains("/Composer2/") {
                let text = try source(file)
                if text.contains("Composer2Lab") || text.contains("Composer2Document") || text.contains("Composer2LiveOutput") {
                    XCTAssertTrue(allowed.contains(file.lastPathComponent), "\(file.lastPathComponent) references the lab")
                }
            }
        }
    }

    func testThisFileUsesNoTimingWaits() throws {
        let text = try source(URL(fileURLWithPath: #filePath))
        for token in ["Task" + ".sleep", "XCT" + "Waiter", "wait(" + "for:"] {
            XCTAssertFalse(text.contains(token), "guard tests never wait on time")
        }
    }
}
