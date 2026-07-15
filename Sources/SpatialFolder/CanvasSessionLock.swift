import Darwin
import Foundation

/// 描述当前持有画布写入锁的进程，供第二个 App 给出可理解的提示。
struct CanvasSessionOwner: Codable, Equatable, Sendable {
    let processID: Int32
    let appVersion: String
    let acquiredAt: Date
}

/// 尝试获取画布锁后的结果。
enum CanvasSessionLockResult {
    case acquired(CanvasSessionLock)
    case occupied(CanvasSessionOwner?)
}

/// 使用 macOS 的 `flock` 为每张画布建立跨进程独占锁。
///
/// 锁与文件描述符生命周期绑定：App 正常释放、崩溃或被强制退出后，系统都会自动释放锁，
/// 因此不会留下永久“死锁文件”。锁文件中的 JSON 只用于展示占用者信息，不承担锁语义。
final class CanvasSessionLock {
    private var fileDescriptor: Int32
    let lockURL: URL
    let owner: CanvasSessionOwner

    private init(fileDescriptor: Int32, lockURL: URL, owner: CanvasSessionOwner) {
        self.fileDescriptor = fileDescriptor
        self.lockURL = lockURL
        self.owner = owner
    }

    deinit {
        release()
    }

    /// 默认把锁放在 Application Support，与布局文件分开保存。
    static func defaultLockDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SpatialFolder/Locks", isDirectory: true)
    }

    /// 非阻塞地申请指定画布的写入权。
    ///
    /// - Returns: 成功时返回必须被会话持有的锁对象；失败时返回当前占用者元数据。
    static func acquire(
        canvasKey: String,
        directory: URL = defaultLockDirectory(),
        processID: Int32 = getpid(),
        appVersion: String
    ) throws -> CanvasSessionLockResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(canvasKey).appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return .occupied(readOwner(from: lockURL))
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(lockError))
        }

        let owner = CanvasSessionOwner(
            processID: processID,
            appVersion: appVersion,
            acquiredAt: Date()
        )
        do {
            try writeOwner(owner, to: descriptor)
            return .acquired(CanvasSessionLock(
                fileDescriptor: descriptor,
                lockURL: lockURL,
                owner: owner
            ))
        } catch {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw error
        }
    }

    /// 主动释放锁；重复调用是安全的。
    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    private static func writeOwner(_ owner: CanvasSessionOwner, to descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(owner)
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw posixError()
        }
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let address = buffer.baseAddress else { return 0 }
            return Darwin.write(descriptor, address, buffer.count)
        }
        guard written == data.count else { throw posixError() }
        _ = fsync(descriptor)
    }

    private static func readOwner(from url: URL) -> CanvasSessionOwner? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CanvasSessionOwner.self, from: data)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
