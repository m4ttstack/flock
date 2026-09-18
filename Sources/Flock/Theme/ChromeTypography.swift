import CoreText
import Foundation
import SwiftUI

/// Every face and size the window chrome sets text in. Chrome text is Inter,
/// bundled with the app; monospaced chrome text is the terminal face, so a
/// readout matches the panes beside it. Sizes are the chrome design's at the
/// same 1.28x as `ChromeMetrics`, to the half point. SF Symbols stay in the
/// system face, sized to sit beside the text they accompany.
enum ChromeType {
    enum Weight: CaseIterable {
        case regular, medium, semibold, bold

        /// Faces are named outright rather than picked by a weight trait, so
        /// a partial registration can never silently resolve medium or
        /// semibold to the regular face.
        var postScriptName: String {
            switch self {
            case .regular: "Inter-Regular"
            case .medium: "Inter-Medium"
            case .semibold: "Inter-SemiBold"
            case .bold: "Inter-Bold"
            }
        }
    }

    static let windowTitle = inter(11.5, .medium)
    static let connectionNotice = inter(11.5)
    static let banner = inter(14)
    static let bannerSymbol = Font.system(size: 16.5)

    static let railHeading = inter(10, .semibold)
    static let railHeadingTracking: CGFloat = 1.28
    static let railHeadingSymbol = Font.system(size: 13.5, weight: .medium)
    static func workspaceName(selected: Bool) -> Font { inter(14, selected ? .medium : .regular) }
    static let workspaceCount = inter(11.5)

    static let tabLabelSize: CGFloat = 14
    static func tabLabelWeight(selected: Bool) -> Weight { selected ? .medium : .regular }
    static func tabLabel(selected: Bool) -> Font { inter(tabLabelSize, tabLabelWeight(selected: selected)) }
    static let protocolReadout = mono(11.5)

    static let paneTitle = inter(11.5, .medium)
    static let statusChip = mono(11.5)
    static let chatButtonHandle = inter(10, .semibold)
    static let chatButtonGlyph = Font.system(size: 10)
    static let emptyCanvas = inter(15.5)
    static let rearrangeSymbol = Font.system(size: 28, weight: .semibold)

    static let cardSymbol = Font.system(size: 28)
    static let cardText = mono(13)
    static let cardHint = inter(11.5)

    static let gridTitle = inter(14, .medium)
    static let gridCount = inter(11.5)
    static let gridHint = mono(11.5)
    static let gridCardName = inter(14, .medium)
    static let gridCardMeta = inter(11.5)
    static func gridTabLabel(selected: Bool) -> Font { inter(11.5, selected ? .medium : .regular) }
    static let gridMiniPaneTitle = inter(8.5, .medium)
    static let gridTileTitle = inter(14, .medium)
    static let gridTileLabel = inter(11.5)

    static let hoverCardTitle = inter(14, .medium)
    static let hoverCardDetail = inter(11.5)
    static let hoverCardTail = mono(11.5)
    static let hoverCardCopy = inter(11)
    static let hoverCardCopySymbol = Font.system(size: 9.5, weight: .medium)

    static let launcherName = inter(16.5, .medium)
    static let launcherMonogram = inter(14, .bold)
    static let launcherHint = inter(11.5)

    static let toastSymbol = Font.system(size: 13, weight: .medium)
    static let toastMessage = inter(14)
    static let attentionToastHeadline = inter(13, .medium)
    static let attentionToastBreadcrumb = inter(11.5)
    static let attentionToastPill = inter(11.5, .medium)
    static let attentionToastGlyph = Font.system(size: 10, weight: .semibold)
    static let copiedSymbol = Font.system(size: 14, weight: .medium)
    static let copiedMessage = inter(13)

    /// Sized from the control's own metric: the glyph and the box it sits in
    /// are one control, and two numbers for it drift apart.
    static let closeSymbol = Font.system(size: ChromeMetrics.CloseButton.symbol, weight: .bold)
    static let zoomBadge = Font.system(size: 9.5, weight: .semibold)

    static let ghostSymbol = Font.system(size: 14, weight: .semibold)
    static let ghostLabel = inter(14, .semibold)
    static let ghostCompactSymbol = Font.system(size: 10.5, weight: .semibold)
    static let ghostCompactLabel = inter(11.5, .semibold)
    static let ratioLabel = inter(13, .semibold)

    static func inter(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .custom(weight.postScriptName, fixedSize: size)
    }

    static func mono(_ size: CGFloat) -> Font {
        .custom(TerminalFont.face, fixedSize: size)
    }

    /// Must run before the first chrome view draws text: a face that is not
    /// registered yet resolves to the system face, with no error.
    static func install() {
        _ = installation
    }

    private static let installation: Void = {
        let bundle = Bundle(for: BundleToken.self)
        for weight in Weight.allCases {
            guard let url = bundle.url(forResource: weight.postScriptName, withExtension: "otf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

/// Resolves to whichever bundle the chrome is compiled into: the app, or the
/// render test bundle.
private final class BundleToken {}
