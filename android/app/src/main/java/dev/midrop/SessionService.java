package dev.midrop;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.*;
import android.provider.MediaStore;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.net.ssl.HttpsURLConnection;
import org.json.*;

/** Phone-initiated, pinned connection: no inbound listening port on Android. */
public class SessionService extends Service {
    private final Set<String> handled=ConcurrentHashMap.newKeySet();
    static final AtomicBoolean RECEIVING=new AtomicBoolean(false);
    static volatile SessionService instance;
    private static final int CONNECTION=81, PROGRESS=82;
    private final ExecutorService downloads=Executors.newSingleThreadExecutor();
    private volatile boolean running,cancelReceive,refreshRequested;
    private volatile HttpsURLConnection pollConnection,downloadConnection;
    private Thread poller;
    private String currentOffer="";
    private Discovery.Listener discovery;
    private final Handler main=new Handler(Looper.getMainLooper());
    private NotificationManager manager;

    private boolean canReceive() {
        return canReceiveText()
            && (Build.VERSION.SDK_INT>=29 || checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)==PackageManager.PERMISSION_GRANTED);
    }
    private boolean canReceiveText() { return MainActivity.visible || Protocol.prefs(this).getBoolean("background_receive",true); }
    static void start(Context c) {
        if (!Protocol.prefs(c).getString("token","").isEmpty() && (MainActivity.visible || Protocol.prefs(c).getBoolean("background_receive",true)))
            c.startForegroundService(new Intent(c,SessionService.class).setAction("START"));
    }
    static void visibilityChanged() {
        SessionService s=instance;
        if (s!=null && s.pollConnection!=null) { s.refreshRequested=true; s.pollConnection.disconnect(); }
    }
    private PendingIntent open() { return PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE); }
    private PendingIntent action(String action,String id) {
        Intent i=new Intent(this,SessionService.class).setAction(action).putExtra("id",id).setData(Uri.parse("midrop://action/"+action+"/"+id));
        return PendingIntent.getService(this,0,i,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
    }
    private Notification connectionNotice(String text) {
        return new Notification.Builder(this,"connection").setSmallIcon(R.drawable.ic_status).setContentTitle("MiDrop")
            .setContentText(text).setContentIntent(open()).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(new Notification.Action.Builder(null,"暂停接收",action("STOP","")).build()).build();
    }
    @Override public void onCreate() {
        super.onCreate(); instance=this;
        manager=(NotificationManager)getSystemService(NOTIFICATION_SERVICE);
        manager.cancel(83);
        manager.createNotificationChannel(new NotificationChannel("connection","后台连接",NotificationManager.IMPORTANCE_LOW));
        // Remove obsolete per-batch confirmation notifications on upgrade.
        manager.deleteNotificationChannel("incoming");
        manager.createNotificationChannel(new NotificationChannel("receive","接收进度",NotificationManager.IMPORTANCE_LOW));
        for (String uri:new HashSet<>(Protocol.prefs(this).getStringSet("partial_uris",Collections.emptySet()))) {
            try { getContentResolver().delete(Uri.parse(uri),null,null); } catch (Exception ignored) {}
        }
        Protocol.prefs(this).edit().remove("partial_uris").apply();
        for (String path:new HashSet<>(Protocol.prefs(this).getStringSet("partial_paths",Collections.emptySet()))) {
            File f=new File(path);
            if (f.getName().startsWith(".midrop-") && f.getParentFile()!=null && f.getParentFile().getName().equals("MiDrop")) f.delete();
        }
        Protocol.prefs(this).edit().remove("partial_paths").apply();
        discovery=devices -> {
            String saved=Protocol.serverId(this);
            for (Discovery.Device d:devices) if (!saved.isEmpty() && saved.equals(d.id)) {
                String old=Protocol.prefs(this).getString("address","");
                if (!old.equals(d.address)) {
                    Protocol.prefs(this).edit().putString("address",d.address).apply();
                    if (pollConnection!=null) { refreshRequested=true; pollConnection.disconnect(); }
                }
            }
        };
        Discovery.get(this).add(discovery);
    }
    @Override public int onStartCommand(Intent intent,int flags,int startId) {
        if (intent!=null && "STOP".equals(intent.getAction())) {
            Protocol.prefs(this).edit().putBoolean("background_receive",false).apply(); shutdown(); return START_NOT_STICKY;
        }
        if (Protocol.prefs(this).getString("token","").isEmpty()) { stopSelf(); return START_NOT_STICKY; }
        startForeground(CONNECTION,connectionNotice("正在连接你的 Mac"));
        if (!running) {
            running=true; poller=new Thread(this::poll,"MiDrop-session"); poller.start();
        }
        if (intent!=null && "CANCEL".equals(intent.getAction())) {
            cancelReceive=true;
            if (downloadConnection!=null) downloadConnection.disconnect();
        }
        return START_NOT_STICKY;
    }
    private void poll() {
        long lastNotice=0;
        while (running) {
            HttpsURLConnection c=null;
            try {
                BoardStore.ensureServer(this);
                syncBoardDraft();
                boolean ready=canReceive();
                JSONObject body=new JSONObject().put("receiving",ready).put("name",Protocol.deviceName(this))
                    .put("board_support",true).put("board_revision",BoardStore.revision(this));
                c=Protocol.authenticated(this,"/events"); pollConnection=c;
                JSONObject result=Protocol.post(c,body);
                if (!running) break;
                Protocol.prefs(this).edit().putString("device_id",result.getString("device_id")).putString("server_id",result.getString("server_id"))
                    .putBoolean("connected",true).putString("connection_error","").apply();
                JSONObject board=result.optJSONObject("board");
                if (board!=null) BoardStore.receive(this,board);
                else Protocol.prefs(this).edit().putBoolean("board_capable",false).apply();
                JSONArray offers=result.getJSONArray("offers");
                for (int i=0;i<offers.length();i++) {
                    JSONObject offer=offers.getJSONObject(i); String id=offer.getString("id");
                    // Accept one batch at a time. Other offers remain on the Mac
                    // and are picked up automatically after this receive ends.
                    if (canReceive() && !handled.contains(id) && RECEIVING.compareAndSet(false,true)) {
                        downloads.execute(() -> receiveAutomatically(offer));
                        break;
                    }
                }
                if (SystemClock.elapsedRealtime()-lastNotice>15000) {
                    manager.notify(CONNECTION,connectionNotice("已连接 · 公告板自动同步"));
                    lastNotice=SystemClock.elapsedRealtime();
                }
                // Waiting offers make /events return immediately. Avoid a hot
                // polling loop while another batch is already downloading.
                if (offers.length()>0 && RECEIVING.get()) Thread.sleep(500);
            } catch (Exception error) {
                if (!running) break;
                if (refreshRequested) { refreshRequested=false; continue; }
                Protocol.prefs(this).edit().putBoolean("connected",false).putString("connection_error",error instanceof Protocol.ApiException && ((Protocol.ApiException)error).code==401?"此设备的信任已撤销，请重新连接":"正在寻找你的 Mac").apply();
                try { Thread.sleep(2500); } catch (InterruptedException e) { break; }
            } finally { if (c!=null) c.disconnect(); pollConnection=null; }
        }
    }
    private void syncBoardDraft() throws Exception {
        BoardStore.Draft draft;
        try { draft=BoardStore.pending(this); }
        catch (IOException error) { Protocol.prefs(this).edit().putString("board_error",error.getMessage()).apply(); return; }
        if (draft==null) return;
        try {
            JSONObject response=Protocol.post(this,"/board",new JSONObject().put("text",draft.text).put("base_revision",draft.base));
            BoardStore.acknowledged(this,draft,response.getJSONObject("board"));
        } catch (Protocol.ApiException error) {
            if (error.code==409 && error.payload.optJSONObject("board")!=null) {
                BoardStore.conflict(this,draft,error.payload.getJSONObject("board")); return;
            }
            Protocol.prefs(this).edit().putString("board_error",error.getMessage()).apply();
            throw error;
        }
    }
    private void receiveAutomatically(JSONObject offer) {
        String id=offer.optString("id");
        try {
            // Recheck after scheduling in case the user paused or disconnected.
            if (!running || !canReceive()) return;
            Protocol.post(this,"/offers/"+id+"/decision",new JSONObject().put("decision","accept"));
            handled.add(id);
            receive(offer);
        } catch (Exception error) {
            Protocol.progress(this,"incoming","failed",offer.optString("name"),0,offer.optLong("size"),"无法开始接收，请在 Mac 重新发送");
        } finally {
            RECEIVING.set(false);
            visibilityChanged();
        }
    }
    private void progress(JSONObject offer,long done,long size,String state,String message) {
        Protocol.progress(this,"incoming",state,offer.optString("name"),done,size,message);
        Notification.Builder b=new Notification.Builder(this,"receive").setSmallIcon(R.drawable.ic_status).setContentTitle("MiDrop · "+message)
            .setContentText(offer.optString("name")).setContentIntent(open()).setOnlyAlertOnce(true).setOngoing(state.equals("transferring"));
        if (state.equals("transferring")) b.setProgress(100,size==0?0:(int)(done*100/size),false)
            .addAction(new Notification.Action.Builder(null,"取消",action("CANCEL",offer.optString("id"))).build());
        manager.notify(PROGRESS,b.build());
    }
    private void receive(JSONObject offer) {
        String id=offer.optString("id"); currentOffer=id; cancelReceive=false;
        long total=offer.optLong("size"),done=0,last=0;
        int count=0;
        PowerManager.WakeLock wake=((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"MiDrop:receive");
        wake.acquire(60*60*1000L);
        try {
            JSONArray files=offer.getJSONArray("files");
            progress(offer,0,total,"transferring","正在接收");
            for (int i=0;i<files.length();i++) {
                JSONObject file=files.getJSONObject(i);
                String name=safeName(file.getString("name")),mime=file.optString("mime","application/octet-stream");
                long expectedSize=file.getLong("size");
                if (expectedSize<0 || expectedSize>20L*1024*1024*1024) throw new IOException("文件大小无效");
                checkCancelled();
                Uri target=null; File partial=null,committed=null; boolean published=false;
                try {
                    FileOutputStream output;
                    if (Build.VERSION.SDK_INT>=29) {
                        ContentValues values=new ContentValues();
                        values.put(MediaStore.Downloads.DISPLAY_NAME,name); values.put(MediaStore.Downloads.MIME_TYPE,mime);
                        values.put(MediaStore.Downloads.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/MiDrop"); values.put(MediaStore.Downloads.IS_PENDING,1);
                        target=getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values);
                        if (target==null) throw new IOException("无法创建接收文件");
                        track("partial_uris",target.toString(),true);
                        ParcelFileDescriptor fd=getContentResolver().openFileDescriptor(target,"w");
                        if (fd==null) throw new IOException("无法打开接收文件");
                        output=new ParcelFileDescriptor.AutoCloseOutputStream(fd);
                    } else {
                        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)!=PackageManager.PERMISSION_GRANTED) throw new IOException("请先允许保存文件");
                        File folder=new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),"MiDrop");
                        if (!folder.exists() && !folder.mkdirs()) throw new IOException("无法创建接收文件夹");
                        partial=File.createTempFile(".midrop-",".part",folder); track("partial_paths",partial.getAbsolutePath(),true);
                        output=new FileOutputStream(partial);
                    }
                    MessageDigest digest=MessageDigest.getInstance("SHA-256"); long bytes=0;
                    try (FileOutputStream out=output) {
                        downloadConnection=Protocol.authenticated(this,"/files/"+id+"/"+file.getString("id"));
                        int status=downloadConnection.getResponseCode();
                        if (status!=200) throw new IOException("传输已取消或源文件发生变化");
                        if (downloadConnection.getContentLengthLong()!=expectedSize) throw new IOException("文件长度不一致");
                        try (InputStream in=downloadConnection.getInputStream()) {
                            byte[] buffer=new byte[256*1024]; int n;
                            while ((n=in.read(buffer))!=-1) {
                                checkCancelled(); bytes+=n;
                                if (bytes>expectedSize) throw new IOException("文件长度异常");
                                out.write(buffer,0,n); digest.update(buffer,0,n);
                                long now=SystemClock.elapsedRealtime();
                                if (now-last>400) { progress(offer,done+bytes,total,"transferring","正在接收"); last=now; }
                            }
                        }
                        out.flush(); out.getFD().sync();
                    }
                    checkCancelled();
                    if (bytes!=expectedSize || !Protocol.hex(digest.digest()).equals(file.getString("sha256"))) throw new IOException("文件未接收完整或校验失败");
                    if (Build.VERSION.SDK_INT>=29) {
                        ContentValues complete=new ContentValues(); complete.put(MediaStore.Downloads.IS_PENDING,0);
                        if (getContentResolver().update(target,complete,null,null)!=1) throw new IOException("无法保存文件");
                        track("partial_uris",target.toString(),false);
                        try (Cursor c=getContentResolver().query(target,new String[]{MediaStore.Downloads.DISPLAY_NAME},null,null,null)) { if (c!=null && c.moveToFirst()) name=c.getString(0); } catch (Exception ignored) {}
                    } else {
                        File folder=partial.getParentFile();
                        String stem=name,ext=""; int dot=name.lastIndexOf('.'); if (dot>0) { stem=name.substring(0,dot); ext=name.substring(dot); }
                        for (int n=0;n<10000;n++) {
                            File candidate=new File(folder,n==0?name:stem+" ("+n+")"+ext);
                            if (candidate.createNewFile()) { committed=candidate; break; }
                        }
                        if (committed==null || !partial.renameTo(committed)) { if (committed!=null) committed.delete(); throw new IOException("无法保存文件"); }
                        track("partial_paths",partial.getAbsolutePath(),false);
                        name=committed.getName(); target=Uri.fromFile(committed);
                    }
                    published=true; done+=bytes; count++;
                    Protocol.prefs(this).edit().putString("last_received_name",name).putString("last_received_uri",target.toString()).putString("last_received_mime",mime).apply();
                    Protocol.post(this,"/offers/"+id+"/ack",new JSONObject().put("file_id",file.getString("id")).put("sha256",file.getString("sha256")));
                } finally {
                    if (downloadConnection!=null) { downloadConnection.disconnect(); downloadConnection=null; }
                    if (!published && target!=null && Build.VERSION.SDK_INT>=29) { try { getContentResolver().delete(target,null,null); } catch (Exception ignored) {} track("partial_uris",target.toString(),false); }
                    if (partial!=null) { partial.delete(); track("partial_paths",partial.getAbsolutePath(),false); }
                }
            }
            progress(offer,done,total,"completed","已保存 "+count+" 个文件到 Download/MiDrop");
        } catch (Exception error) {
            try { Protocol.post(this,"/offers/"+id+"/cancel",new JSONObject().put("failed",!cancelReceive)); } catch (Exception ignored) {}
            progress(offer,done,total,cancelReceive?"cancelled":"failed",(cancelReceive?"已取消": "接收未完成："+error.getMessage())+" · 已保存 "+count+" 个文件");
        } finally {
            if (wake.isHeld()) wake.release();
            currentOffer="";
            main.post(() -> { if (!MainActivity.visible && !Protocol.prefs(this).getBoolean("background_receive",true)) shutdown(); });
        }
    }
    private void checkCancelled() throws IOException { if (cancelReceive || !running) throw new IOException("已取消"); }
    static String safeName(String name) { name=name.replace('\\','/'); name=name.substring(name.lastIndexOf('/')+1).replaceAll("[\\p{Cntrl}:]","").replaceAll("^\\.+","").trim(); return name.isEmpty()?"未命名文件":name; }
    private synchronized void track(String field,String item,boolean add) {
        Set<String> values=new HashSet<>(Protocol.prefs(this).getStringSet(field,Collections.emptySet()));
        if (add) values.add(item); else values.remove(item);
        Protocol.prefs(this).edit().putStringSet(field,values).commit();
    }
    private void shutdown() {
        running=false; cancelReceive=true;
        if (pollConnection!=null) pollConnection.disconnect(); if (downloadConnection!=null) downloadConnection.disconnect();
        if (poller!=null) poller.interrupt();
        new Thread(() -> { try { Protocol.post(this,"/events",new JSONObject().put("receiving",false).put("wait",false)
            .put("board_support",false)); } catch (Exception ignored) {} }).start();
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf();
    }
    @Override public void onDestroy() {
        running=false; cancelReceive=true;
        if (pollConnection!=null) pollConnection.disconnect(); if (downloadConnection!=null) downloadConnection.disconnect();
        if (poller!=null) poller.interrupt();
        Discovery.get(this).remove(discovery);
        Protocol.prefs(this).edit().putBoolean("connected",false).apply();
        instance=null; downloads.shutdownNow(); super.onDestroy();
    }
    @Override public IBinder onBind(Intent i) { return null; }
}
