// PerformanceView.swift
// ChromaGlow — Round 3 Phase C (the DJ Perform surface)
//
// Full-screen stage: deck A is the live composition (inherited, never
// interrupted), deck B cues the next look, the crossfader blends them at
// the render chokepoint, punch pads overlay momentary hits, and the
// queue promotes-and-advances on every completed fade.
//
// Design rules (spec artifact): no scrolling, thumb-size targets,
// hold-to-engage pads that self-release, honest transport badge, and the
// shared beat panel — never bespoke clock UI.

import SwiftUI
import QuartzCore
import UIKit

// MARK: - PerformanceViewModel

@MainActor
@Observable
final class PerformanceViewModel: Identifiable {

    /// Drives `.fullScreenCover(item:)` in StudioView — presentation must key off
    /// the VM itself, never a separate Bool, or the cover can commit before the
    /// VM lands and present an empty (black) screen.
    nonisolated let id = UUID()

    let mix: PerformanceMixBox
    let room: RoomDisplayItem
    private unowned let orchestrator: UnifiedOrchestrator

    /// Live per-room transport truth — a construction-time snapshot went
    /// stale on mid-set DTLS→REST failover (wrong badge, wrong punch branch).
    var isStreaming: Bool {
        orchestrator.compositionTransportByRoom[room.id] == .entertainment
    }
    /// Saved preset backing the live composition — nil for unsaved looks
    /// (incl. the "+ Create" draft), which gates "Save with composition".
    let presetID: UUID?
    private let compositionStore: CompositionStore?

    var deckAName: String
    var deckBName: String? = nil
    var queue: [CompositionPreset] = []
    var displayCrossfade: Double = 0
    var autoFadeActive = false

    private var pollTask: Task<Void, Never>? = nil

    init(orchestrator: UnifiedOrchestrator,
         room: RoomDisplayItem,
         liveBox: CompositionParamBox,
         liveName: String,
         presetID: UUID? = nil,
         compositionStore: CompositionStore? = nil) {
        self.mix = PerformanceMixBox(deckA: liveBox)
        self.room = room
        self.orchestrator = orchestrator
        self.deckAName = liveName
        self.presetID = presetID
        self.compositionStore = compositionStore
        // R4-7: reopen the preset's saved sequence, if any.
        if let presetID,
           let saved = compositionStore?.presets.first(where: { $0.id == presetID })?.sequence {
            self.sequence = saved
        }
    }

    func begin() {
        orchestrator.activePerformanceMix = mix
        // The Perform surface IS the audio demand: its beat panel advertises
        // "Listening for a beat…", and auto-fade/strobe need a tempo even
        // over a non-reactive composition. Refcounted — a mic-reactive
        // composition keeps capture alive after end() via its own demand.
        Task { await AudioAnalysisEngine.shared.setDemand(.performance, active: true) }
        UIApplication.shared.isIdleTimerDisabled = true
        // 10 Hz poll: mirrors mixer-owned state into observable UI state and
        // runs promote-and-advance when an auto-fade lands.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.displayCrossfade = self.mix.crossfade
                self.autoFadeActive = self.mix.autoFade != nil
                self.promoteIfFadeLanded()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func end() {
        stopSequence()
        pollTask?.cancel()
        pollTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        mix.punch = nil
        mix.autoFade = nil
        mix.masterIntensity = 1.0
        // Whatever is showing keeps playing: if we ended on deck B, promote
        // it into the live box first so the composition doesn't snap back.
        if mix.crossfade >= 0.5, let b = mix.deckB {
            adopt(b, name: deckBName ?? deckAName)
        }
        mix.crossfade = 0
        orchestrator.activePerformanceMix = nil
        Task { await AudioAnalysisEngine.shared.setDemand(.performance, active: false) }
    }

    // ── Decks & queue ──

    func cue(_ preset: CompositionPreset) {
        mix.deckB = CompositionParamBox(preset: preset)
        deckBName = preset.name
    }

    func enqueue(_ preset: CompositionPreset) {
        if mix.deckB == nil {
            cue(preset)
        } else {
            queue.append(preset)
        }
    }

    func setCrossfade(_ value: Double) {
        mix.autoFade = nil           // manual touch always wins
        mix.crossfade = min(1, max(0, value))
        displayCrossfade = mix.crossfade
        promoteIfFadeLanded()
    }

    func autoFade(bars: Int) {
        mix.startAutoFade(bars: bars, beat: BeatClock.snapshot(),
                          hostNow: CACurrentMediaTime())
        HapticManager.shared.selection()
    }

    /// Full-B = deck B becomes the live look: copy its layers into the live
    /// box (identity preserved — the render loop keeps its reference),
    /// reset the fader, and cue the next queued preset.
    private func promoteIfFadeLanded() {
        guard mix.autoFade == nil, mix.crossfade >= 0.999, let b = mix.deckB else { return }
        adopt(b, name: deckBName ?? deckAName)
        mix.crossfade = 0
        displayCrossfade = 0
        if let next = queue.first {
            queue.removeFirst()
            cue(next)
        } else {
            mix.deckB = nil
            deckBName = nil
        }
        HapticManager.shared.medium()
    }

    private func adopt(_ source: CompositionParamBox, name: String) {
        mix.deckA.palette = source.palette
        mix.deckA.motion = source.motion
        mix.deckA.envelope = source.envelope
        mix.deckA.reaction = source.reaction
        deckAName = name
    }

    // ── Step sequencer (Round 3 D — runs on the same mix) ──

    var sequence = CompositionSequence()
    private(set) var sequencePlayer: SequencePlayer? = nil
    var isSequencePlaying: Bool { sequencePlayer?.isPlaying ?? false }
    var currentSequenceStepID: UUID? = nil

    /// A step is a captured look: all four layers inline, self-contained.
    func captureCurrentStep() {
        let a = mix.deckA
        sequence.steps.append(CompositionSequence.Step(
            name: "Step \(sequence.steps.count + 1)",
            palette: a.palette, motion: a.motion,
            envelope: a.envelope, reaction: a.reaction))
        HapticManager.shared.selection()
    }

    func playSequence() {
        guard !sequence.steps.isEmpty else { return }
        mix.autoFade = nil
        let player = sequencePlayer ?? SequencePlayer(mix: mix)
        sequencePlayer = player
        player.start(sequence) { [weak self] step in
            self?.deckAName = step.name
            self?.deckBName = nil
            self?.currentSequenceStepID = step.id
        }
        HapticManager.shared.medium()
    }

    func stopSequence() {
        sequencePlayer?.stop()
        currentSequenceStepID = nil
    }

    /// R4-7: persist the sequence onto its backing preset. No-op when the
    /// live composition is unsaved (presetID nil — save the composition
    /// first from the mixer tray).
    @discardableResult
    func saveSequenceToPreset() -> Bool {
        guard let presetID,
              let store = compositionStore,
              var preset = store.presets.first(where: { $0.id == presetID }) else { return false }
        preset.sequence = sequence.steps.isEmpty ? nil : sequence
        store.save(preset)
        HapticManager.shared.medium()
        return true
    }

    // ── Punch pads ──

    func punchDown(_ pad: PerformanceMixBox.PunchPad) {
        mix.engagePunch(pad)
        HapticManager.shared.medium()
        // REST tier: the mixer overlay only lands at scheduler cadence, so
        // fire the bridge-native burst too — instant, self-terminating.
        // STROBE must alternate two contrasting colors (white↔white was a
        // static flash); BURST is the steady white push, like the overlay.
        if !isStreaming, pad != .blackout {
            let colors: (a: CGPoint, b: CGPoint) = pad == .strobe
                ? (CGPoint(x: 0.3127, y: 0.3290), CGPoint(x: 0.1500, y: 0.0600))
                : (CGPoint(x: 0.3127, y: 0.3290), CGPoint(x: 0.3127, y: 0.3290))
            Task {
                await SignalingService(orchestrator: orchestrator)
                    .punchBurst(room: room, a: colors.a, b: colors.b, durationMs: 1200)
            }
        }
    }

    func punchUp() {
        mix.releasePunch(hostNow: CACurrentMediaTime())
        HapticManager.shared.light()
    }
}

// MARK: - PerformanceView

struct PerformanceView: View {

    let viewModel: PerformanceViewModel
    let presets: [CompositionPreset]
    @Environment(\.dismiss) private var dismiss

    @State private var showQueuePicker = false
    @State private var showSequencer = false
    @State private var heldPad: PerformanceMixBox.PunchPad? = nil

    private let stageBG = Color(red: 0.043, green: 0.043, blue: 0.059)

    var body: some View {
        ZStack {
            stageBG.ignoresSafeArea()
            VStack(spacing: 14) {
                header
                clockCluster
                deckRow
                crossfaderSection
                padGrid
                masterRow
                queueRow
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { viewModel.begin() }
        .onDisappear { viewModel.end() }
        .sheet(isPresented: $showQueuePicker) { queuePicker }
        .sheet(isPresented: $showSequencer) { sequenceEditor }
    }

    // ── Header ──

    private var header: some View {
        HStack(spacing: 8) {
            Text(viewModel.room.name.uppercased())
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
            Text(viewModel.isStreaming ? "⚡ STREAMING" : "🔌 REST")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(viewModel.isStreaming ? HuePalette.Noir.success : .white.opacity(0.6))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.08)))
            Spacer()
            Button {
                showSequencer = true
            } label: {
                Image(systemName: "list.number")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(viewModel.isSequencePlaying
                                     ? Color.black.opacity(0.85) : .white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(viewModel.isSequencePlaying
                                              ? AnyShapeStyle(HuePalette.amber)
                                              : AnyShapeStyle(.white.opacity(0.08))))
            }
            .stageTapTarget(visual: 40)
            .accessibilityLabel("Step sequencer")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .stageTapTarget(visual: 40)
            .accessibilityLabel("Close Perform")
        }
    }

    // ── Clock (the shared beat panel — never bespoke) ──

    private var clockCluster: some View {
        HStack {
            // Transport-only: Perform passes no BeatBinding, so requesting
            // `.global` (which includes `.binding`) advertised a per-effect
            // sync section the panel silently skipped.
            BeatChipButton(capabilities: [.transport, .manualBPM, .barMeter])
            Spacer()
        }
    }

    // ── Decks ──

    private var deckRow: some View {
        HStack(spacing: 10) {
            deckCard(tag: "DECK A · LIVE", name: viewModel.deckAName,
                     active: viewModel.displayCrossfade < 0.5)
            Button {
                showQueuePicker = true
            } label: {
                deckCard(tag: "DECK B · CUED",
                         name: viewModel.deckBName ?? "Tap to cue",
                         active: viewModel.displayCrossfade >= 0.5,
                         dimmed: viewModel.deckBName == nil)
            }
            .buttonStyle(.plain)
        }
    }

    private func deckCard(tag: String, name: String, active: Bool, dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tag)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? HuePalette.amber : .white.opacity(0.4))
                .tracking(1.2)
            Text(name)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(dimmed ? 0.35 : 1))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(active ? HuePalette.amber.opacity(0.55) : .white.opacity(0.1),
                                  lineWidth: active ? 1.5 : 1))
        )
    }

    // ── Crossfader ──

    private var crossfaderSection: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(
                get: { viewModel.displayCrossfade },
                set: { viewModel.setCrossfade($0) }
            ), in: 0...1)
            .tint(HuePalette.amber)
            .disabled(viewModel.deckBName == nil)
            HStack {
                Text("A").font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                ForEach([4, 8, 16], id: \.self) { bars in
                    Button("FADE \(bars)") {
                        viewModel.autoFade(bars: bars)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .buttonStyle(.bordered)
                    .tint(viewModel.autoFadeActive ? HuePalette.amber : .white.opacity(0.5))
                    .disabled(viewModel.deckBName == nil)
                }
                Spacer()
                Text("B").font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
    }

    // ── Punch pads (hold to engage, self-releasing) ──

    private var padGrid: some View {
        HStack(spacing: 10) {
            punchPad(.strobe, icon: "bolt.fill", label: "STROBE")
            punchPad(.blackout, icon: "square.fill", label: "BLACKOUT")
            punchPad(.whiteBurst, icon: "sun.max.fill", label: "BURST")
        }
    }

    private func punchPad(_ pad: PerformanceMixBox.PunchPad, icon: String, label: String) -> some View {
        let isHeld = heldPad == pad
        return VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20))
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
        }
        .foregroundStyle(isHeld ? Color.black.opacity(0.85) : HuePalette.amber)
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isHeld ? HuePalette.amber : HuePalette.amber.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(HuePalette.amber.opacity(0.45), lineWidth: 1))
        )
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard heldPad != pad else { return }
                    heldPad = pad
                    viewModel.punchDown(pad)
                }
                .onEnded { _ in
                    heldPad = nil
                    viewModel.punchUp()
                }
        )
        .accessibilityLabel("\(label) punch pad")
        .accessibilityHint("Hold to engage; releases on lift")
    }

    // ── Master ──

    private var masterRow: some View {
        HStack(spacing: 12) {
            Text("MASTER")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(1.2)
            Slider(value: Binding(
                get: { viewModel.mix.masterIntensity },
                set: { viewModel.mix.masterIntensity = min(1, max(0, $0)) }
            ), in: 0...1)
            .tint(HuePalette.amber)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
    }

    // ── Queue ──

    private var queueRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.queue) { preset in
                    Text(preset.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(.white.opacity(0.07)))
                }
                Button {
                    showQueuePicker = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HuePalette.amber)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(HuePalette.amber.opacity(0.12)))
                }
            }
        }
        .frame(height: 34)
    }

    // ── Step sequencer (Round 3 D) ──

    private var sequenceEditor: some View {
        @Bindable var vm = viewModel
        return NavigationStack {
            List {
                Section {
                    ForEach($vm.sequence.steps) { $step in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.3))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(viewModel.currentSequenceStepID == step.id
                                                     ? HuePalette.amber : .white)
                                Text("\(step.bars) bars · fade \(step.crossfadeBeats)♩")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            Spacer()
                            Menu("\(step.bars) bars") {
                                ForEach([2, 4, 8, 16, 32], id: \.self) { bars in
                                    Button("\(bars) bars") { step.bars = bars }
                                }
                            }
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Menu("XF \(step.crossfadeBeats)♩") {
                                ForEach([0, 2, 4, 8, 16], id: \.self) { beats in
                                    Button(beats == 0 ? "Hard cut" : "\(beats) beats") {
                                        step.crossfadeBeats = beats
                                    }
                                }
                            }
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                    .onMove { vm.sequence.steps.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { vm.sequence.steps.remove(atOffsets: $0) }

                    Button {
                        viewModel.captureCurrentStep()
                    } label: {
                        Label("Capture current look as a step", systemImage: "plus.viewfinder")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HuePalette.amber)
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                } footer: {
                    Text("Steps are self-contained snapshots — the current step plays on deck A, the next cues on deck B, and fades land on the beat grid.")
                }

                Section {
                    Toggle("Loop", isOn: $vm.sequence.loops)
                        .tint(HuePalette.amber)
                        .listRowBackground(Color.white.opacity(0.05))

                    // R4-7: sequences travel with their composition preset.
                    Button {
                        vm.saveSequenceToPreset()
                    } label: {
                        Label("Save with composition", systemImage: "square.and.arrow.down")
                            .foregroundStyle(vm.presetID == nil
                                             ? Color.white.opacity(0.35)
                                             : HuePalette.amber)
                    }
                    .disabled(vm.presetID == nil)
                    .listRowBackground(Color.white.opacity(0.05))
                } footer: {
                    if vm.presetID == nil {
                        Text("Save the composition first — sequences attach to saved compositions.")
                    } else {
                        Text("Saved sequences reopen with this composition's Perform surface.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(stageBG)
            .navigationTitle("Sequence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isSequencePlaying ? "Stop" : "Play") {
                        if viewModel.isSequencePlaying {
                            viewModel.stopSequence()
                        } else {
                            viewModel.playSequence()
                            showSequencer = false
                        }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .disabled(vm.sequence.steps.isEmpty && !viewModel.isSequencePlaying)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var queuePicker: some View {
        NavigationStack {
            List(presets) { preset in
                Button {
                    viewModel.enqueue(preset)
                    showQueuePicker = false
                    HapticManager.shared.selection()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: preset.icon)
                            .foregroundStyle(HuePalette.amber)
                        Text(preset.name).foregroundStyle(.white)
                        Spacer()
                        if viewModel.deckBName == nil {
                            Text("cues to B").font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(stageBG)
            .navigationTitle("Cue a Composition")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
