package dev.midrop.qa;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.accessibility.AccessibilityNodeInfo;

/** Exercise the real board editor without a send button or a device picker. */
public final class TextInstrumentation extends Instrumentation {
    private Bundle arguments;
    @Override public void onCreate(Bundle args) { arguments=args; start(); }
    private AccessibilityNodeInfo findClass(AccessibilityNodeInfo node,String name) {
        if (node==null) return null;
        if (name.contentEquals(node.getClassName())) return node;
        for (int i=0;i<node.getChildCount();i++) { AccessibilityNodeInfo result=findClass(node.getChild(i),name); if (result!=null) return result; }
        return null;
    }
    private AccessibilityNodeInfo text(String value) {
        AccessibilityNodeInfo root=getUiAutomation().getRootInActiveWindow(); if (root==null) return null;
        for (AccessibilityNodeInfo node:root.findAccessibilityNodeInfosByText(value)) if (value.contentEquals(node.getText())) return node;
        return null;
    }
    private void click(String title) throws Exception {
        long until=SystemClock.elapsedRealtime()+5000;
        while (SystemClock.elapsedRealtime()<until) {
            AccessibilityNodeInfo node=text(title);
            if (node!=null && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) { waitForIdleSync(); return; }
            Thread.sleep(100);
        }
        throw new AssertionError("Button missing: "+title);
    }
    @Override public void onStart() {
        Bundle result=new Bundle();
        try {
            Context c=getTargetContext(); String mode=arguments.getString("mode"),value=arguments.getString("text","");
            Intent intent=new Intent().setClassName(c,"dev.midrop.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            if ("share".equals(mode)) intent.setAction(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT,value);
            startActivitySync(intent); waitForIdleSync();
            AccessibilityNodeInfo editor=null; long until=SystemClock.elapsedRealtime()+5000;
            while (editor==null && SystemClock.elapsedRealtime()<until) { editor=findClass(getUiAutomation().getRootInActiveWindow(),"android.widget.EditText"); if (editor==null) Thread.sleep(100); }
            if (editor==null) throw new AssertionError("Shared board editor missing");
            if (text("发送")!=null || text("最近文字")!=null || text("你的设备")!=null)
                throw new AssertionError("Board still contains messaging/history/device selection UI");
            if ("inspect".equals(mode)) {
                until=SystemClock.elapsedRealtime()+10000;
                while (!value.contentEquals(editor.getText()) && SystemClock.elapsedRealtime()<until) { Thread.sleep(150); editor=findClass(getUiAutomation().getRootInActiveWindow(),"android.widget.EditText"); }
                if (!value.contentEquals(editor.getText())) throw new AssertionError("Editor did not show shared content");
                click("复制"); final String[] copied=new String[1];
                runOnMainSync(() -> { ClipboardManager clipboard=(ClipboardManager)c.getSystemService(Context.CLIPBOARD_SERVICE); copied[0]=clipboard.getPrimaryClip().getItemAt(0).getText().toString(); });
                if (!value.equals(copied[0])) throw new AssertionError("Copied content changed");
            } else {
                if ("clear".equals(mode)) { click("清空"); value=""; }
                else if ("remote".equals(mode)) click("使用另一端内容");
                else if (!"share".equals(mode)) {
                    Bundle input=new Bundle(); input.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,value);
                    if (!editor.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,input)) throw new AssertionError("Unable to edit board");
                }
                until=SystemClock.elapsedRealtime()+30000; boolean done=false;
                while (SystemClock.elapsedRealtime()<until) {
                    SharedPreferences p=c.getSharedPreferences("midrop",0);
                    if ("conflict".equals(mode)) done=p.getBoolean("board_conflict",false) && value.equals(p.getString("board_draft",""));
                    else if ("offline".equals(mode)) done=p.getBoolean("board_dirty",false) && value.equals(p.getString("board_draft",""));
                    else done=!p.getBoolean("board_dirty",false) && value.equals(p.getString("board_draft","")) && value.equals(p.getString("board_text",""));
                    if (done) break; Thread.sleep(100);
                }
                if (!done) throw new AssertionError("Board state did not converge: "+mode);
                c.getSharedPreferences("midrop",0).edit().putBoolean("qa_flushed",true).commit();
            }
            result.putString("result","PASS: "+mode); finish(Activity.RESULT_OK,result);
        } catch (Throwable error) { result.putString("error",error.toString()); finish(Activity.RESULT_CANCELED,result); }
    }
}
