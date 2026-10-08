import SwiftUI
import WidgetKit

/// The phone's widget extension (0.7.3): the home-screen and lock-screen widget,
/// and the journey's Live Activity and Dynamic Island.
@main
struct RoadsAndRunesWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        RideLiveActivity()
    }
}
