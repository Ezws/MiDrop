import Foundation
import Darwin

/// Shared by every installed/build copy, rather than keyed by executable path.
final class SingleInstanceLock {
    private var fd: Int32 = -1
    private(set) var isOwner = false
    private(set) var ownerPID: pid_t?

    init(directory: URL) throws {
        let file=directory.appendingPathComponent("receiver.lock")
        fd=open(file.path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        guard fd>=0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        if flock(fd,LOCK_EX|LOCK_NB) != 0 {
            let code=errno
            if code==EWOULDBLOCK || code==EAGAIN {
                ownerPID=(try? String(contentsOf:file,encoding:.utf8))
                    .flatMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }
                close(fd); fd = -1
                return
            }
            close(fd); fd = -1
            throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)
        }
        isOwner=true; ownerPID=getpid()
        let bytes=Array("\(getpid())\n".utf8)
        guard ftruncate(fd,0)==0, bytes.withUnsafeBytes({ Darwin.write(fd,$0.baseAddress,$0.count) })==bytes.count else {
            let code=errno; release()
            throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)
        }
    }

    func release() { if fd>=0 { close(fd); fd = -1 }; isOwner=false }
    deinit { release() }
}
