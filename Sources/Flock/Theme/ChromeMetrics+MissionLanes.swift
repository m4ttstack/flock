import CoreGraphics

extension ChromeMetrics.MissionControl {
    /// A split lane's subgroup labels sit where At rest's section labels do:
    /// the first one below the heading, the second at At rest's gap between
    /// sections. The scroll content's inset is taken back out.
    static let subgroupTopPadding: CGFloat = laneScrollInset + restFirstSectionGap
    static let subgroupGap: CGFloat = cardGap + restSectionGap - laneScrollInset
    static let subgroupLabelGap: CGFloat = cardGap - laneScrollInset
    static let subgroupCountSpacing: CGFloat = 5
    /// Two dots in a lane's heading mark: the front one sits this fraction
    /// of a dot to the right of the back one, so most of the back one shows,
    /// and a ring of the lane's ground this fraction of a dot wide cuts it out.
    static let laneMarkOffset: CGFloat = 0.75
    static let laneMarkCutout: CGFloat = 0.2
}
