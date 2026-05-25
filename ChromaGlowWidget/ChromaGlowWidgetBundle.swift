// ChromaGlowWidgetBundle.swift
// ChromaGlow — Epic 5 / Widget
//
// Widget bundle entry point.
// ChromaGlowWidgetControl (Control Center) removed — iOS 18 only and
// not in scope for v0.1.0. Add back in a future story if needed.

import WidgetKit
import SwiftUI

@main
struct ChromaGlowWidgetBundle: WidgetBundle {
    var body: some Widget {
        ChromaGlowWidget()
    }
}
