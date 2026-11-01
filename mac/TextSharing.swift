import SwiftUI
import AppKit

func boardLink(_ text:String) -> URL? {
    let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !value.contains(where:{$0.isWhitespace}), let url=URL(string:value),
          ["http","https"].contains(url.scheme?.lowercased() ?? ""), let host=url.host, !host.isEmpty else { return nil }
    return url
}

struct MiDropHomeView: View {
    @ObservedObject var model: ReceiverModel
    var settings: () -> Void
    var openWindow: () -> Void
    @ViewState private var page=0
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Picker("功能",selection:$page) { Text("公告板").tag(0); Text("文件").tag(1) }
                    .pickerStyle(.segmented).labelsHidden()
                Button(action:openWindow) { Image(systemName:"arrow.up.left.and.arrow.down.right") }.help("在窗口中打开公告板")
                Menu {
                    Button("设置",action:settings)
                    Divider()
                    Button("退出 MiDrop") { NSApp.terminate(nil) }
                } label:{Image(systemName:"gearshape")}.menuIndicator(.hidden).menuStyle(.borderlessButton).frame(width:18)
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,18).padding(.vertical,14)
            if page==0 { TextShareView(model:model) }
            else { PanelView(model:model,settings:settings,openTexts:{page=0}) }
        }.frame(width:380,height:560).background(Color(nsColor:.windowBackgroundColor))
            .onChange(of:model.pending.count) { if $0>0 { page=1 } }
    }
}

struct TextShareLauncher: View {
    @ObservedObject var model: ReceiverModel
    var action: () -> Void
    var body: some View {
        Button(action:action) {
            HStack(spacing:11) {
                Image(systemName:"note.text").font(.system(size:19)).foregroundStyle(mint)
                VStack(alignment:.leading,spacing:4) {
                    Text("共享公告板").font(.system(size:13,weight:.medium))
                    Text(model.textDraft.isEmpty ? "连接后，文字与链接随手可见" : model.textDraft).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength:4)
                Image(systemName:"chevron.right").font(.system(size:10)).foregroundStyle(.secondary)
            }.padding(14).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:15))
        }.buttonStyle(.plain)
    }
}

struct TextShareView: View {
    @ObservedObject var model: ReceiverModel
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:7) {
                    Text("共享公告板").font(.system(size:22,weight:.semibold))
                    Text("写在这里，连接的设备都会看到。").font(.system(size:12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName:"note.text").font(.system(size:23,weight:.light)).foregroundStyle(mint)
            }.padding(.horizontal,26).padding(.top,26).padding(.bottom,22)
            ZStack(alignment:.topLeading) {
                TextEditor(text:$model.textDraft).font(.system(size:16)).lineSpacing(7)
                    .scrollContentBackground(.hidden).padding(.horizontal,20).padding(.vertical,12)
                    .accessibilityLabel("共享公告板内容")
                if model.textDraft.isEmpty {
                    Text("记下一段文字，或粘贴一个链接…").font(.system(size:16)).foregroundStyle(.tertiary)
                        .padding(.horizontal,26).padding(.top,20).allowsHitTesting(false)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.primary.opacity(0.018))
            if model.boardConflict {
                HStack {
                    Text("继续编辑可同步此处草稿").font(.system(size:11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("使用另一端内容") { model.useRemoteBoard() }.buttonStyle(.plain).font(.system(size:11))
                }.padding(.horizontal,26).padding(.vertical,10)
            }
            HStack(spacing:16) {
                Circle().fill(model.boardConnected ? mint : Color.secondary.opacity(0.4)).frame(width:5,height:5)
                Text(model.boardStatus).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength:8)
                if let link=boardLink(model.textDraft) {
                    Button { NSWorkspace.shared.open(link) } label:{Image(systemName:"arrow.up.right.square")}.help("打开链接")
                }
                Button { model.replaceBoard(NSPasteboard.general.string(forType:.string) ?? "") } label:{Image(systemName:"doc.on.clipboard")}.help("粘贴到公告板")
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.textDraft,forType:.string) } label:{Image(systemName:"doc.on.doc")}.help("复制全部").disabled(model.textDraft.isEmpty)
                Button { model.replaceBoard("") } label:{Image(systemName:"trash")}.help("清空公告板").disabled(model.textDraft.isEmpty)
            }.font(.system(size:13)).buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.horizontal,26).padding(.vertical,18)
        }.frame(minWidth:360,minHeight:320).background(Color(nsColor:.windowBackgroundColor))
            .onChange(of:model.textDraft) { model.boardEdited($0) }
    }
}
