import CoreServices
import Foundation

/// FSEvents 文件级监听能捕获子项目的扩展属性变化；目录 vnode 监听无法看到 Finder 标签变化。
final class FolderChangeMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?

    init?(
        folderURL: URL,
        latency: CFTimeInterval = 0.15,
        onChange: @escaping @Sendable () -> Void
    ) {
        let callbackBox = FolderChangeHandlerBox(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<FolderChangeHandlerBox>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<FolderChangeHandlerBox>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderChangeCallback,
            &context,
            [folderURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        cancel()
    }

    func cancel() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

private let folderChangeCallback: FSEventStreamCallback = {
    _, context, eventCount, _, _, _ in
    guard eventCount > 0, let context else { return }
    Unmanaged<FolderChangeHandlerBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .onChange()
}

private final class FolderChangeHandlerBox: @unchecked Sendable {
    let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }
}
