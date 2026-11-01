import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin
import OSLog

// Keep using the property wrapper with CLT SDKs that expose a newer State
// macro without shipping its SwiftUIMacros compiler plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

let mint = Color(red: 0.50, green: 0.80, blue: 0.66)

func brandMark(template: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: 32, height: 32))
    image.lockFocus()
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: 0, y: 32); context.scaleBy(x: 32/1024, y: -32/1024)
    context.setLineWidth(112); context.setLineCap(.round)
    let a = CGMutablePath(); a.move(to: CGPoint(x: 608,y: 276)); a.addCurve(to: CGPoint(x: 292,y: 380), control1: CGPoint(x: 492,y: 192), control2: CGPoint(x: 330,y: 244)); a.addCurve(to: CGPoint(x: 416,y: 628), control1: CGPoint(x: 262,y: 488), control2: CGPoint(x: 316,y: 588))
    context.addPath(a); context.setStrokeColor((template ? NSColor.black : NSColor(red: 0.35,green: 0.67,blue: 0.51,alpha: 1)).cgColor); context.strokePath()
    let b = CGMutablePath(); b.move(to: CGPoint(x: 416,y: 748)); b.addCurve(to: CGPoint(x: 732,y: 644), control1: CGPoint(x: 532,y: 832), control2: CGPoint(x: 694,y: 780)); b.addCurve(to: CGPoint(x: 608,y: 396), control1: CGPoint(x: 762,y: 536), control2: CGPoint(x: 708,y: 436))
    context.addPath(b); context.setStrokeColor((template ? NSColor.black : NSColor.secondaryLabelColor).cgColor); context.strokePath()
    image.unlockFocus(); image.isTemplate = template
    return image
}

struct Device: Identifiable, Equatable {
    let id: String
    let name: String
    let online: Bool
    let receiving: Bool
    let receivingText: Bool
    let supportsBoard: Bool
    init(_ d: [String: Any]) { id=d["id"] as? String ?? ""; name=d["name"] as? String ?? "手机"; online=d["online"] as? Bool ?? false; receiving=d["receiving"] as? Bool ?? false; receivingText=d["receiving_text"] as? Bool ?? false; supportsBoard=d["supports_board"] as? Bool ?? false }
}
struct Transfer: Identifiable, Equatable {
    let id, name, state, direction: String
    let bytes, size: Int64
    init(_ d: [String: Any]) { id=d["id"] as? String ?? ""; name=d["name"] as? String ?? "文件"; state=d["state"] as? String ?? ""; direction=d["direction"] as? String ?? ""; bytes=(d["bytes"] as? NSNumber)?.int64Value ?? 0; size=(d["size"] as? NSNumber)?.int64Value ?? 0 }
    var active: Bool { ["preparing","waiting","accepted","transferring"].contains(state) }
    var label: String { ["preparing":"正在准备","waiting":"等待手机接收","accepted":"手机已就绪","transferring":direction == "incoming" ? "正在接收" : "正在发送","completed":"已完成","cancelled":"已取消","expired":"请求已过期","rejected":"手机已拒绝","failed":"传输未完成"][state] ?? state }
}
struct TrustRequest: Identifiable, Equatable {
    let id, name: String
    init(_ d: [String: Any]) { id=d["id"] as? String ?? ""; name=d["name"] as? String ?? "手机" }
}

final class ReceiverModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var pending: [TrustRequest] = []
    @Published var transfers: [Transfer] = []
    @Published var recent: [[String: Any]] = []
    @Published var selected = ""
    @Published var ready = false
    @Published var message = "正在启动"
    @Published var error = ""
    @Published var addresses = ""
    @Published var fingerprint = ""
    @Published var sharedFiles: [URL] = []
    @Published var submittingSharedFiles = false
    @Published var textDraft = ""
    @Published var boardRevision = 0
    @Published var boardDirty = false
    @Published var boardSyncing = false
    @Published var boardConflict = false
    @Published var boardError = ""
    var trustArrived: (() -> Void)?
    var textArrived: (() -> Void)?
    private var boardRemoteText = ""
    private var boardBaseRevision = 0
    private var boardEditSequence = 0
    private var boardLastEditedText = ""
    private var boardLoaded = false
    private var boardRestoredDraft = false
    private var boardDebounce: DispatchWorkItem?
    private let previewMode: Bool
    var boardConnected: Bool { devices.contains { $0.online && $0.supportsBoard } }
    var boardStatus: String {
        if !boardError.isEmpty { return boardError }
        if boardConflict { return "另一端已更新，本机草稿已保留" }
        if !ready { return "正在连接…" }
        if boardDirty || boardSyncing { return "正在同步…" }
        return boardConnected ? "已连接 · 自动同步" : "已保存 · 等待设备连接"
    }
    let root: URL
    let destination: URL
    private var process: Process?
    private var service: NetService?
    private var stateMonitor: StateDirectoryMonitor?
    private var lastState: Data?
    private var serverPort = 0
    private var instanceLock: SingleInstanceLock?
    private(set) var alreadyRunning = false
    var primaryPID: pid_t? { instanceLock?.ownerPID }
    private var stopping = false
    private var seen = Set<String>()
    private let script = Bundle.main.resourceURL!.appendingPathComponent("receiver.py")
    private let work = DispatchQueue(label: "dev.midrop.control", qos: .userInitiated)

    init(preview: Bool = false, stateDirectory:URL?=nil, destinationDirectory:URL?=nil) {
        previewMode=preview
        root=stateDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MiDrop")
        destination=destinationDirectory ?? FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0].appendingPathComponent("MiDrop")
        if preview {
            devices=[Device(["id":"demo","name":"REDMI Turbo 4 Pro","online":true,"receiving":true,"receiving_text":true,"supports_board":true])]
            selected="demo"; ready=true; message="接收已就绪"
            recent=[["name":"周末的照片.heic","size":4862400,"direction":"incoming","time":Date().timeIntervalSince1970],["name":"设计参考.pdf","size":1284000,"direction":"outgoing","time":Date().timeIntervalSince1970-600]]
        } else {
            if let data=try? Data(contentsOf:root.appendingPathComponent("board-draft.json")),
               let draft=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
               let text=draft["text"] as? String, let base=draft["base_revision"] as? Int {
                textDraft=text; boardLastEditedText=text; boardBaseRevision=base; boardDirty=true
                boardConflict=draft["conflict"] as? Bool ?? false; boardRestoredDraft=true
            }
            start()
        }
    }
    func start() {
        let fm=FileManager.default
        do {
            try fm.createDirectory(at: root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            instanceLock=try SingleInstanceLock(directory:root)
            guard instanceLock?.isOwner==true else { alreadyRunning=true; message="MiDrop 已在运行"; return }
            let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            p.arguments=[script.path,"--state",root.path,"--destination",destination.path,"--parent-pid",String(getpid())]
            #if MIDROP_MODEL_TESTS
            p.arguments?.append(contentsOf:["--bind","127.0.0.1"])
            #endif
            let log=root.appendingPathComponent("receiver.log")
            fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])
            let handle=try FileHandle(forWritingTo:log)
            p.standardOutput=handle; p.standardError=handle
            p.terminationHandler={ [weak self] p in DispatchQueue.main.async { guard let self=self,!self.stopping else { return }; self.ready=false; self.message="接收服务已停止"; self.error="请在设置中查看日志，退出后重新打开 MiDrop。"; self.service?.stop() } }
            stateMonitor=try StateDirectoryMonitor(directory:root) { [weak self] in self?.refresh() }
            try p.run(); process=p
            refresh()
        } catch { message="启动失败"; self.error=error.localizedDescription }
    }
    func refresh() {
        guard let p=process,p.isRunning,
              let data=try? Data(contentsOf:root.appendingPathComponent("state.json")),
              data != lastState,
              let d=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              d["pid"] as? Int == Int(p.processIdentifier),let port=d["port"] as? Int,port>0 else { return }
        lastState=data
        if !ready { ready=true }
        if message != "接收已就绪" { message="接收已就绪" }
        let nextDevices=(d["trusted_devices"] as? [[String:Any]] ?? []).map(Device.init)
        let nextPending=(d["pending_pairs"] as? [[String:Any]] ?? []).map(TrustRequest.init)
        let nextTransfers=(d["transfers"] as? [[String:Any]] ?? []).map(Transfer.init)
        let nextRecent=d["recent"] as? [[String:Any]] ?? []
        if let board=d["board"] as? [String:Any] { applyBoard(board) }
        let nextFingerprint=d["fingerprint"] as? String ?? ""
        if devices != nextDevices { devices=nextDevices }
        if pending != nextPending { pending=nextPending }
        if transfers != nextTransfers { transfers=nextTransfers }
        if !NSArray(array:recent).isEqual(to:nextRecent) { recent=nextRecent }
        if fingerprint != nextFingerprint { fingerprint=nextFingerprint }
        if serverPort != port { serverPort=port; refreshAddresses() }
        if selected.isEmpty || !devices.contains(where:{$0.id==selected}) { selected=devices.first(where:{$0.receiving})?.id ?? devices.first?.id ?? "" }
        #if !MIDROP_MODEL_TESTS
        if service==nil {
            let s=NetService(domain:"local.",type:"_midrop._tcp.",name:Host.current().localizedName ?? "我的 Mac",port:Int32(port))
            s.setTXTRecord(NetService.data(fromTXTRecord:["v":Data("2".utf8),"id":Data((d["server_id"] as? String ?? "").utf8)]))
            s.publish(); service=s
        }
        #endif
        let new=Set(pending.map(\.id)).subtracting(seen)
        seen.formUnion(pending.map(\.id))
        if !new.isEmpty { trustArrived?() }
        if boardDirty && !boardSyncing && !boardConflict { scheduleBoardSave() }
    }
    func refreshAddresses() {
        guard serverPort>0 else { return }
        let next=Self.localAddresses().map { "\($0):\(serverPort)" }.joined(separator:"\n")
        if addresses != next { addresses=next }
    }
    func command(_ payload: [String:Any], resultHandler: (([String:Any]) -> Void)? = nil, completion: ((Bool) -> Void)? = nil) {
        work.async { [weak self] in
            guard let self=self else { return }
            do {
                let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/python3"); p.arguments=[self.script.path,"--control",self.root.appendingPathComponent("control.sock").path]
                let input=Pipe(),output=Pipe(); p.standardInput=input; p.standardOutput=output; p.standardError=FileHandle.nullDevice
                try p.run()
                try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:payload)); try input.fileHandleForWriting.close()
                let response=output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                let result=(try? JSONSerialization.jsonObject(with:response)) as? [String:Any]
                DispatchQueue.main.async {
                    self.error=result?["error"] as? String ?? (p.terminationStatus==0 && result != nil ? "" : "接收服务暂时不可用")
                    self.refresh(); resultHandler?(result ?? ["error":self.error]); completion?(self.error.isEmpty)
                }
            } catch { DispatchQueue.main.async { self.error=error.localizedDescription; resultHandler?(["error":self.error]); completion?(false) } }
        }
    }
    func send(_ urls:[URL]) {
        guard !urls.isEmpty else { return }
        guard devices.contains(where:{$0.id==selected && $0.receiving}) else { error="请在手机打开 MiDrop，或开启后台接收。"; return }
        command(["action":"queue","device_id":selected,"paths":urls.map(\.path)])
    }
    private func applyBoard(_ board:[String:Any]) {
        guard let revision=board["revision"] as? Int, let text=board["text"] as? String, revision>=boardRevision else { return }
        let firstLoad = !boardLoaded
        let changed=boardLoaded && revision>boardRevision && text != boardRemoteText
        boardRevision=revision; boardRemoteText=text; boardLoaded=true
        if firstLoad && !boardRestoredDraft { boardBaseRevision=revision; if boardDirty { persistBoardDraft() } }
        if !boardDirty { textDraft=text; boardBaseRevision=revision }
        if changed && !boardSyncing { textArrived?() }
    }
    func replaceBoard(_ text:String) { textDraft=text; boardEdited(text) }
    func boardEdited(_ text:String) {
        guard !previewMode else { return }
        if !boardDirty && text==boardRemoteText { return }
        if boardDirty && text==boardLastEditedText && !boardConflict { return }
        if boardConflict { boardBaseRevision=boardRevision }
        boardLastEditedText=text; boardDirty=true; boardConflict=false; boardError=""; boardEditSequence+=1
        persistBoardDraft()
        scheduleBoardSave()
    }
    private func persistBoardDraft() {
        let file=root.appendingPathComponent("board-draft.json")
        do {
            if boardDirty {
                let data=try JSONSerialization.data(withJSONObject:["text":textDraft,"base_revision":boardBaseRevision,"conflict":boardConflict])
                try data.write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            } else if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
        } catch { boardError="本地草稿暂未保存，请检查可用空间" }
    }
    private func scheduleBoardSave() {
        boardDebounce?.cancel()
        let job=DispatchWorkItem { [weak self] in self?.saveBoard() }; boardDebounce=job
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6,execute:job)
    }
    private func saveBoard() {
        guard ready, boardDirty, !boardSyncing, !boardConflict else { return }
        guard textDraft.utf8.count<=65536 else { boardError="内容不能超过 64 KiB"; return }
        let draft=textDraft, sequence=boardEditSequence
        boardSyncing=true
        command(["action":"update_board","text":draft,"base_revision":boardBaseRevision],resultHandler:{ [weak self] response in
            guard let self else { return }; self.boardSyncing=false
            if let board=response["board"] as? [String:Any] { self.applyBoard(board) }
            if response["conflict"] as? Bool == true {
                self.boardConflict=true; self.boardBaseRevision=self.boardRevision; self.boardError=""; self.persistBoardDraft(); return
            }
            guard response["ok"] as? Bool == true else {
                self.boardError=response["error"] as? String ?? "暂时未同步，内容已保留"; return
            }
            if self.boardEditSequence==sequence && self.textDraft==draft {
                self.boardDirty=false; self.textDraft=self.boardRemoteText; self.boardBaseRevision=self.boardRevision
            } else {
                self.boardBaseRevision=(response["board"] as? [String:Any])?["revision"] as? Int ?? self.boardRevision
                self.scheduleBoardSave()
            }
            self.persistBoardDraft()
        })
    }
    func useRemoteBoard() {
        boardDebounce?.cancel(); boardEditSequence+=1; boardDirty=false; boardConflict=false; boardError=""
        textDraft=boardRemoteText; boardLastEditedText=boardRemoteText; boardBaseRevision=boardRevision
        persistBoardDraft()
    }
    func receiveSharedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard urls.allSatisfy(\.isFileURL), sharedFiles.count + urls.count <= 1000 else {
            error="每次最多共享 1000 个本地文件。"; return
        }
        sharedFiles.append(contentsOf: urls)
        error=""
    }
    func sendSharedFiles() {
        guard !sharedFiles.isEmpty, !submittingSharedFiles, ready else { return }
        guard devices.contains(where:{$0.id==selected && $0.receiving}) else {
            error="请在手机打开 MiDrop，或开启后台接收。"; return
        }
        let batch=sharedFiles
        submittingSharedFiles=true
        command(["action":"queue","device_id":selected,"paths":batch.map(\.path)],completion:{ [weak self] success in
            guard let self else { return }
            self.submittingSharedFiles=false
            if success { self.sharedFiles.removeFirst(batch.count) }
        })
    }
    func chooseFiles() {
        let panel=NSOpenPanel(); panel.canChooseFiles=true; panel.canChooseDirectories=false; panel.allowsMultipleSelection=true; panel.prompt="发送到手机"
        if panel.runModal() == .OK { send(panel.urls) }
    }
    func reveal(_ item:[String:Any]) {
        guard let path=item["path"] as? String,!path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])
    }
    func revoke(_ device:Device) {
        let a=NSAlert(); a.messageText="取消对\(device.name)的信任？"; a.informativeText="之后需要在这台 Mac 上重新允许连接。"; a.addButton(withTitle:"取消信任"); a.addButton(withTitle:"返回")
        if a.runModal() == .alertFirstButtonReturn { command(["action":"revoke","id":device.id]) }
    }
    func stop() {
        stopping=true; boardDebounce?.cancel(); stateMonitor?.cancel(); stateMonitor=nil; service?.stop()
        if let p=process,p.isRunning { p.terminate() }
        instanceLock?.release()
    }
    static func localAddresses()->[String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head)==0 else { return [] }; defer { freeifaddrs(head) }
        var result:[String]=[]; var current=head
        while let p=current {
            let i=p.pointee; current=i.ifa_next
            guard let address=i.ifa_addr,address.pointee.sa_family==UInt8(AF_INET),String(cString:i.ifa_name).hasPrefix("en"),i.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var buffer=[CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(address,socklen_t(address.pointee.sa_len),&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST)==0 { result.append(String(cString:buffer)) }
        }
        return result.sorted()
    }
}

struct SharedFilesView: View {
    @ObservedObject var model: ReceiverModel
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("待发送 · \(model.sharedFiles.count) 个文件").font(.system(size:13,weight:.medium))
            Text(model.sharedFiles.prefix(3).map(\.lastPathComponent).joined(separator:"\n"))
                .font(.system(size:11)).foregroundStyle(.secondary).lineLimit(3)
            Text("选择上方手机后发送").font(.system(size:11)).foregroundStyle(.secondary)
            HStack {
                Button("取消") { model.sharedFiles=[] }.disabled(model.submittingSharedFiles)
                Spacer()
                Button(model.submittingSharedFiles ? "正在提交…" : "发送到手机") { model.sendSharedFiles() }
                    .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(Color.black.opacity(0.8))
                    .disabled(!model.ready || model.submittingSharedFiles || !model.devices.contains(where:{$0.id==model.selected && $0.receiving}))
            }
        }.padding(14).background(mint.opacity(0.12),in:RoundedRectangle(cornerRadius:15))
    }
}

struct PanelView: View {
    @ObservedObject var model:ReceiverModel
    var settings:()->Void = {}
    var openTexts:()->Void = {}
    @ViewState private var dropTarget=false
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:9) {
                Image(nsImage:brandMark(template:true)).renderingMode(.template).resizable().foregroundStyle(mint).frame(width:29,height:29)
                Text("MiDrop").font(.system(size:18,weight:.semibold))
                Spacer()
                Button(action:settings) { Image(systemName:"gearshape").font(.system(size:14)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("设置")
            }.padding(.horizontal,20).padding(.top,18).padding(.bottom,14)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    HStack(spacing:6) { Circle().fill(model.ready ? mint : .orange).frame(width:6,height:6); Text(model.message).font(.system(size:12)).foregroundStyle(.secondary) }
                    ForEach(model.pending) { request in
                        VStack(alignment:.leading,spacing:12) {
                            Text(request.name).font(.system(size:14,weight:.medium)).lineLimit(2)
                            Text("想与你的 Mac 建立连接").font(.system(size:12)).foregroundStyle(.secondary)
                            HStack { Button("拒绝") { model.command(["action":"approve","id":request.id,"allow":false]) }; Spacer(); Button("允许并记住") { model.command(["action":"approve","id":request.id,"allow":true]) }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(Color.black.opacity(0.8)) }
                        }.padding(14).background(mint.opacity(0.12),in:RoundedRectangle(cornerRadius:16))
                    }
                    VStack(alignment:.leading,spacing:10) {
                        section("设备")
                        if model.devices.isEmpty {
                            HStack(spacing:12) {
                                Image(systemName:"iphone.gen3").font(.system(size:25,weight:.light)).foregroundStyle(.secondary)
                                VStack(alignment:.leading,spacing:4) { Text("等待你的手机").font(.system(size:13,weight:.medium)); Text("在手机 MiDrop 中选择这台 Mac").font(.system(size:11)).foregroundStyle(.secondary) }
                            }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:15))
                        }
                        ForEach(model.devices) { device in
                            Button { model.selected=device.id } label: {
                                HStack(spacing:12) {
                                    Image(systemName:"iphone.gen3").font(.system(size:27,weight:.light)).frame(width:29)
                                    VStack(alignment:.leading,spacing:5) { Text(device.name).font(.system(size:13,weight:.medium)).lineLimit(1); Text(device.receiving ? "在线 · 可以接收" : device.online ? "在线 · 接收已暂停" : "离线").font(.system(size:11)).foregroundStyle(.secondary) }
                                    Spacer(minLength:2)
                                    Circle().fill(device.receiving ? mint : Color.secondary.opacity(0.35)).frame(width:6,height:6)
                                }.padding(13).background(model.selected==device.id ? mint.opacity(0.10) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:15))
                                    .overlay(RoundedRectangle(cornerRadius:15).strokeBorder(model.selected==device.id ? mint.opacity(0.6) : .clear,lineWidth:1))
                            }.buttonStyle(.plain).contextMenu { Button("取消信任") { model.revoke(device) } }
                        }
                    }
                    TextShareLauncher(model:model,action:openTexts)
                    if !model.sharedFiles.isEmpty {
                        SharedFilesView(model:model)
                    }
                    Button { model.chooseFiles() } label: {
                        VStack(spacing:9) {
                            Image(systemName:"plus").font(.system(size:18,weight:.light)).foregroundStyle(.secondary)
                            Text("拖入文件，发送到手机").font(.system(size:12,weight:.medium))
                        }.frame(maxWidth:.infinity).frame(height:82)
                            .background(dropTarget ? mint.opacity(0.16) : Color.primary.opacity(0.015),in:RoundedRectangle(cornerRadius:15))
                            .overlay(RoundedRectangle(cornerRadius:15).strokeBorder(dropTarget ? mint : Color.secondary.opacity(0.25),style:StrokeStyle(lineWidth:1,dash:[4,4])))
                    }.buttonStyle(.plain).onDrop(of:[UTType.fileURL.identifier],isTargeted:$dropTarget) { providers in
                        let group=DispatchGroup(); let lock=NSLock(); var urls:[URL]=[]
                        for p in providers {
                            group.enter(); p.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { item,_ in
                                let url=(item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation:$0,relativeTo:nil) }
                                if let url=url { lock.lock(); urls.append(url); lock.unlock() }; group.leave()
                            }
                        }
                        group.notify(queue:.main) { model.send(urls) }; return true
                    }
                    let active=model.transfers.filter(\.active)
                    if !active.isEmpty {
                        VStack(alignment:.leading,spacing:12) {
                            section("正在传递")
                            ForEach(active) { t in
                                VStack(alignment:.leading,spacing:8) {
                                    HStack { Image(systemName:t.direction=="incoming" ? "arrow.down.left" : "arrow.up.right").font(.system(size:11)); Text(t.label).font(.system(size:12,weight:.medium)); Spacer(); Button { model.command(["action":"cancel","id":t.id]) } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                                    Text(t.name).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    if t.state=="transferring" { ProgressView(value:Double(t.bytes),total:Double(max(t.size,1))).tint(mint).controlSize(.small) }
                                    else { ProgressView().controlSize(.mini) }
                                }.padding(12).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:13))
                            }
                        }
                    }
                    if !model.recent.isEmpty {
                        VStack(alignment:.leading,spacing:10) {
                            section("最近文件")
                            ForEach(Array(model.recent.prefix(3).enumerated()),id:\.offset) { _,item in
                                Button { model.reveal(item) } label: {
                                    HStack(spacing:10) {
                                        Image(systemName:item["direction"] as? String == "outgoing" ? "arrow.up.right" : "arrow.down.left").font(.system(size:11)).foregroundStyle(.secondary).frame(width:16)
                                        Text(item["name"] as? String ?? "文件").font(.system(size:12)).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength:2)
                                        Text(ByteCountFormatter.string(fromByteCount:(item["size"] as? NSNumber)?.int64Value ?? 0,countStyle:.file)).font(.system(size:10)).foregroundStyle(.secondary)
                                    }.padding(.vertical,3)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if let t=model.transfers.last(where:{!$0.active && $0.state != "completed"}) { Text(t.label+" · "+t.name).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2) }
                    if !model.error.isEmpty {
                        HStack(alignment:.top) { Text(model.error).font(.system(size:11)).foregroundStyle(.secondary); Spacer(); Button { model.error="" } label:{Image(systemName:"xmark").font(.system(size:9))}.buttonStyle(.plain) }
                    }
                }.padding(.horizontal,20).padding(.bottom,16)
            }
            Divider().padding(.horizontal,20)
            HStack {
                Button { NSWorkspace.shared.open(model.destination) } label:{Label("接收文件夹",systemImage:"folder").font(.system(size:11))}.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Menu { Button("设置",action:settings); Divider(); Button("退出 MiDrop") { NSApp.terminate(nil) } } label:{Image(systemName:"ellipsis").font(.system(size:13))}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:24)
            }.padding(.horizontal,20).padding(.vertical,14)
        }.frame(width:360,height:480).background(Color(nsColor:.windowBackgroundColor))
    }
    private func section(_ text:String)->some View { Text(text).font(.system(size:11,weight:.medium)).foregroundStyle(.secondary) }
}

struct SettingsView: View {
    @ObservedObject var model:ReceiverModel
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Image(nsImage:brandMark(template:true)).renderingMode(.template).resizable().foregroundStyle(mint).frame(width:30,height:30); Text("MiDrop 设置").font(.title2.weight(.semibold)); Spacer(); Text("0.4.0").foregroundStyle(.secondary).font(.caption) }
            GroupBox("信任的设备") {
                VStack(alignment:.leading,spacing:12) {
                    if model.devices.isEmpty { Text("还没有连接设备").foregroundStyle(.secondary) }
                    ForEach(model.devices) { d in HStack { Text(d.name).lineLimit(1); Spacer(); Text(d.online ? "在线" : "离线").foregroundStyle(.secondary); Button("取消信任") { model.revoke(d) } } }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
            }
            GroupBox("连接详情") {
                VStack(alignment:.leading,spacing:10) {
                    Text("备用地址").font(.caption).foregroundStyle(.secondary)
                    Text(model.addresses.isEmpty ? "请连接局域网" : model.addresses).font(.system(.callout,design:.monospaced)).textSelection(.enabled)
                    Text("安全指纹").font(.caption).foregroundStyle(.secondary)
                    Text(model.fingerprint).font(.system(size:10,design:.monospaced)).textSelection(.enabled).lineLimit(3)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
            }
            HStack { VStack(alignment:.leading,spacing:5) { Text("接收位置").font(.caption).foregroundStyle(.secondary); Text("下载 / MiDrop") }; Spacer(); Button("打开文件夹") { NSWorkspace.shared.open(model.destination) } }
            HStack { Text("首次允许后自动重连，局域网 HTTPS 加密。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("查看日志") { NSWorkspace.shared.open(model.root.appendingPathComponent("receiver.log")) } }
            if !model.error.isEmpty { Text(model.error).foregroundStyle(.secondary).font(.caption) }
            Spacer(minLength:0)
        }.padding(24).frame(width:480,height:480)
    }
}

final class AppDelegate:NSObject,NSApplicationDelegate {
    var model:ReceiverModel!
    var item:NSStatusItem!
    let popover=NSPopover()
    var settingsWindow:NSWindow?
    var shareWindow:NSWindow?
    var textWindow:NSWindow?
    private var openedFiles: [URL] = []
    private var primaryApplication: NSRunningApplication?
    private var forwarding: DispatchWorkItem?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let args=CommandLine.arguments
        if let index=args.firstIndex(of:"--preview"),index+1<args.count {
            renderPreview(to:args[index+1],dark:args.contains("--dark")); return
        }
        if let index=args.firstIndex(of:"--preview-text"),index+1<args.count {
            renderPreview(to:args[index+1],dark:args.contains("--dark"),text:true); return
        }
        model=ReceiverModel()
        if model.alreadyRunning {
            let others=NSRunningApplication.runningApplications(withBundleIdentifier:Bundle.main.bundleIdentifier ?? "dev.midrop.mac")
                .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
            primaryApplication=others.first(where:{$0.processIdentifier==model.primaryPID}) ?? others.first
            forwardToPrimary(); return
        }
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image=brandMark(template:true); item.button?.image?.size=NSSize(width:21,height:21)
        item.button?.toolTip="MiDrop"; item.button?.target=self; item.button?.action=#selector(toggle)
        popover.behavior = .transient; popover.contentSize=NSSize(width:380,height:560)
        popover.contentViewController=NSHostingController(rootView:MiDropHomeView(model:model,settings:{ [weak self] in self?.showSettings() },openWindow:{ [weak self] in self?.showTexts() }))
        model.trustArrived={ [weak self] in self?.show() }
        model.textArrived={ [weak self] in self?.item.length=NSStatusItem.variableLength; self?.item.button?.imagePosition = .imageLeft; self?.item.button?.title=" •"; self?.item.button?.toolTip="MiDrop · 公告板已更新" }
        if !openedFiles.isEmpty { _=handleOpenedURLs(openedFiles); openedFiles=[] }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in
            guard let self else { return }
            if !self.model.textDraft.isEmpty { self.showTexts() }
            else if self.model.sharedFiles.isEmpty { self.show() } else { self.showSharedFiles() }
        }
    }
    private func forwardToPrimary() {
        forwarding?.cancel()
        let action=DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let app=self.primaryApplication, let url=app.bundleURL else { NSApp.terminate(nil); return }
            let configuration=NSWorkspace.OpenConfiguration()
            configuration.activates=true; configuration.createsNewApplicationInstance=false
            configuration.allowsRunningApplicationSubstitution=false
            let completion: (NSRunningApplication?,Error?) -> Void = { _,_ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            if self.openedFiles.isEmpty {
                NSWorkspace.shared.openApplication(at:url,configuration:configuration,completionHandler:completion)
            } else {
                NSWorkspace.shared.open(self.openedFiles,withApplicationAt:url,configuration:configuration,completionHandler:completion)
            }
        }
        forwarding=action
        // Launch-time document/URL events can arrive just after didFinishLaunching.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:action)
    }
    @objc func toggle() { if popover.isShown { popover.performClose(nil) } else { show() } }
    func show() { guard let button=item?.button else { return }; item.button?.title=""; item.length=NSStatusItem.squareLength; item.button?.toolTip="MiDrop"; NSApp.activate(ignoringOtherApps:true); popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY) }
    func showTexts() {
        popover.performClose(nil); item.button?.title=""; item.length=NSStatusItem.squareLength; item.button?.toolTip="MiDrop"
        if textWindow==nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:600),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title="MiDrop · 共享公告板"; window.contentMinSize=NSSize(width:380,height:360)
            window.contentView=NSHostingView(rootView:TextShareView(model:model)); window.isReleasedWhenClosed=false; window.center(); textWindow=window
        }
        textWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func showSettings() {
        model.refreshAddresses()
        popover.performClose(nil)
        if settingsWindow==nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:480),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            w.title="MiDrop 设置"; w.contentView=NSHostingView(rootView:SettingsView(model:model)); w.isReleasedWhenClosed=false; w.center(); settingsWindow=w
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool {
        if model?.alreadyRunning==true { forwardToPrimary(); return false }
        show(); return true
    }
    func application(_ application:NSApplication,open urls:[URL]) {
        Logger(subsystem:"dev.midrop.mac",category:"share").notice("Received \(urls.count) shared file URLs")
        guard model != nil else { openedFiles.append(contentsOf:urls); return }
        if model.alreadyRunning { openedFiles.append(contentsOf:urls); forwardToPrimary(); return }
        let text=handleOpenedURLs(urls)
        // A regular window stays visible when Finder finishes closing its
        // share sheet, and gives offline devices time to reconnect.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in if text { self?.showTexts() } else { self?.showSharedFiles() } }
    }
    private func handleOpenedURLs(_ urls:[URL]) -> Bool {
        let files=urls.filter(\.isFileURL)
        if !files.isEmpty { model.receiveSharedFiles(files) }
        var receivedText=false
        for url in urls where url.scheme=="midrop" && url.host=="share-text" {
            guard let text=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="text"})?.value,
                  !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count<=65536 else {
                model.error="共享文字为空或超过 64 KiB"; continue
            }
            model.replaceBoard(text); receivedText=true
        }
        return receivedText
    }
    func showSharedFiles() {
        popover.performClose(nil)
        if shareWindow==nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:360,height:480),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title="MiDrop · 发送文件"
            window.contentView=NSHostingView(rootView:PanelView(model:model,settings:{ [weak self] in self?.showSettings() },openTexts:{ [weak self] in self?.showTexts() }))
            window.isReleasedWhenClosed=false; window.center(); shareWindow=window
        }
        shareWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationWillTerminate(_ notification:Notification) { model?.stop() }
    func renderPreview(to path:String,dark:Bool,text:Bool=false) {
        model=ReceiverModel(preview:true)
        if text {
            model.textDraft="周末出行\n\n车票、地址和临时记下的事，放在这里。\n手机和电脑打开就是同一份。\n\nhttps://example.com/trip"
        }
        let content=text ? AnyView(TextShareView(model:model)) : AnyView(PanelView(model:model))
        let host=NSHostingView(rootView:content.environment(\.colorScheme,dark ? .dark : .light))
        host.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:text ? 480 : 360,height:text ? 600 : 480),styleMask:.borderless,backing:.buffered,defer:false)
        w.contentView=host; w.setFrameOrigin(NSPoint(x:-10000,y:-10000)); w.orderFront(nil)
        settingsWindow=w
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5) {
            host.layoutSubtreeIfNeeded()
            if let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:rep)
                if let data=rep.representation(using:.png,properties:[:]) { try? data.write(to:URL(fileURLWithPath:path)) }
            }
            NSApp.terminate(nil)
        }
    }
}
#if !MIDROP_MODEL_TESTS
@main
struct MiDropApp {
    static func main() {
        let app=NSApplication.shared
        let delegate=AppDelegate(); app.delegate=delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
