// HueHomeWidgetBundle.swift
// HueHome Pro — Epic 5 / Widget
//
// Widget bundle entry point. The Controls are iOS 18+; the availability check
// keeps the bundle loadable on iOS 17, where they simply don't appear.

import WidgetKit
import SwiftUI

@main
struct HueHomeWidgetBundle: WidgetBundle {
    var body: some Widget {
        HueHomeWidget()

        if #available(iOSApplicationExtension 18.0, *) {
            RoomToggleControl()
            SceneControl()
            PresetControl()
            AllOffControl()
        }
    }
}
