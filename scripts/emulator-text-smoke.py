#!/usr/bin/env python3
"""Shared-board integration checks on disposable AVD 5556; never touches a real phone."""
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
smoke=load('smoke',ROOT/'scripts/emulator-smoke.py'); backend=load('receiver',ROOT/'mac/receiver.py')
adb,wait=smoke.adb,smoke.wait
APP='dev.midrop'

def main():
    assert 'emulator-5556\tdevice' in subprocess.check_output([str(smoke.ADB),'devices'],text=True)
    runtime=ROOT/'.build/board'; runtime.mkdir(parents=True,exist_ok=True)
    run=Path(tempfile.mkdtemp(prefix='qa-',dir=runtime))
    receiver=backend.Receiver(run/'state',run/'received')
    server=backend.Server(('127.0.0.1',0),backend.Handler); server.receiver=receiver; receiver.port=server.server_port
    token=receiver.add_device('Board QA phone'); owner=backend.token_hash(token); receiver.publish()
    def serve():
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start(); return thread
    thread=serve()
    try:
        adb('root'); adb('wait-for-device'); assert adb('shell','getprop','ro.build.version.sdk')=='36'
        adb('shell','setprop','debug.hwui.drawing_enabled','1')
        adb('install','-r',str(ROOT/'dist/MiDrop-android.apk')); adb('install','-r',str(ROOT/'.build/android-instrumentation/qa.apk'))
        adb('shell','pm','grant',APP,'android.permission.POST_NOTIFICATIONS'); adb('shell','am','force-stop',APP); adb('logcat','-c')
        remote='/data/user/0/'+APP+'/shared_prefs'; uid=adb('shell','stat','-c','%u','/data/user/0/'+APP)
        prefs=ET.Element('map')
        for key,value in {'token':token,'pin':receiver.fingerprint,'address':'10.0.2.2:'+str(receiver.port),'server_id':receiver.server_id,'name':'QA Mac','client_id':'board-qa'}.items():
            ET.SubElement(prefs,'string',{'name':key}).text=value
        ET.SubElement(prefs,'boolean',{'name':'background_receive','value':'true'})
        path=run/'prefs.xml'; ET.ElementTree(prefs).write(path,encoding='utf-8',xml_declaration=True)
        adb('shell','mkdir','-p',remote); adb('push',str(path),remote+'/midrop.xml'); adb('shell','rm','-f',remote+'/midrop.xml.bak')
        adb('shell','chown','-R',uid+':'+uid,remote); adb('shell','restorecon','-R',remote)
        def preferences():
            tree=ET.fromstring(adb('shell','cat',remote+'/midrop.xml'))
            return {n.get('name'):n.text or n.get('value','') for n in tree}
        def start():
            seen=receiver.sessions.get(owner,{}).get('seen',0)
            adb('shell','am','start','-W','-n',APP+'/.MainActivity')
            wait(lambda: receiver.sessions.get(owner,{}).get('board_support') and receiver.sessions[owner]['seen']>seen,30)
        def publish(text):
            result=receiver.control({'action':'update_board','text':text,'base_revision':receiver.board['revision']})
            assert result.get('ok'),result
            wait(lambda: preferences().get('board_text')==text,20)
        def instrument(mode,text=''):
            command=shlex.join(['am','instrument','-w','-e','mode',mode,'-e','text',text,'dev.midrop.qa/.TextInstrumentation'])
            output=adb('shell',command); assert 'PASS: '+mode in output,output
        def capture(name):
            time.sleep(.9); (ROOT/'previews'/name).write_bytes(adb('exec-out','screencap','-p',binary=True))
        start()
        rows_before=adb('shell','content','query','--uri','content://media/external/downloads','--projection','_id')
        text='  共享便签 🐈\n中文、空格和换行保持原样。\nhttps://example.com/?a=1&b=猫\n '
        publish(text); instrument('inspect',text)
        typed='在手机直接编辑\n不用发送，也不用选择设备。'
        instrument('edit',typed); assert receiver.board['text']==typed
        link='https://example.com/trip?a=1&b=猫'
        instrument('share',link); assert receiver.board['text']==link
        # A second paired client sees the same document, without being selected.
        other=receiver.add_device('Second QA phone')
        assert receiver.events(backend.token_hash(other),False,wait=0,board_support=True,board_revision=-1)[1]['board']['text']==link
        start(); adb('shell','am','start','-a','android.intent.action.MAIN','-c','android.intent.category.HOME')
        publish('后台连接也能看到同一份公告板')
        adb('shell','pm','revoke',APP,'android.permission.POST_NOTIFICATIONS')
        start(); adb('shell','am','start','-a','android.intent.action.MAIN','-c','android.intent.category.HOME')
        publish('关闭通知后，公告板仍自动同步')
        adb('shell','pm','grant',APP,'android.permission.POST_NOTIFICATIONS')
        # Keep an offline local draft, then reconnect after another client edits.
        server.shutdown(); thread.join()
        offline='离线写下的草稿，不应被覆盖'
        instrument('offline',offline)
        revision=receiver.board['revision']
        receiver.update_board('另一端在离线期间更新了内容',revision)
        thread=serve(); start()
        wait(lambda: preferences().get('board_conflict')=='true',20)
        assert preferences()['board_draft']==offline and receiver.board['text']=='另一端在离线期间更新了内容'
        instrument('remote','另一端在离线期间更新了内容')
        instrument('clear'); assert receiver.board['text']==''
        start()
        sample='周末出行\n\n车票、地址和临时记下的事，放在这里。\n手机和电脑打开就是同一份。\n\nhttps://example.com/trip'
        publish(sample); capture('android-board-light.png')
        adb('shell','cmd','uimode','night','yes'); time.sleep(1); capture('android-board-dark.png')
        adb('shell','cmd','uimode','night','no')
        rows_after=adb('shell','content','query','--uri','content://media/external/downloads','--projection','_id')
        assert rows_before==rows_after and receiver.recent==[] and receiver.texts==[]
        assert list(receiver.destination.iterdir())==[]
        log=adb('logcat','-d','-s','AndroidRuntime:E'); assert 'FATAL EXCEPTION' not in log,log
        report={'android_api':36,'passed':['board replaces send/history/device-selection UI',
            'PC edits visible on phone; phone edits automatically visible on PC',
            'same board visible to all paired clients without selecting a recipient',
            'Unicode, whitespace and newlines preserved; explicit clipboard copy',
            'Android system text sharing edits the board without a send step',
            'background sync and notification permission denied',
            'offline draft retained; stale write cannot overwrite remote updates',
            'use remote content and synchronized clear','no message history, downloaded text files or MediaStore rows created'],
            'not_verified':['physical REDMI / HyperOS']}
        (ROOT/'previews/board-qa-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(report,ensure_ascii=False,indent=2))
    finally:
        adb('shell','am','force-stop',APP); server.shutdown(); server.server_close(); thread.join()

if __name__=='__main__': main()
