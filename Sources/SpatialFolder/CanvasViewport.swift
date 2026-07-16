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

    static func presentationSize(
        logicalSize: CGSize,
        viewportSize: CGSize,
        displayScale: CGFloat
    ) -> CGSize {
        guard logicalSize.width > 0, logicalSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0,
              displayScale > 0 else {
            return logicalSize
        }
        return CGSize(
            width: max(logicalSize.width, viewportSize.width / displayScale),
            height: max(logicalSize.height, viewportSize.height / displayScale)
        )
    }
}
