// ProfilesAccessView.swift
// ChromaGlow — Family Sharing Phase 3 (owner UI)
//
// More → PEOPLE → Profiles & Access. The owner's roster of guest
// profiles: who's invited, which rooms and features they hold, when they
// were last issued a code. "Generate Invite" hands the profile to
// GuestInviteMintSheet (per-guest key mint + time-boxed QR); the sheet's
// onMinted writes the key refs back onto the profile.
//
// Enforcement honesty is stated ON the surface (design §5): room limits
// are app-side; the key is bridge-wide by Hue platform design.

import SwiftUI
import SwiftData

struct ProfilesAccessView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    @Query(sort: \GuestProfile.createdAt) private var profiles: [GuestProfile]
    @Query(sort: \BridgeRecord.sortOrder) private var bridges: [BridgeRecord]

    @State private var editingProfile: GuestProfile?
    @State private var showCreateSheet = false
    @State private var invitingProfile: GuestProfile?
    @State private var profileToDelete: GuestProfile?
    @State private var showDeleteAlert = false
    @State private var profileToRevoke: GuestProfile?
    @State private var showRevokeAlert = false
    @State private var revokeOutcomeMessage: String?
    @State private var revokeInFlight = false

    /// Pure: every key ref a profile was EVER issued, existing order first,
    /// new refs appended, no duplicates (a re-mint for the same bridge
    /// upserts the same Keychain account, so its ref repeats).
    nonisolated static func mergedKeyRefs(_ existing: [String], adding new: [String]) -> [String] {
        var seen = Set(existing)
        var merged = existing
        for ref in new where seen.insert(ref).inserted {
            merged.append(ref)
        }
        return merged
    }

    private static let rowInsets = EdgeInsets(top: 5, leading: HueSpacing.screenH, bottom: 5, trailing: HueSpacing.screenH)

    var body: some View {
        List {
            LuminousScreenTitle(title: "Profiles & Access",
                                eyebrow: "People",
                                eyebrowSymbol: "person.2.fill",
                                eyebrowTint: LuminousPalette.amber,
                                subtitle: "A profile for each person: their rooms, what they may change, and a one-scan invite.")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: HueSpacing.screenH, bottom: 12, trailing: HueSpacing.screenH))

            if profiles.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.rowInsets)
            } else {
                ForEach(profiles) { profile in
                    profileRow(profile)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(Self.rowInsets)
                        .contentShape(Rectangle())
                        .onTapGesture { editingProfile = profile }
                        .contextMenu {
                            Button {
                                invitingProfile = profile
                            } label: {
                                Label("Generate Invite", systemImage: "qrcode")
                            }
                            .disabled(profile.allowedGroupIDs.isEmpty || profile.revokedAt != nil)
                            Button {
                                editingProfile = profile
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            if !profile.mintedKeyRefs.isEmpty && profile.revokedAt == nil {
                                Button(role: .destructive) {
                                    profileToRevoke = profile
                                    showRevokeAlert = true
                                } label: {
                                    Label("Revoke Access", systemImage: "nosign")
                                }
                            }
                            Button(role: .destructive) {
                                profileToDelete = profile
                                showDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onDelete { indexSet in
                    if let idx = indexSet.first {
                        profileToDelete = profiles[idx]
                        showDeleteAlert = true
                    }
                }

                newProfileButton
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.rowInsets)

                keysOnBridgeSection
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.rowInsets)

                honestyFootnote
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: HueSpacing.screenH + 6, bottom: 24, trailing: HueSpacing.screenH + 6))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { LuminousAmbience(colors: [LuminousPalette.amber, LuminousPalette.magenta], intensity: 0.6) }
        .luminousPageChrome(title: "Profiles & Access")
        .sheet(isPresented: $showCreateSheet) {
            GuestProfileEditorView(profile: nil)
        }
        .sheet(item: $editingProfile) { profile in
            GuestProfileEditorView(profile: profile)
        }
        .sheet(item: $invitingProfile) { profile in
            GuestInviteMintSheet(
                spec: GuestInviteSpec(
                    profileID: profile.id,
                    profileName: profile.name,
                    allowedGroupIDs: profile.allowedGroupIDs,
                    features: profile.features,
                    isRevoked: profile.revokedAt != nil
                ),
                onMinted: { refs in
                    // UNION, never replace: a mint session only reports the
                    // bridges it targeted this time, and revocation finds
                    // keys solely through this list — replacing it orphaned
                    // every earlier bridge's key (unrevocable from here).
                    profile.mintedKeyRefs = Self.mergedKeyRefs(profile.mintedKeyRefs, adding: refs)
                    profile.lastInviteAt = Date()
                    try? modelContext.save()
                }
            )
        }
        .alert("Delete Profile?", isPresented: $showDeleteAlert, presenting: profileToDelete) { profile in
            Button("Delete", role: .destructive) { delete(profile) }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text(profile.mintedKeyRefs.isEmpty
                 ? "This removes \(profile.name)'s profile. No keys were issued to it."
                 : "Deleting removes \(profile.name)'s key from this phone and blocks re-inviting from this profile. Their existing bridge access can only be fully revoked from the official Philips Hue app (or by resetting app keys).")
        }
        .alert("Revoke \(profileToRevoke?.name ?? "guest")'s access?",
               isPresented: $showRevokeAlert, presenting: profileToRevoke) { profile in
            Button("Revoke", role: .destructive) {
                Task { await revoke(profile) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("ChromaGlow will try to delete their key from each bridge and always forgets it on this phone (their invite can't be re-issued). If a bridge refuses, their existing access can only be fully revoked from the official Philips Hue app.")
        }
        .alert("Revocation", isPresented: Binding(
            get: { revokeOutcomeMessage != nil },
            set: { if !$0 { revokeOutcomeMessage = nil } }
        )) {
            Button("OK", role: .cancel) { revokeOutcomeMessage = nil }
        } message: {
            Text(revokeOutcomeMessage ?? "")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Rows
    // ──────────────────────────────────────────────

    private func profileRow(_ profile: GuestProfile) -> some View {
        let tint = Color(hex: profile.colorHex)
        let revoked = profile.revokedAt != nil
        let canInvite = !profile.allowedGroupIDs.isEmpty && !revoked
        return HStack(spacing: 14) {
            LuminousIconBadge(symbol: profile.icon, tint: tint, size: 46, lit: !revoked)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(LuminousType.cardTitle)
                        .foregroundStyle(LuminousPalette.ink)
                        .lineLimit(1)
                    if revoked {
                        LuminousTextBadge(text: "Revoked", tint: LuminousPalette.danger)
                    }
                }
                Text(summary(for: profile))
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                if let lastInviteAt = profile.lastInviteAt {
                    Text("Invited \(lastInviteAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(LuminousPalette.inkTertiary)
                }
            }
            Spacer(minLength: 0)
            Button {
                invitingProfile = profile
            } label: {
                LuminousRoundGlyph(symbol: "qrcode", size: 42,
                                   tint: canInvite ? LuminousPalette.cyan : LuminousPalette.inkTertiary)
            }
            .buttonStyle(LuminousPressStyle(scale: 0.9))
            .disabled(!canInvite)
            .accessibilityLabel("Generate invite for \(profile.name)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .luminousPanel(radius: LuminousPalette.cardRadius, glow: revoked ? nil : tint, glowStrength: 0.45)
    }

    private func summary(for profile: GuestProfile) -> String {
        let roomCount = profile.allowedGroupIDs.count
        let rooms = roomCount == 0 ? "No rooms yet" : "\(roomCount) room\(roomCount == 1 ? "" : "s")"
        let featureNames: [String] = profile.features.compactMap { feature in
            switch feature {
            case GuestFeature.onOff:      return "on/off"
            case GuestFeature.brightness: return "brightness"
            case GuestFeature.scenes:     return "scenes"
            default:                      return nil
            }
        }
        return featureNames.isEmpty ? rooms : "\(rooms) · \(featureNames.joined(separator: ", "))"
    }

    private var newProfileButton: some View {
        Button {
            showCreateSheet = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(LuminousPalette.void)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(LuminousPalette.signalGradient))
                    .shadow(color: LuminousPalette.cyan.opacity(0.5), radius: 8)
                Text("New Profile")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LuminousPalette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 60)
            .luminousGlass(radius: LuminousPalette.cardRadius, accent: LuminousPalette.cyan, selected: true)
            .contentShape(RoundedRectangle(cornerRadius: LuminousPalette.cardRadius, style: .continuous))
        }
        .buttonStyle(LuminousPressStyle())
    }

    /// Phase 4 diagnostic: the whitelist runtime probe, one row per active
    /// bridge. Reveals — on real firmware — whether local key listing and
    /// removal still exist, with honest copy either way.
    @ViewBuilder
    private var keysOnBridgeSection: some View {
        // "Your" bridges only — a guest-held bridge's keys belong to its
        // owner (BridgeKeysView also refuses removal there).
        let activeBridges = bridges.filter { $0.isActive && !orchestrator.isGuestGrantedBridge($0.id) }
        if !activeBridges.isEmpty {
            LuminousGroup(title: "Keys on your bridges") {
                ForEach(Array(activeBridges.enumerated()), id: \.element.id) { idx, bridge in
                    NavigationLink(destination: BridgeKeysView(bridge: bridge)) {
                        LuminousRow(symbol: "key.horizontal.fill", tint: LuminousPalette.amber, title: bridge.name,
                                    subtitle: "See every app key this bridge holds")
                    }
                    .buttonStyle(LuminousRowButtonStyle())
                    if idx < activeBridges.count - 1 { LuminousRowDivider() }
                }
            }
            .padding(.top, 8)
        }
    }

    private var honestyFootnote: some View {
        Text("Room limits apply inside ChromaGlow on the guest's phone. The key itself can control the whole bridge from any Hue app — a Philips Hue limitation.")
            .font(.caption)
            .foregroundStyle(LuminousPalette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // ──────────────────────────────────────────────
    // MARK: - Empty state
    // ──────────────────────────────────────────────

    private var emptyState: some View {
        LuminousEmptyState(symbol: "person.2",
                           title: "No Profiles",
                           message: "Create a profile for each family member or guest, pick their rooms, then hand them a one-scan invite.",
                           actionTitle: "New Profile",
                           action: { showCreateSheet = true })
    }

    // ──────────────────────────────────────────────
    // MARK: - Actions
    // ──────────────────────────────────────────────

    private func delete(_ profile: GuestProfile) {
        // Owner-side wipe: the stored key material goes with the profile.
        // Bridge-side access survives until real revocation (the Revoke
        // action / the official Hue app) — the alert said exactly that.
        GuestKeyStore.delete(accounts: profile.mintedKeyRefs)
        modelContext.delete(profile)
        try? modelContext.save()
    }

    private func revoke(_ profile: GuestProfile) async {
        guard !revokeInFlight else { return }
        revokeInFlight = true
        defer { revokeInFlight = false }

        let report = await GuestRevocationService.revoke(
            profileID: profile.id,
            mintedKeyRefs: profile.mintedKeyRefs
        )

        // The keys are gone from this phone either way — mark revoked so the
        // mint sheet refuses to re-show or regenerate a QR for this profile.
        profile.revokedAt = Date()
        try? modelContext.save()

        if report.fullyRevokedEverywhere {
            revokeOutcomeMessage =
                "\(profile.name)'s key was deleted from the bridge itself — they're fully signed out."
        } else {
            revokeOutcomeMessage =
                "\(profile.name)'s key was removed from this phone and can't be re-issued. At least one bridge refused the delete — their existing access there can only be fully revoked from the official Philips Hue app (or by resetting app keys)."
        }
    }
}
