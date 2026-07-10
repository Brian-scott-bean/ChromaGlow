// GuestAccessBanner.swift
// ChromaGlow — Family Sharing Phase 3 (guest-side transparency)
//
// A slim capsule at the top of the dashboard whenever any live bridge is
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
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HuePalette.amber)
                    Text(bannerText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(HuePalette.amber.opacity(0.10))
                        .overlay(Capsule().strokeBorder(HuePalette.amber.opacity(0.25), lineWidth: 1))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
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
        StageSheetScaffold(title: "Guest Access") {
            StageCard(icon: "person.2.fill", title: "This home is shared with you") {
                VStack(alignment: .leading, spacing: HueSpacing.sm) {
                    if !orchestrator.guestAccessInfo.profileNames.isEmpty {
                        Text("Profile: \(orchestrator.guestAccessInfo.profileNames.joined(separator: ", "))")
                            .font(HueFont.stageControl)
                            .foregroundStyle(StagePalette.ink)
                    }
                    Text("You see the rooms and controls the owner shared. Everything else stays out of the way.")
                        .font(HueFont.stageStatus)
                        .foregroundStyle(StagePalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            StageCard(icon: "hand.raised.fill", title: "The honest fine print") {
                Text("Room limits apply inside ChromaGlow on this phone. The key itself can control the whole bridge from any Hue app — a Philips Hue limitation.")
                    .font(HueFont.stageStatus)
                    .foregroundStyle(StagePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            StageCard(icon: "qrcode", title: "Changing your access") {
                Text("To change what you can access, ask the owner for a new invite and scan it again — that's the whole update mechanism, by design.")
                    .font(HueFont.stageStatus)
                    .foregroundStyle(StagePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The guest variant of the dashboard's "no rooms" empty state — zero
/// allowed rooms is a deliberate fail-closed outcome, not an error.
struct GuestZeroRoomsState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.25))
            Text("No rooms shared yet")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.55))
            Text("The owner hasn't shared any rooms with you yet.\nAsk them for a new invite, then scan it again.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
