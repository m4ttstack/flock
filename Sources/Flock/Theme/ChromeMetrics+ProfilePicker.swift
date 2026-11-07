import SwiftUI

extension ChromeMetrics {
    enum ProfilePicker {
        static let spacing: CGFloat = 6
        static let dot: CGFloat = 6
        static let marker: CGFloat = 13
        static let chevron: CGFloat = 9
        static let verticalPadding: CGFloat = 6
        static let horizontalPadding: CGFloat = 9
        static let listWidth: CGFloat = 240
        static let listVerticalPadding: CGFloat = 6
        static let listRowInset: CGFloat = 5
        static let listHorizontalPadding: CGFloat = 8
        static let listRowVerticalPadding: CGFloat = 6
        static let listRowSpacing: CGFloat = 1
        static let listSectionGap: CGFloat = 5
        static let check: CGFloat = 11
    }
}

extension ChromeType {
    static let profilePickerName = inter(13, .medium)
    static let profilePickerMarker = Font.system(size: 11, weight: .medium)
    static let profilePickerChevron = Font.system(size: 9, weight: .semibold)
    static let profilePickerRow = inter(13)
    static let profilePickerCheck = Font.system(size: 10, weight: .bold)
    static let profilePickerHint = inter(11)
}
