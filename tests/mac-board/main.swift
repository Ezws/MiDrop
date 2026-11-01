import Foundation
import Darwin

func check(_ condition:@autoclosure ()->Bool,_ message:String) { if !condition() { fputs("FAIL: \(message)\n",stderr); exit(1) } }
func waitFor(_ condition:()->Bool,seconds:Double=8) {
    let until=Date().addingTimeInterval(seconds)
    while !condition() && Date()<until { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
    check(condition(),"timed out")
}
let directory=URL(fileURLWithPath:"/private/tmp/mdboard-\(UUID().uuidString.prefix(8))")
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
let model=ReceiverModel(stateDirectory:directory.appendingPathComponent("state"),destinationDirectory:directory.appendingPathComponent("files"))
func snapshot()->[String:Any] { ((try? Data(contentsOf:model.root.appendingPathComponent("state.json"))).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any]) ?? [:] }
func board()->[String:Any] { snapshot()["board"] as? [String:Any] ?? [:] }
waitFor { model.ready }
model.replaceBoard("Mac 自动同步\nhttps://example.com/?a=1&b=猫")
waitFor { !model.boardDirty && board()["text"] as? String==model.textDraft }
check(model.boardRevision==1,"editor did not publish automatically")
let expectedRevision=model.boardRevision
model.replaceBoard("本机未提交的草稿")
var remoteDone=false
model.command(["action":"update_board","text":"另一端的新内容","base_revision":expectedRevision],resultHandler:{ response in remoteDone=response["ok"] as? Bool==true })
waitFor { remoteDone && model.boardConflict }
check(model.textDraft=="本机未提交的草稿","remote update destroyed the local draft")
check(board()["text"] as? String=="另一端的新内容","stale draft overwrote newer board")
model.useRemoteBoard()
check(model.textDraft=="另一端的新内容" && !model.boardDirty,"use remote content failed")
model.replaceBoard("")
waitFor { !model.boardDirty && board()["text"] as? String=="" }
let receiverPID=snapshot()["pid"] as? Int ?? 0
model.replaceBoard("退出前最后一次编辑，也要保留")
model.stop()
waitFor({ receiverPID==0 || kill(pid_t(receiverPID),0) != 0 },seconds:5)
let recovered=ReceiverModel(stateDirectory:model.root,destinationDirectory:model.destination)
waitFor { recovered.ready && !recovered.boardDirty }
check(recovered.textDraft=="退出前最后一次编辑，也要保留","quit before debounce lost the local draft")
let recoveredPID=snapshot()["pid"] as? Int ?? 0
recovered.stop()
waitFor({ recoveredPID==0 || kill(pid_t(recoveredPID),0) != 0 },seconds:5)
try FileManager.default.removeItem(at:directory)
print("PASS: Mac autosync, conflict protects draft, remote restore, clear and draft recovery after quit")
