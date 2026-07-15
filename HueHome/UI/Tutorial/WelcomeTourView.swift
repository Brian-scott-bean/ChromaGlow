// WelcomeTourView.swift
// ChromaGlow — the Welcome Tour pager
//
// The full-screen tour surface: a swipeable TabView over TutorialCatalog
// pages in the StageKit dark-stage look. Content comes from the caller
// (already audience-filtered — see WelcomeTourWiring / MoreView), so this
// view owns nothing but the page index. Skip and Done both land in
// `onFinish`; the caller decides what "finished" means (set the seen flag
// on first launch, just dismiss on replay).

import SwiftUI
import UIKit

struct WelcomeTourView: View {
    let pages: [TutorialPage]
    let onFinish: () -> Void

    @State private var pageIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLastPage: Bool { pageIndex >= pages.count - 1 }
    private var accent: Color {
        Color(hex: pages.indices.contains(pageIndex) ? pages[pageIndex].accentHex : "#FFC107")
    }

    var body: some View {
        ZStack {
            StagePalette.stage.ignoresSafeArea()
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
            Text("WELCOME TOUR")
                .font(HueFont.stageTag)
                .tracking(1.2)
                .foregroundStyle(StagePalette.muted)
            Spacer()
            if !isLastPage {
                Button("Skip") { onFinish() }
                    .font(HueFont.stageChip)
                    .foregroundStyle(StagePalette.muted)
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
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    Text(page.eyebrow)
                        .font(HueFont.stageTag)
                        .tracking(1.2)
                        .foregroundStyle(pageAccent)
                    Text(page.title)
                        .font(HueFont.tourTitle)
                        .foregroundStyle(StagePalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(page.body)
                        .font(HueFont.tourBody)
                        .foregroundStyle(StagePalette.ink.opacity(0.72))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let footnote = page.footnote {
                        Text(footnote)
                            .font(HueFont.stageStatus)
                            .foregroundStyle(StagePalette.muted)
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
        HStack(spacing: 16) {
            Button {
                withAnimation(HueAnimation.adaptive(HueAnimation.toggle, reduceMotion: reduceMotion)) {
                    pageIndex = max(0, pageIndex - 1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StagePalette.ink.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .overlay(Circle().strokeBorder(StagePalette.line, lineWidth: 1))
            }
            .accessibilityLabel("Previous page")
            .opacity(pageIndex == 0 ? 0 : 1)
            .disabled(pageIndex == 0)

            Spacer()
            pageDots
            Spacer()

            Button {
                if isLastPage {
                    HapticManager.shared.success()
                    onFinish()
                } else {
                    withAnimation(HueAnimation.adaptive(HueAnimation.toggle, reduceMotion: reduceMotion)) {
                        pageIndex = min(pages.count - 1, pageIndex + 1)
                    }
                }
            } label: {
                Text(isLastPage ? "Done" : "Next")
                    .font(HueFont.stageName)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26)
                    .frame(height: 44)
                    .background(Capsule().fill(HuePalette.amber))
            }
            .accessibilityLabel(isLastPage ? "Finish tour" : "Next page")
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(i == pageIndex ? accent : Color.white.opacity(0.22))
                    .frame(width: i == pageIndex ? 18 : 6, height: 6)
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
