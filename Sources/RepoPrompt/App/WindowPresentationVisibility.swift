/// Presentation-only policy; it must never gate execution, persistence, or model publication.
enum WindowPresentationVisibility {
    static func isVisible(
        windowIsVisible: Bool,
        isMiniaturized: Bool,
        occlusionIsVisible: Bool,
        appIsHidden: Bool
    ) -> Bool {
        windowIsVisible && !isMiniaturized && occlusionIsVisible && !appIsHidden
    }
}
