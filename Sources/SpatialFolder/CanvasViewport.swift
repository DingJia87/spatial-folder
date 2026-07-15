import Foundation

enum CanvasViewport {
    static func displayScale(
        logicalSize: CGSize,
        viewportWidth: CGFloat,
        displaySize: CGSize
    ) -> CGFloat {
        guard logicalSize.width > 0, logicalSize.height > 0,
              viewportWidth > 0, displaySize.width > 0, displaySize.height > 0 else {
            return 1
        }
        return min(
            1,
            viewportWidth / logicalSize.width,
            displaySize.width / logicalSize.width,
            displaySize.height / logicalSize.height
        )
    }
}
