// WelcomeTourView.swift
// ChromaGlow — the Welcome Tour pager
//
// The full-screen tour surface: a swipeable TabView over TutorialCatalog
// pages in the Luminous look — the room behind the page glows in its
// colour, so swiping through the tour changes the light. Content comes from the caller
// (already audience-filtered — see WelcomeTourWiring / MoreView), so this
// view owns nothing but the page index. Skip and Done both land in
// `onFinish`; the caller decides what "finished" means (set the seen flag
// on first launch, just dismiss on replay).

import SwiftUI
import UIKit

struct WelcomeTourView: View {
    let pages: [TutorialPage]
    /// "WELCOME TOUR" for the full deck; the wiring passes "WHAT'S NEW" for
    /// the versioned mini-deck. Declared between pages and onFinish so
    /// trailing-closure call sites compile unchanged.
    var headerTitle: String = "WELCOME TOUR"
    let onFinish: () -> Void

    @State private var pageIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLastPage: Bool { pageIndex >= pages.count - 1 }
    private var accent: Color {
        Color(hex: pages.indices.contains(pageIndex) ? pages[pageIndex].accentHex : "#8C59FF")
    }

    var body: some View {
        ZStack {
            LuminousAmbience(colors: [accent, LuminousPalette.violet])
                .animation(.easeInOut(duration: 0.8), value: pageIndex)
            VStack(spacing: 0) {
                topBar
                pager
                footer
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: pageIndex) { _, newIndex in
            HapticManager.shared.light()
            guard pages.indices.contains(newIndex) else { return }
            UIAccessibility.post(
                notification: .pageScrolled,
                argument: "Page \(newIndex + 1) of \(pages.count): \(pages[newIndex].title)"
            )
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            LuminousEyebrow(text: headerTitle)
            Spacer()
            if !isLastPage {
                Button("Skip") { onFinish() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Skip the tour")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var pager: some View {
        TabView(selection: $pageIndex) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                pageContent(page, index: index)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder
    private func pageContent(_ page: TutorialPage, index: Int) -> some View {
        let pageAccent = Color(hex: page.accentHex)
        ScrollView {
            VStack(spacing: 0) {
                TutorialIllustrationView(kind: page.illustration,
                                         accent: pageAccent,
                                         isActive: index == pageIndex)
                    .frame(height: 250)
                    .frame(maxWidth: .infinity)
                    .luminousStageFrame()
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    LuminousEyebrow(text: page.eyebrow, tint: pageAccent)
                    Text(page.title)
                        .font(.system(.title, design: .rounded).weight(.heavy))
                        .foregroundStyle(LuminousPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(page.body)
                        .font(.body)
                        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let footnote = page.footnote {
                        Text(footnote)
                            .font(.footnote)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            LuminousRoundButton(symbol: "chevron.left", label: "Previous page", size: 44) {
                withAnimation(HueAnimation.adaptive(HueAnimation.toggle, reduceMotion: reduceMotion)) {
                    pageIndex = max(0, pageIndex - 1)
                }
            }
            .opacity(pageIndex == 0 ? 0 : 1)
            .disabled(pageIndex == 0)
            .accessibilityHidden(pageIndex == 0)

            Spacer()
            pageDots
            Spacer()

            LuminousPrimaryButton(title: isLastPage ? "Done" : "Next", compact: true) {
                if isLastPage {
                    HapticManager.shared.success()
                    onFinish()
                } else {
                    withAnimation(HueAnimation.adaptive(HueAnimation.toggle, reduceMotion: reduceMotion)) {
                        pageIndex = min(pages.count - 1, pageIndex + 1)
                    }
                }
            }
            .fixedSize()   // never let the dots row squeeze this into a wrap
            .accessibilityLabel(isLastPage ? "Finish tour" : "Next page")
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var pageDots: some View {
        // Compact metrics: 13 dots + Back + Next must fit a 375pt phone
        // without ever squeezing the Next label (which is fixedSize).
        HStack(spacing: 5) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(i == pageIndex ? accent : Color.white.opacity(0.30))
                    .frame(width: i == pageIndex ? 14 : 5, height: 5)
                    .shadow(color: i == pageIndex ? accent.opacity(0.8) : .clear, radius: 4)
            }
        }
        .animation(HueAnimation.adaptive(HueAnimation.toggle, reduceMotion: reduceMotion), value: pageIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(pageIndex + 1) of \(pages.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: pageIndex = min(pages.count - 1, pageIndex + 1)
            case .decrement: pageIndex = max(0, pageIndex - 1)
            @unknown default: break
            }
        }
    }
}

#Preview("Welcome Tour") {
    WelcomeTourView(pages: TutorialCatalog.pages) {}
}

#Preview("Welcome Tour — guest") {
    WelcomeTourView(pages: TutorialCatalog.pages(includeStudioSuite: false)) {}
}
