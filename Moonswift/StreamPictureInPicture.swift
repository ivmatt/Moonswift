import AVKit

/// The system's Picture in Picture for the stream: the video layer moves into iOS's own floating window (which drags,
/// snaps, resizes and works over other apps) while the stream keeps going. A four-finger pinch starts it, and so does
/// leaving the app mid-stream. Its restore button brings the stream back full screen; its close button disconnects
/// (the game keeps running on the PC).
final class StreamPictureInPicture: NSObject {
    var onActiveChange: (Bool) -> Void = { _ in }
    var onRestore: () -> Void = {}
    var onClose: () -> Void = {}

    private var controller: AVPictureInPictureController?
    /// Stopping to come back full screen (or because the stream is closing), rather than the window's close button.
    private var isStoppingQuietly = false

    /// Once the layer is on screen and showing the stream.
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
        controller.delegate = self
        controller.requiresLinearPlayback = true // live: no skip buttons
        controller.canStartPictureInPictureAutomaticallyFromInline = true // leaving the app keeps streaming
        self.controller = controller
    }

    var isPossible: Bool { controller?.isPictureInPicturePossible == true }
    var isActive: Bool { controller?.isPictureInPictureActive == true }

    func start() { controller?.startPictureInPicture() }

    /// Closes the window without counting as its close button: for coming back full screen, or leaving the stream.
    func stopQuietly() {
        guard isActive else { return }
        isStoppingQuietly = true
        controller?.stopPictureInPicture()
    }
}

extension StreamPictureInPicture: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        onActiveChange(true)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        onActiveChange(false)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        isStoppingQuietly = true
        onRestore()
        completion(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onActiveChange(false)
        if !isStoppingQuietly { onClose() }
        isStoppingQuietly = false
    }
}

/// A live stream: always playing, no timeline.
extension StreamPictureInPicture: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
