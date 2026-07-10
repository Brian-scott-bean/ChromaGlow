// SequencePlayer.swift
// ChromaGlow — Round 3 Phase D (step sequencer)
//
// Steps, not timelines: a sequence is a reorderable list of captured
// looks (all four layers inline — deleting a source preset can never
// break it), each holding for N bars and crossfading into the next over
// M beats. The player drives the SAME PerformanceMixBox the Perform
// surface owns — current step on deck A, next on deck B, bar-aligned
// fades from the shared clock. No new render machinery.

import Foundation
import QuartzCore

// MARK: - CompositionSequence

struct CompositionSequence: Codable, Equatable {

    struct Step: Codable, Equatable, Identifiable {
        var id = UUID()
        var name = "Step"
        var palette = PaletteConfig()
        var motion = MotionConfig()
        var envelope = EnvelopeConfig()
        var reaction = ReactionConfig()
        var bars = 8                 // hold length
        var crossfadeBeats = 4       // fade into the NEXT step

        enum CodingKeys: String, CodingKey {
            case id, name, palette, motion, envelope, reaction, bars, crossfadeBeats
        }

        init(id: UUID = UUID(), name: String = "Step",
             palette: PaletteConfig = PaletteConfig(),
             motion: MotionConfig = MotionConfig(),
             envelope: EnvelopeConfig = EnvelopeConfig(),
             reaction: ReactionConfig = ReactionConfig(),
             bars: Int = 8, crossfadeBeats: Int = 4) {
            self.id = id
            self.name = name
            self.palette = palette
            self.motion = motion
            self.envelope = envelope
            self.reaction = reaction
            self.bars = max(1, bars)
            self.crossfadeBeats = max(0, crossfadeBeats)
        }

        // M-13 convention: schema drift never drops a step.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
            name = (try? c.decode(String.self, forKey: .name)) ?? "Step"
            palette = (try? c.decode(PaletteConfig.self, forKey: .palette)) ?? PaletteConfig()
            motion = (try? c.decode(MotionConfig.self, forKey: .motion)) ?? MotionConfig()
            envelope = (try? c.decode(EnvelopeConfig.self, forKey: .envelope)) ?? EnvelopeConfig()
            reaction = (try? c.decode(ReactionConfig.self, forKey: .reaction)) ?? ReactionConfig()
            bars = max(1, (try? c.decode(Int.self, forKey: .bars)) ?? 8)
            crossfadeBeats = max(0, (try? c.decode(Int.self, forKey: .crossfadeBeats)) ?? 4)
        }
    }

    var steps: [Step] = []
    var loops = true

    enum CodingKeys: String, CodingKey { case steps, loops }

    init(steps: [Step] = [], loops: Bool = true) {
        self.steps = steps
        self.loops = loops
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = (try? c.decode([Step].self, forKey: .steps)) ?? []
        loops = (try? c.decode(Bool.self, forKey: .loops)) ?? true
    }
}

// MARK: - SequencePlayer

/// Drives an EXISTING PerformanceMixBox (the caller owns the orchestrator
/// seam). Hold → cue next → beat-exact auto-fade → promote → repeat.
@MainActor
@Observable
final class SequencePlayer {

    private let mix: PerformanceMixBox
    private(set) var isPlaying = false
    private(set) var currentStepIndex = 0

    private var task: Task<Void, Never>? = nil

    init(mix: PerformanceMixBox) {
        self.mix = mix
    }

    /// `onPromote` fires on the MainActor whenever a step becomes the live
    /// look (deck names, step highlighting).
    func start(_ sequence: CompositionSequence,
               onPromote: @escaping @MainActor (CompositionSequence.Step) -> Void) {
        stop()
        guard !sequence.steps.isEmpty else { return }
        isPlaying = true
        currentStepIndex = 0
        adopt(sequence.steps[0])
        onPromote(sequence.steps[0])

        task = Task { [weak self] in
            await self?.run(sequence, onPromote: onPromote)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isPlaying = false
        mix.autoFade = nil
        mix.deckB = nil
        mix.crossfade = 0
    }

    private func run(_ sequence: CompositionSequence,
                     onPromote: @escaping @MainActor (CompositionSequence.Step) -> Void) async {
        while !Task.isCancelled {
            let steps = sequence.steps
            guard !steps.isEmpty else { break }
            let step = steps[currentStepIndex % steps.count]

            await sleepBars(step.bars)
            guard !Task.isCancelled else { return }

            let nextIndex = (currentStepIndex + 1) % steps.count
            if nextIndex == 0 && !sequence.loops { break }
            let next = steps[nextIndex]

            // Cue + bar-aligned fade over crossfadeBeats (0 = hard cut).
            mix.deckB = CompositionParamBox(palette: next.palette, motion: next.motion,
                                            envelope: next.envelope, reaction: next.reaction)
            if step.crossfadeBeats > 0 {
                let snap = BeatClock.snapshot()
                mix.startAutoFade(beats: Double(step.crossfadeBeats),
                                  beat: snap,
                                  hostNow: CACurrentMediaTime())
                // Only a render loop clears autoFade (renderMixed). If none is
                // consuming this mix — bridge-stored preset, effect stopped
                // underneath — bound the wait to the fade's own duration plus
                // grace and land it manually, or the sequence hangs forever.
                let expected = snap.bpm > 0
                    ? Double(step.crossfadeBeats) * snap.beatInterval : 0
                let deadline = CACurrentMediaTime() + expected + 2.0
                while !Task.isCancelled, mix.autoFade != nil,
                      CACurrentMediaTime() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { return }
                if let auto = mix.autoFade {
                    mix.crossfade = auto.toValue
                    mix.autoFade = nil
                }
            }

            adopt(next)
            currentStepIndex = nextIndex
            onPromote(next)
        }
        isPlaying = false
    }

    /// Copies the step's layers into the live box (identity preserved —
    /// the render loop keeps its reference) and resets the fader.
    private func adopt(_ step: CompositionSequence.Step) {
        mix.deckA.palette = step.palette
        mix.deckA.motion = step.motion
        mix.deckA.envelope = step.envelope
        mix.deckA.reaction = step.reaction
        mix.crossfade = 0
        mix.deckB = nil
    }

    /// Hold time derives from the clock AT ENTRY (a mid-hold tempo change
    /// lands on the next step; chunked so stop() reacts within 250 ms).
    private func sleepBars(_ bars: Int) async {
        let snap = BeatClock.snapshot()
        let seconds: Double
        if snap.bpm > 0 {
            seconds = Double(bars * max(1, snap.beatsPerBar)) * snap.beatInterval
        } else {
            seconds = Double(bars) * 2.0   // no clock: 120 BPM 4/4 equivalent
        }
        let deadline = CACurrentMediaTime() + seconds
        while !Task.isCancelled, CACurrentMediaTime() < deadline {
            let remaining = deadline - CACurrentMediaTime()
            try? await Task.sleep(for: .milliseconds(Int(min(250, max(10, remaining * 1000)))))
        }
    }
}
