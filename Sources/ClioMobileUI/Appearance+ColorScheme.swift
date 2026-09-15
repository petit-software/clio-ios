import ClioMobileCore
import SwiftUI

public extension Appearance {
    /// What `preferredColorScheme` wants: nil follows the phone.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
