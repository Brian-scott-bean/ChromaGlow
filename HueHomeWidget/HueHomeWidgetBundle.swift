// HueHomeWidgetBundle.swift
// HueHome Pro — Epic 5 / Widget
//
// Widget bundle entry point.
// HueHomeWidgetControl (Control Center) removed — iOS 18 only and
// not in scope for v0.1.0. Add back in a future story if needed.

import WidgetKit
import SwiftUI

@main
struct HueHomeWidgetBundle: WidgetBundle {
    var body: some Widget {
        HueHomeWidget()
    }
}
