#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== Phase 1: git mv directories ==="
git mv ChromaGlow ChromaGlow
git mv ChromaGlowTests ChromaGlowTests
git mv ChromaGlowWidget ChromaGlowWidget
git mv ChromaGlow.xcodeproj ChromaGlow.xcodeproj
git mv ChromaGlowWidgetExtension.entitlements ChromaGlowWidgetExtension.entitlements
git mv LightShadeWatch ChromaGlowWatchExtension
git mv "ChromaGlowWatchApp" ChromaGlowWatchApp
git mv "ChromaGlowWatchAppTests" ChromaGlowWatchAppTests
git mv "ChromaGlowWatchAppUITests" ChromaGlowWatchAppUITests
git mv ChromaGlow-Icon.svg ChromaGlow-Icon.svg 2>/dev/null || true

echo "=== Phase 2: git mv key files ==="
git mv ChromaGlow/ChromaGlowApp.swift ChromaGlow/ChromaGlowApp.swift
git mv ChromaGlow/ChromaGlow.entitlements ChromaGlow/ChromaGlow.entitlements
git mv ChromaGlowWidget/ChromaGlowWidget.swift ChromaGlowWidget/ChromaGlowWidget.swift
git mv ChromaGlowWidget/ChromaGlowWidgetBundle.swift ChromaGlowWidget/ChromaGlowWidgetBundle.swift
git mv ChromaGlowWidget/ChromaGlowWidgetControl.swift ChromaGlowWidget/ChromaGlowWidgetControl.swift
git mv ChromaGlowWatchExtension/ChromaGlowWatchWidget.swift ChromaGlowWatchExtension/ChromaGlowWatchWidget.swift
git mv ChromaGlowWatchExtension/ChromaGlowWatchWidgetBundle.swift ChromaGlowWatchExtension/ChromaGlowWatchWidgetBundle.swift
git mv ChromaGlowWatchExtension/LightShadeWatch.entitlements ChromaGlowWatchExtension/ChromaGlowWatchExtension.entitlements
git mv ChromaGlowWatchApp/ChromaGlowWatchApp.swift ChromaGlowWatchApp/ChromaGlowWatchApp.swift
git mv ChromaGlowWatchApp/LightShadeWatchApp.entitlements ChromaGlowWatchApp/ChromaGlowWatchApp.entitlements
git mv "ChromaGlowWatchApp/ChromaGlowWatchApp.entitlements" "ChromaGlowWatchApp/ChromaGlowWatchAppExtension.entitlements"
git mv ChromaGlowWatchAppTests/ChromaGlowWatchAppTests.swift ChromaGlowWatchAppTests/ChromaGlowWatchAppTests.swift
git mv ChromaGlowWatchAppUITests/ChromaGlowWatchAppUITests.swift ChromaGlowWatchAppUITests/ChromaGlowWatchAppUITests.swift
git mv ChromaGlowWatchAppUITests/ChromaGlowWatchAppUITestsLaunchTests.swift ChromaGlowWatchAppUITests/ChromaGlowWatchAppUITestsLaunchTests.swift
git mv ChromaGlow.xcodeproj/xcshareddata/xcschemes/"ChromaGlow 1.xcscheme" ChromaGlow.xcodeproj/xcshareddata/xcschemes/ChromaGlow.xcscheme

echo "=== Phase 3: bulk text replace ==="
export LC_ALL=C
while IFS= read -r -d '' f; do
  perl -i -pe '
    s/ChromaGlowWatchAppUITests/ChromaGlowWatchAppUITests/g;
    s/ChromaGlowWatchAppTests/ChromaGlowWatchAppTests/g;
    s/ChromaGlowWatchAppUITestsLaunchTests/ChromaGlowWatchAppUITestsLaunchTests/g;
    s/ChromaGlowWatchAppUITests/ChromaGlowWatchAppUITests/g;
    s/ChromaGlowWatchAppTests/ChromaGlowWatchAppTests/g;
    s/ChromaGlowWatchApp\.entitlements/ChromaGlowWatchApp.entitlements/g;
    s/ChromaGlowWatchApp/ChromaGlowWatchApp/g;
    s/ChromaGlowWatchApp/ChromaGlowWatchApp/g;
    s/ChromaGlowWatchApp/ChromaGlowWatchApp/g;
    s/ChromaGlowWatchExtension/ChromaGlowWatchExtension/g;
    s/ChromaGlowWatchEntryView/ChromaGlowWatchEntryView/g;
    s/ChromaGlowWatchWidgetBundle/ChromaGlowWatchWidgetBundle/g;
    s/LightShadeWatch\.swift/ChromaGlowWatchWidget.swift/g;
    s/struct ChromaGlowWatchWidget:/struct ChromaGlowWatchWidget:/g;
    s/ChromaGlowWidgetExtension/ChromaGlowWidgetExtension/g;
    s/ChromaGlowWidgetBundle/ChromaGlowWidgetBundle/g;
    s/ChromaGlowWidgetControl/ChromaGlowWidgetControl/g;
    s/ChromaGlowWidget\.swift/ChromaGlowWidget.swift/g;
    s/struct ChromaGlowWidget/struct ChromaGlowWidget/g;
    s/ChromaGlowWidget\b/ChromaGlowWidget/g;
    s/ChromaGlowTests/ChromaGlowTests/g;
    s/ChromaGlowApp\.swift/ChromaGlowApp.swift/g;
    s/struct ChromaGlowApp/struct ChromaGlowApp/g;
    s/ChromaGlowApp\b/ChromaGlowApp/g;
    s/ChromaGlow\.entitlements/ChromaGlow.entitlements/g;
    s/ChromaGlow\.app/ChromaGlow.app/g;
    s|ChromaGlow/|ChromaGlow/|g;
    s/ChromaGlow\.xcodeproj/ChromaGlow.xcodeproj/g;
    s/ChromaGlow/ChromaGlow/g;
    s/ChromaGlow/ChromaGlow/g;
    s/INFOPLIST_KEY_CFBundleDisplayName = ChromaGlow Watch/INFOPLIST_KEY_CFBundleDisplayName = ChromaGlow Watch/g;
    s/INFOPLIST_KEY_CFBundleDisplayName = ChromaGlow/INFOPLIST_KEY_CFBundleDisplayName = ChromaGlow/g;
    s/in ChromaGlow/in ChromaGlow/g;
    s/fatalError\("ChromaGlow:/fatalError("ChromaGlow:/g;
    s/\bHueHome\b/ChromaGlow/g;
  ' "$f" 2>/dev/null || true
done < <(find . -type f \( \
  -name '*.swift' -o -name '*.md' -o -name '*.mdc' -o -name '*.rb' -o -name '*.sh' \
  -o -name '*.plist' -o -name '*.pbxproj' -o -name '*.xcscheme' -o -name '*.html' \
  -o -name '.cursorrules' -o -name '*.entitlements' \) \
  ! -path './.git/*' ! -path './build/*' -print0)

echo "=== Done ==="
