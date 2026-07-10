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
    @Environment(\.colorScheme)  private var colorScheme
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    @Query(sort: \GuestProfile.createdAt) private var profiles: [GuestProfile]

    @State private var editingProfile: GuestProfile?
    @State private var showCreateSheet = false
    @State private var invitingProfile: GuestProfile?
    @State private var profileToDelete: GuestProfile?
    @State private var showDeleteAlert = false

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if profiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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

                    honestyFootnote
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Profiles & Access")
        .navigationBarTitleDisplayMode(.large)
        .preferredColorScheme(.dark)
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
                    profile.mintedKeyRefs = refs
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
    }

    // ──────────────────────────────────────────────
    // MARK: - Rows
    // ──────────────────────────────────────────────

    private func profileRow(_ profile: GuestProfile) -> some View {
        GlassmorphicCard(isActive: false, glowColor: HuePalette.amber) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(hex: profile.colorHex).opacity(0.20))
                        .frame(width: 40, height: 40)
                    Image(systemName: profile.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color(hex: profile.colorHex))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        if profile.revokedAt != nil {
                            Text("REVOKED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.red.opacity(0.15)))
                        }
                    }
                    Text(summary(for: profile))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                    if let lastInviteAt = profile.lastInviteAt {
                        Text("Invited \(lastInviteAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.30))
                    }
                }
                Spacer()
                Button {
                    invitingProfile = profile
                } label: {
                    Image(systemName: "qrcode")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(
                            profile.allowedGroupIDs.isEmpty || profile.revokedAt != nil
                                ? .white.opacity(0.2) : HuePalette.amber
                        )
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(profile.allowedGroupIDs.isEmpty || profile.revokedAt != nil)
                .accessibilityLabel("Generate invite for \(profile.name)")
            }
        }
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
            Label("New Profile", systemImage: "plus.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HuePalette.amber)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(HuePalette.amber.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    private var honestyFootnote: some View {
        Text("Room limits apply inside ChromaGlow on the guest's phone. The key itself can control the whole bridge from any Hue app — a Philips Hue limitation.")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.35))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // ──────────────────────────────────────────────
    // MARK: - Empty state / background
    // ──────────────────────────────────────────────

    private var emptyState: some View {
        VStack(spacing: HueSpacing.xl) {
            AmberRadialGlow(radius: 50)
                .overlay {
                    Image(systemName: "person.2")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(HuePalette.amber)
                }
                .frame(width: 80, height: 80)

            VStack(spacing: HueSpacing.sm) {
                Text("No Profiles")
                    .font(HueFont.displaySmall)
                    .foregroundStyle(HuePalette.Noir.textPrimary)
                Text("Create a profile for each family member or guest, pick their rooms, then hand them a one-scan invite.")
                    .font(HueFont.body)
                    .foregroundStyle(HuePalette.Noir.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, HueSpacing.xl)
            }

            Button {
                showCreateSheet = true
            } label: {
                Label("New Profile", systemImage: "plus.circle.fill")
                    .font(HueFont.callout.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, HueSpacing.xxl)
                    .padding(.vertical, HueSpacing.md)
                    .background(HuePalette.amber)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(hex: "#141224"), Color(hex: "#0B0A14")],
            startPoint: .top, endPoint: .bottom
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Actions
    // ──────────────────────────────────────────────

    private func delete(_ profile: GuestProfile) {
        // Owner-side wipe: the stored key material goes with the profile.
        // Bridge-side access survives until real revocation (Phase 4 / the
        // official Hue app) — the alert said exactly that.
        GuestKeyStore.delete(accounts: profile.mintedKeyRefs)
        modelContext.delete(profile)
        try? modelContext.save()
    }
}
