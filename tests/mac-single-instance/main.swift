import Foundation
import Darwin

func check(_ condition: @autoclosure () -> Bool, _ message:String) {
    if !condition() { fputs("FAIL: \(message)\n",stderr); exit(1) }
}

if CommandLine.arguments.count>1 {
    let lock=try SingleInstanceLock(directory:URL(fileURLWithPath:CommandLine.arguments[1]))
    if CommandLine.arguments[2]=="occupied" {
        check(!lock.isOwner,"second process acquired the active lock")
        check(lock.ownerPID==Int32(CommandLine.arguments[3]),"owner PID did not identify the first process")
    } else { check(lock.isOwner,"lock was not released after the first owner closed it") }
    exit(0)
}
let directory=FileManager.default.temporaryDirectory.appendingPathComponent("midrop-instance-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:directory) }
let lock=try SingleInstanceLock(directory:directory)
check(lock.isOwner,"first process did not acquire lock")
func probe(_ expectation:String) throws {
    let child=Process(); child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
    child.arguments=[directory.path,expectation,String(getpid())]
    try child.run(); child.waitUntilExit(); check(child.terminationStatus==0,"child process failed")
}
try probe("occupied")
lock.release()
try probe("available")
print("PASS: cross-process exclusion, owner PID and release")
