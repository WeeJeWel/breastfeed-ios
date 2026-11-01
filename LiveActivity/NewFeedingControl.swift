import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct NewFeedingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.breastfeed.newFeeding") {
            ControlWidgetButton(action: NewFeedingIntent()) {
                Label("New Feeding", image: "BreastControl")
            }
        }
        .displayName("New Feeding")
        .description("Open a new feeding for the selected baby.")
    }
}
