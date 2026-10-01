// GuestAccessBanner.swift
// ChromaGlow — Family Sharing Phase 3 (guest-side transparency)
//
// A slim glass capsule at the top of Home whenever any live bridge is
// grant-limited. Tapping it opens the detail sheet with the profile
// name(s), what was granted, and the two mandatory truths (design §5):
// enforcement is app-side (the key is bridge-wide by Hue platform
// design), and the only update path is a fresh invite re-scan.

import SwiftUI

struct GuestAccessBanner: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var showDetail = false

    var body: some View {
        if orchestrator.guestAccessInfo.hasAnyGrant {
            Button {
                showDetail = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LuminousPalette.amber)
                    Text(bannerText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LuminousPalette.ink.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Capsule().fill(.ultraThinMaterial))
                .background(Capsule().fill(LuminousPalette.amber.opacity(0.08)))
                .overlay(Capsule().strokeBorder(LuminousPalette.amber.opacity(0.35), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(LuminousPressStyle(scale: 0.98))
            .accessibilityLabel("Guest access details")
            .sheet(isPresented: $showDetail) { detailSheet }
        }
    }

    private var bannerText: String {
        let names = orchestrator.guestAccessInfo.profileNames
        if let first = names.first, names.count == 1 {
            return "Guest access · signed in as \"\(first)\""
        }
        return "Guest access · some rooms are limited"
    }

    // ──────────────────────────────────────────────
    // MARK: - Detail sheet
    // ──────────────────────────────────────────────

    private var detailSheet: some View {
        LuminousSheetScaffold(title: "Guest Access",
                              eyebrow: "Shared with you",
                              eyebrowSymbol: "person.2.fill",
                              tint: LuminousPalette.amber,
                              ambience: [LuminousPalette.amber, LuminousPalette.magenta]) {
            LuminousTitledCard(symbol: "person.2.fill", title: "This home is shared with you", tint: LuminousPalette.amber) {
                VStack(alignment: .leading, spacing: 8) {
                    if !orchestrator.guestAccessInfo.profileNames.isEmpty {
                        Text("Profile: \(orchestrator.guestAccessInfo.profileNames.joined(separator: ", "))")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(LuminousPalette.ink)
                    }
                    Text("You see the rooms and controls the owner shared. Everything else stays out of the way.")
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LuminousTitledCard(symbol: "hand.raised.fill", title: "The honest fine print", tint: LuminousPalette.cyan) {
                Text("Room limits apply inside ChromaGlow on this phone. The key itself can control the whole bridge from any Hue app — a Philips Hue limitation.")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LuminousTitledCard(symbol: "qrcode", title: "Changing your access", tint: LuminousPalette.magenta) {
                Text("To change what you can access, ask the owner for a new invite and scan it again — that's the whole update mechanism, by design.")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The guest variant of the dashboard's "no rooms" empty state — zero
/// allowed rooms is a deliberate fail-closed outcome, not an error.
struct GuestZeroRoomsState: View {
    var body: some View {
        LuminousEmptyState(symbol: "person.2.slash",
                           title: "No rooms shared yet",
                           message: "The owner hasn't shared any rooms with you yet.\nAsk them for a new invite, then scan it again.")
    }
}
