package dev.midrop;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import java.io.IOException;
import org.json.*;

/** A single shared document plus a protected local draft, never a message log. */
final class BoardStore {
    static final int MAX_BYTES=64*1024;
    static String draft(Context c) { SharedPreferences p=Protocol.prefs(c); return p.getString("board_draft",p.getString("board_text","")); }
    static long revision(Context c) { return Protocol.prefs(c).getLong("board_revision",0); }
    static synchronized void ensureServer(Context c) {
        SharedPreferences p=Protocol.prefs(c); String server=Protocol.serverId(c),old=p.getString("board_server_id","");
        if (server.isEmpty() || server.equals(old)) return;
        SharedPreferences.Editor e=p.edit().putString("board_server_id",server).putBoolean("board_capable",false);
        if (!old.isEmpty()) {
            boolean draft=p.getBoolean("board_dirty",false);
            e.putLong("board_revision",0).putLong("board_base",0).putString("board_text","")
                .putBoolean("board_conflict",draft).putString("board_error",draft?"已切换电脑，旧草稿未自动同步":"");
            if (!draft) e.putString("board_draft","");
        }
        e.commit();
    }
    static void validate(String text) throws IOException { if (text==null || text.getBytes("UTF-8").length>MAX_BYTES) throw new IOException("公告板内容不能超过 64 KiB"); }
    static synchronized void edit(Context c,String text) {
        SharedPreferences p=Protocol.prefs(c);
        if (text.equals(draft(c))) return;
        SharedPreferences.Editor e=p.edit().putString("board_draft",text).putBoolean("board_dirty",true)
            .putBoolean("board_conflict",false).putString("board_error","")
            .putLong("board_edit",p.getLong("board_edit",0)+1).putLong("board_edited_at",SystemClock.elapsedRealtime());
        if (!p.getBoolean("board_dirty",false) || p.getBoolean("board_conflict",false)) e.putLong("board_base",revision(c));
        e.apply();
    }
    static synchronized void receive(Context c,JSONObject board) throws Exception {
        SharedPreferences p=Protocol.prefs(c); long revision=board.getLong("revision");
        if (revision<revision(c)) return;
        String text=board.getString("text"); validate(text);
        SharedPreferences.Editor e=p.edit().putLong("board_revision",revision).putString("board_text",text).putBoolean("board_capable",true);
        if (!p.getBoolean("board_dirty",false)) e.putString("board_draft",text).putLong("board_base",revision);
        if (!e.commit()) throw new IOException("无法保存公告板");
    }
    static final class Draft {
        final String text,server; final long edit,base;
        Draft(String text,long edit,long base,String server) { this.text=text; this.edit=edit; this.base=base; this.server=server; }
    }
    static synchronized Draft pending(Context c) throws IOException {
        SharedPreferences p=Protocol.prefs(c);
        if (!p.getBoolean("board_dirty",false) || p.getBoolean("board_conflict",false) || !p.getBoolean("board_capable",false)) return null;
        long age=SystemClock.elapsedRealtime()-p.getLong("board_edited_at",0);
        if (age>=0 && age<600) return null;
        String text=draft(c); validate(text);
        return new Draft(text,p.getLong("board_edit",0),p.getLong("board_base",revision(c)),Protocol.serverId(c));
    }
    static synchronized void acknowledged(Context c,Draft sent,JSONObject board) throws Exception {
        if (!sent.server.equals(Protocol.serverId(c))) return;
        receive(c,board); SharedPreferences p=Protocol.prefs(c);
        SharedPreferences.Editor e=p.edit().putString("board_error","");
        if (p.getLong("board_edit",0)==sent.edit && draft(c).equals(sent.text)) {
            e.putBoolean("board_dirty",false).putBoolean("board_conflict",false)
                .putString("board_draft",p.getString("board_text",sent.text)).putLong("board_base",revision(c));
        } else e.putLong("board_base",board.getLong("revision"));
        if (!e.commit()) throw new IOException("无法保存公告板");
    }
    static synchronized void conflict(Context c,Draft sent,JSONObject board) throws Exception {
        if (!sent.server.equals(Protocol.serverId(c))) return;
        receive(c,board);
        Protocol.prefs(c).edit().putBoolean("board_conflict",true).putString("board_error","").putLong("board_base",revision(c)).commit();
    }
    static synchronized void useRemote(Context c) {
        SharedPreferences p=Protocol.prefs(c);
        p.edit().putString("board_draft",p.getString("board_text",""))
            .putBoolean("board_dirty",false).putBoolean("board_conflict",false).putString("board_error","")
            .putLong("board_base",revision(c)).putLong("board_edit",p.getLong("board_edit",0)+1).apply();
    }
    static String status(Context c) {
        SharedPreferences p=Protocol.prefs(c);
        if (!p.getString("board_error","").isEmpty()) return p.getString("board_error","");
        if (p.getBoolean("board_conflict",false)) return "另一端已更新，本机草稿已保留";
        if (!p.getBoolean("connected",false)) return p.getBoolean("board_dirty",false)?"连接后自动同步 · 草稿已保留":"等待电脑连接";
        if (!p.getBoolean("board_capable",false)) return "请更新电脑端 MiDrop 以使用公告板";
        return p.getBoolean("board_dirty",false)?"正在同步…":"已连接 · 自动同步";
    }
}
