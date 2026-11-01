import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import socket
import ssl
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import quote

spec = importlib.util.spec_from_file_location("receiver", Path(__file__).parents[1] / "mac/receiver.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReceiverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.receiver = module.Receiver(cls.root / "state", cls.root / "received")
        cls.server = module.Server(("127.0.0.1", 0), module.Handler)
        cls.server.receiver = cls.receiver
        cls.port = cls.server.server_port
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temp.cleanup()

    def setUp(self):
        self.receiver.attempts = []
        self.receiver.renew_pairing(revoke=True)
        _, data = self.request("/pair", json.dumps({"code": self.receiver.code}).encode())
        self.token = data["token"]

    def request(self, path, body=b"", headers=None, method="POST"):
        context = ssl._create_unverified_context()
        client = http.client.HTTPSConnection("127.0.0.1", self.port, context=context, timeout=4)
        client.request(method, path, body, headers or {})
        response = client.getresponse()
        data = json.loads(response.read())
        status = response.status
        client.close()
        return status, data

    def upload(self, name, body=b"hello", checksum=None):
        return self.request("/upload?name=" + quote(name), body, {
            "Authorization": "Bearer " + self.token,
            "X-Content-SHA256": checksum or hashlib.sha256(body).hexdigest()})

    def test_binary_roundtrip_unicode_and_hash(self):
        body = bytes(range(256)) * 4096
        status, data = self.upload("照片-原图.heic", body)
        self.assertEqual(status, 201)
        self.assertEqual((self.receiver.destination / data["name"]).read_bytes(), body)
        self.assertEqual(data["sha256"], hashlib.sha256(body).hexdigest())

    def test_empty_file(self):
        status, data = self.upload("empty.txt", b"")
        self.assertEqual(status, 201)
        self.assertEqual((self.receiver.destination / data["name"]).stat().st_size, 0)

    def test_duplicates_never_overwrite(self):
        _, first = self.upload("same.txt", b"first")
        _, second = self.upload("same.txt", b"second")
        self.assertNotEqual(first["name"], second["name"])
        self.assertEqual((self.receiver.destination / first["name"]).read_bytes(), b"first")

    def test_path_traversal_is_flattened(self):
        status, data = self.upload("../../outside.txt")
        self.assertEqual(status, 201)
        self.assertEqual(data["name"], "outside.txt")
        self.assertFalse((self.root / "outside.txt").exists())
        self.assertEqual(module.safe_name("..\\secret.txt"), "secret.txt")

    def test_checksum_mismatch_discards_partial(self):
        status, _ = self.upload("corrupt.txt", checksum="0" * 64)
        self.assertEqual(status, 422)
        self.assertFalse((self.receiver.destination / "corrupt.txt").exists())
        self.assertEqual(list(self.receiver.destination.glob(".midrop-*.part")), [])

    def test_authentication_required_and_revocation(self):
        self.assertEqual(self.request("/upload?name=bad", b"test")[0], 401)
        self.receiver.renew_pairing(revoke=True)
        self.assertEqual(self.upload("revoked.txt")[0], 401)

    def test_pairing_expiry_and_single_use(self):
        # The successful pair in setUp consumes the code.
        code = self.receiver.code
        self.assertEqual(self.request("/pair", json.dumps({"code": code}).encode())[0], 403)
        self.receiver.renew_pairing()
        self.receiver.expires = 0
        self.assertEqual(self.request("/pair", json.dumps({"code": self.receiver.code}).encode())[0], 403)

    def test_pair_rate_limit(self):
        self.receiver.attempts = []
        for _ in range(5):
            self.assertEqual(self.request("/pair", b'{"code":"invalid"}')[0], 403)
        self.assertEqual(self.request("/pair", b'{"code":"invalid"}')[0], 429)

    def test_size_limit(self):
        self.assertEqual(self.request("/upload", b"", {"Content-Length": str(module.MAX_FILE + 1)})[0], 413)

    def test_persisted_device_and_certificate(self):
        restored = module.Receiver(self.receiver.root, self.receiver.destination)
        self.assertEqual(restored.fingerprint, self.receiver.fingerprint)
        self.assertTrue(restored.authorized(self.token))
        self.assertEqual((self.receiver.root / "devices.json").stat().st_mode & 0o777, 0o600)

    def test_concurrent_same_name(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda n: self.upload("concurrent.bin", bytes([n]) * 1024), range(4)))
        self.assertTrue(all(status == 201 for status, _ in results))
        names = [data["name"] for _, data in results]
        self.assertEqual(len(set(names)), 4)

    def test_incomplete_stream_not_committed(self):
        connection = ssl._create_unverified_context().wrap_socket(socket.socket(), server_hostname="localhost")
        connection.connect(("127.0.0.1", self.port))
        connection.sendall(("POST /upload?name=interrupted.txt HTTP/1.1\r\nHost: localhost\r\n"
                            "Authorization: Bearer " + self.token + "\r\nContent-Length: 100\r\n"
                            "X-Content-SHA256: " + "0" * 64 + "\r\n\r\npartial").encode())
        connection.close()
        # Wait until the worker finishes cleanup, bounded to one second.
        import time
        for _ in range(100):
            time.sleep(0.01)
            if not list(self.receiver.destination.glob(".midrop-*.part")):
                break
        self.assertFalse((self.receiver.destination / "interrupted.txt").exists())

    def test_tls_certificate_matches_displayed_pin(self):
        context = ssl._create_unverified_context()
        with context.wrap_socket(socket.socket(), server_hostname="localhost") as connection:
            connection.connect(("127.0.0.1", self.port))
            pin = hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest()
        self.assertEqual(pin, self.receiver.fingerprint)


    def auth_headers(self):
        return {"Authorization": "Bearer " + self.token}

    def post_json(self, path, data):
        return self.request(path, json.dumps(data).encode(), self.auth_headers())

    def outgoing(self, body=b"original bytes", name="send.bin"):
        import time
        key = module.token_hash(self.token)
        self.receiver.events(key, True, wait=0)
        source = self.root / name
        source.write_bytes(body)
        jid = self.receiver.queue(key[:24], [str(source)])["id"]
        for _ in range(300):
            if self.receiver.jobs[jid]["state"] != "preparing":
                break
            time.sleep(.01)
        self.assertEqual(self.receiver.jobs[jid]["state"], "waiting")
        return jid, self.receiver.jobs[jid]["files"][0]

    def binary(self, jid, fid, token=None):
        connection = http.client.HTTPSConnection("127.0.0.1", self.port, context=ssl._create_unverified_context(), timeout=4)
        connection.request("GET", "/files/" + jid + "/" + fid, headers={"Authorization": "Bearer " + (token or self.token)})
        response = connection.getresponse()
        status, body = response.status, response.read()
        connection.close()
        return status, body

    def test_trust_requires_local_approval(self):
        status, ticket = self.request("/trust/request", b'{"name":"My phone","client_id":"unique"}')
        self.assertEqual(status, 200)
        self.assertEqual(self.post_json("/trust/status", ticket)[1]["state"], "pending")
        self.assertEqual(self.post_json("/approve", {"id":ticket["request_id"], "allow":True})[0], 404)
        self.assertNotIn("token", self.post_json("/trust/status", ticket)[1])
        path = str(self.root / "c.sock")
        server = module.ControlServer(path, module.ControlHandler)
        server.receiver = self.receiver
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.assertEqual(Path(path).stat().st_mode & 0o777, 0o600)
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(path)
                client.sendall(json.dumps({"action":"approve", "id":ticket["request_id"], "allow":True}).encode()+b"\n")
                self.assertTrue(json.loads(client.makefile("rb").readline())["ok"])
            result = self.post_json("/trust/status", ticket)[1]
            self.assertEqual(result["state"], "approved")
            self.assertTrue(self.receiver.authorized(result["token"]))
            self.assertNotIn(result["token"], (self.receiver.root / "state.json").read_text())
        finally:
            server.shutdown(); server.server_close(); thread.join(); Path(path).unlink()

    def test_trust_reject_expiry_and_ticket_isolation(self):
        _, ticket = self.request("/trust/request", b'{"name":"No"}')
        bad = dict(ticket, ticket="wrong")
        self.assertEqual(self.post_json("/trust/status", bad)[0], 404)
        self.receiver.approve(ticket["request_id"], False)
        self.assertEqual(self.post_json("/trust/status", ticket)[1]["state"], "rejected")
        _, second = self.request("/trust/request", b'{"name":"Expired"}')
        self.receiver.pair_requests[second["request_id"]]["expires"] = __import__("time").time()-1
        self.assertEqual(self.post_json("/trust/status", second)[1]["state"], "expired")
        with self.assertRaises(ValueError): self.receiver.approve(second["request_id"], True)

    def test_reverse_requires_consent_and_roundtrip(self):
        payload = bytes(range(256))*4096
        jid, file = self.outgoing(payload, "反向照片.heic")
        self.assertEqual(self.binary(jid, file["id"])[0], 403)
        offers = self.post_json("/events", {"receiving":True})[1]["offers"]
        self.assertIn(jid, [x["id"] for x in offers])
        self.assertEqual(self.post_json("/offers/"+jid+"/decision", {"decision":"accept"})[0], 200)
        self.assertEqual(self.binary(jid, file["id"]), (200, payload))
        self.assertEqual(self.post_json("/offers/"+jid+"/ack", {"file_id":file["id"], "sha256":file["sha256"]})[0], 200)
        self.assertEqual(self.receiver.jobs[jid]["state"], "completed")

    def test_reverse_empty_file(self):
        jid, f = self.outgoing(b"", "empty-out.txt")
        self.post_json("/offers/"+jid+"/decision", {"decision":"accept"})
        self.assertEqual(self.binary(jid, f["id"]), (200,b""))
        self.assertEqual(self.post_json("/offers/"+jid+"/ack", {"file_id":f["id"],"sha256":f["sha256"]})[0],200)
        self.assertEqual(self.receiver.jobs[jid]["state"],"completed")

    def test_reverse_reject_and_expire(self):
        jid, f = self.outgoing()
        self.post_json("/offers/"+jid+"/decision", {"decision":"reject"})
        self.assertEqual(self.binary(jid, f["id"])[0],403)
        self.assertEqual(self.receiver.jobs[jid]["state"],"rejected")
        jid, f = self.outgoing(name="expired-out.txt")
        self.receiver.jobs[jid]["expires"] = 0
        self.assertEqual(self.post_json("/offers/"+jid+"/decision", {"decision":"accept"})[0],409)
        self.assertEqual(self.binary(jid, f["id"])[0],403)

    def test_reverse_device_isolation_and_revoke(self):
        jid, f = self.outgoing(name="private.bin")
        stranger = self.receiver.add_device("Other phone")
        self.assertEqual(self.binary(jid,f["id"],stranger)[0],404)
        self.post_json("/offers/"+jid+"/decision", {"decision":"accept"})
        self.receiver.revoke(module.token_hash(self.token)[:24])
        self.assertEqual(self.binary(jid,f["id"])[0],401)
        self.assertEqual(self.receiver.jobs[jid]["state"],"cancelled")

    def test_reverse_cancel_and_checksum_ack(self):
        jid, f = self.outgoing(name="cancel-out.txt")
        self.post_json("/offers/"+jid+"/decision", {"decision":"accept"})
        self.assertEqual(self.post_json("/offers/"+jid+"/ack", {"file_id":f["id"],"sha256":"0"*64})[0],422)
        self.post_json("/offers/"+jid+"/cancel", {})
        self.assertEqual(self.binary(jid,f["id"])[0],403)
        self.assertNotEqual(self.receiver.jobs[jid]["state"],"completed")

    def test_reverse_changed_source_fails(self):
        jid, f = self.outgoing(name="changing.txt")
        self.post_json("/offers/"+jid+"/decision", {"decision":"accept"})
        Path(f["path"]).write_bytes(b"changed after consent")
        self.assertEqual(self.binary(jid,f["id"])[0],409)
        self.assertEqual(self.receiver.jobs[jid]["state"],"failed")

    def test_presence_and_legacy_identity_survive_upgrade(self):
        key = module.token_hash(self.token)
        self.receiver.events(key,False,wait=0)
        d=next(x for x in self.receiver.public_devices() if x["id"]==key[:24])
        self.assertTrue(d["online"]); self.assertFalse(d["receiving"])
        self.receiver.sessions[key]["seen"]=0
        self.assertFalse(next(x for x in self.receiver.public_devices() if x["id"]==key[:24])["online"])
        with self.assertRaises(ValueError): self.receiver.queue(key[:24],[str(self.root/"nonexistent")])
        restored=module.Receiver(self.receiver.root,self.receiver.destination)
        self.assertTrue(restored.authorized(self.token))
        self.assertEqual(restored.server_id,self.receiver.server_id)

    def test_idle_and_heartbeats_do_not_rewrite_ui_snapshot(self):
        key = module.token_hash(self.token)
        self.receiver.events(key, True, wait=0)
        state = self.receiver.root / 'state.json'
        before = state.stat()
        seen = self.receiver.sessions[key]['seen']
        with patch.object(module.time, 'time', return_value=seen + 1):
            self.receiver.publish(notify=False)
            self.receiver.events(key, True, wait=0)
        self.assertEqual(state.stat().st_ino, before.st_ino)
        self.assertEqual(state.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.receiver.sessions[key]['seen'], seen + 1)

    def test_receiving_change_and_offline_still_publish_ui_snapshot(self):
        key = module.token_hash(self.token)
        self.receiver.events(key, True, wait=0)
        state = self.receiver.root / 'state.json'
        def device():
            return next(d for d in json.loads(state.read_text())['trusted_devices'] if d['id'] == key[:24])
        self.assertTrue(device()['receiving'])
        self.receiver.events(key, False, wait=0)
        self.assertTrue(device()['online'])
        self.assertFalse(device()['receiving'])
        with patch.object(module.time, 'time', return_value=self.receiver.sessions[key]['seen'] + 61):
            self.receiver.publish(notify=False)
        self.assertFalse(device()['online'])


    def test_restart_reclaims_only_owned_partial_namespace(self):
        partial=self.receiver.destination/".midrop-abcdefgh.part"
        partial.write_bytes(b"unfinished"); partial.chmod(0o600)
        complete=self.receiver.destination/"keep-this.part"
        complete.write_bytes(b"user content")
        restored=module.Receiver(self.receiver.root,self.receiver.destination)
        self.assertFalse(partial.exists())
        self.assertEqual(complete.read_bytes(),b"user content")
        self.assertTrue(restored.authorized(self.token))

    def text_receiver(self):
        key = module.token_hash(self.token)
        self.receiver.events(key, True, wait=0, text_support=True, receiving_text=True)
        return key

    def test_text_phone_to_mac_preserves_content_and_deduplicates(self):
        text = '  中文、emoji 🐈\nhttps://example.com/?a=1&b=%E4%B8%AD\n  '
        payload = {'id': 'phone-message-1', 'text': text}
        status, result = self.post_json('/texts', payload)
        self.assertEqual(status, 201)
        self.assertEqual(self.post_json('/texts', payload), (200, result))
        messages = [m for m in self.receiver.texts if m['id'] == result['id']]
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]['text'], text)
        self.assertEqual(messages[0]['state'], 'completed')
        self.assertEqual(self.post_json('/texts', dict(payload, text='changed'))[0], 400)
        self.assertEqual(self.receiver.texts[-1]['text'], text)
        self.assertNotIn('owner', self.receiver.public_text(messages[0]))
        self.assertEqual((self.receiver.root/'texts.json').stat().st_mode & 0o777, 0o600)

    def test_text_mac_to_phone_delivery_ack_and_device_isolation(self):
        key = self.text_receiver()
        text = '多行\nhttps://example.com/路径?q=猫#中文'
        message = self.receiver.control({'action': 'send_text', 'device_id': key[:24], 'text': text})
        mid = message['id']
        stranger = self.receiver.add_device('Other phone')
        status, events = self.post_json('/events', {'receiving': True, 'text_support': True, 'receiving_text': True, 'wait': False})
        self.assertEqual(status, 200)
        self.assertEqual(next(m['text'] for m in events['texts'] if m['id'] == mid), text)
        self.assertEqual(self.receiver.events(module.token_hash(stranger), True, wait=0, text_support=True, receiving_text=True)[1]['texts'], [])
        self.assertEqual(self.request('/texts/'+mid+'/ack', b'{}', {'Authorization': 'Bearer '+stranger})[0], 404)
        self.assertEqual(self.post_json('/texts/'+mid+'/ack', {})[0], 200)
        self.assertEqual(self.post_json('/texts/'+mid+'/ack', {})[0], 200)
        self.assertEqual(self.receiver.events(key, True, wait=0, text_support=True, receiving_text=True)[1]['texts'], [])
        self.assertEqual(next(m['state'] for m in self.receiver.texts if m['id'] == mid), 'completed')

    def test_text_rejects_unpaired_invalid_and_oversize_payloads(self):
        self.assertEqual(self.request('/texts', b'{"id":"x","text":"private"}')[0], 401)
        for text in ('', ' \n\t ', None, 123, '猫'*(module.MAX_TEXT//3+1)):
            self.assertEqual(self.post_json('/texts', {'id': 'invalid', 'text': text})[0], 400)
        boundary = 'a'*module.MAX_TEXT
        self.assertEqual(self.post_json('/texts', {'id': 'boundary', 'text': boundary})[0], 201)

    def test_text_capability_pause_and_no_storage_requirement(self):
        key = module.token_hash(self.token)
        self.receiver.events(key, True, wait=0)
        with self.assertRaisesRegex(ValueError, '更新'):
            self.receiver.queue_text(key[:24], 'hello')
        self.receiver.events(key, False, wait=0, text_support=True, receiving_text=False)
        with self.assertRaisesRegex(ValueError, '暂停'):
            self.receiver.queue_text(key[:24], 'hello')
        self.receiver.events(key, False, wait=0, text_support=True, receiving_text=True)
        mid = self.receiver.queue_text(key[:24], 'works without storage')['id']
        self.assertIn(mid, [m['id'] for m in self.receiver.events(key, False, wait=0, text_support=True, receiving_text=True)[1]['texts']])

    def test_text_expiry_revocation_and_restart(self):
        key = self.text_receiver()
        mid = self.receiver.queue_text(key[:24], 'expire')['id']
        next(m for m in self.receiver.texts if m['id'] == mid)['expires'] = 0
        self.receiver.sweep()
        self.assertEqual(self.post_json('/texts/'+mid+'/ack', {})[0], 409)
        cancelled = self.receiver.queue_text(key[:24], 'cancel on revoke')['id']
        self.receiver.revoke(key[:24])
        self.assertEqual(next(m['state'] for m in self.receiver.texts if m['id'] == cancelled), 'cancelled')
        self.assertEqual(self.post_json('/texts', {'id': 'revoked', 'text': 'not allowed'})[0], 401)
        other = self.receiver.add_device('Restart phone')
        other_key = module.token_hash(other)
        self.receiver.events(other_key, True, wait=0, text_support=True, receiving_text=True)
        pending = self.receiver.queue_text(other_key[:24], 'interrupted')['id']
        restored = module.Receiver(self.receiver.root, self.receiver.destination)
        self.assertEqual(next(m['state'] for m in restored.texts if m['id'] == pending), 'failed')

    def test_text_history_does_not_evict_pending_delivery(self):
        key = self.text_receiver()
        mid = self.receiver.queue_text(key[:24], 'keep pending')['id']
        for i in range(24):
            self.assertEqual(self.post_json('/texts', {'id': 'history-'+str(i), 'text': str(i)})[0], 201)
        self.assertEqual(len([m for m in self.receiver.texts if m['state'] != 'pending']), 20)
        self.assertEqual(next(m['state'] for m in self.receiver.texts if m['id'] == mid), 'pending')

    def test_board_broadcasts_to_all_trusted_connected_devices(self):
        key=module.token_hash(self.token)
        other=self.receiver.add_device('Second phone')
        before=self.receiver.board['revision']
        text='  共享公告板 🐈\nhttps://example.com/?a=1&b=猫\n '
        status,result=self.post_json('/board',{'text':text,'base_revision':before})
        self.assertEqual(status,200)
        for device in (key,module.token_hash(other)):
            status,events=self.receiver.events(device,False,wait=0,board_support=True,board_revision=before)
            self.assertEqual(events['board']['text'],text)
            self.assertEqual(events['board']['revision'],before+1)
        # The board is independent of file receiving and needs no recipient.
        self.assertEqual(self.receiver.control({'action':'update_board','text':'from Mac','base_revision':before+1})['board']['text'],'from Mac')
        self.assertTrue(self.receiver.public_devices()[0]['supports_board'])

    def test_board_stale_writes_conflict_and_retries_are_idempotent(self):
        revision=self.receiver.board['revision']
        first=self.post_json('/board',{'text':'first writer','base_revision':revision})[1]['board']
        status,conflict=self.post_json('/board',{'text':'stale writer','base_revision':revision})
        self.assertEqual(status,409)
        self.assertEqual(conflict['board'],first)
        self.assertEqual(self.receiver.board,first)
        status,retry=self.post_json('/board',{'text':'first writer','base_revision':revision})
        self.assertEqual(status,200)
        self.assertEqual(retry['board']['revision'],first['revision'])

    def test_board_clear_persistence_and_authorization(self):
        revision=self.receiver.board['revision']
        self.assertEqual(self.request('/board',b'',method='GET')[0],401)
        self.assertEqual(self.request('/board',b'{"text":"bad","base_revision":0}')[0],401)
        self.post_json('/board',{'text':'persistent','base_revision':revision})
        restored=module.Receiver(self.receiver.root,self.receiver.destination)
        self.assertEqual(restored.board['text'],'persistent')
        self.assertEqual((self.receiver.root/'board.json').stat().st_mode & 0o777,0o600)
        self.assertEqual(self.post_json('/board',{'text':'','base_revision':revision+1})[0],200)
        self.assertEqual(self.receiver.board['text'],'')
        self.receiver.revoke(module.token_hash(self.token)[:24])
        self.assertEqual(self.post_json('/board',{'text':'revoked','base_revision':revision+2})[0],401)

    def test_board_limits_and_long_poll_wakeup(self):
        import time
        from concurrent.futures import ThreadPoolExecutor
        revision=self.receiver.board['revision']
        for payload in ({'text':None,'base_revision':revision},{'text':'a','base_revision':True},
                        {'text':'猫'*(module.MAX_TEXT//3+1),'base_revision':revision}):
            self.assertEqual(self.post_json('/board',payload)[0],400)
        key=module.token_hash(self.token)
        self.receiver.events(key,False,wait=0,board_support=True,board_revision=revision)
        with ThreadPoolExecutor(max_workers=1) as worker:
            pending=worker.submit(self.receiver.events,key,False,3,None,False,False,True,revision)
            time.sleep(.1)
            self.receiver.control({'action':'update_board','text':'wake-'+str(revision),'base_revision':revision})
            self.assertEqual(pending.result(timeout=1)[1]['board']['revision'],revision+1)
        # An unchanged board must not repeatedly wake the idle client.
        started=time.monotonic()
        self.receiver.events(key,False,wait=.15,board_support=True,board_revision=revision+1)
        self.assertGreaterEqual(time.monotonic()-started,.12)


if __name__ == "__main__":
    unittest.main()
