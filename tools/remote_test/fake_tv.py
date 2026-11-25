"""A fake Android TV Remote v2 server for testing TVCleanzer's Dart client.
Uses the protobuf classes of androidtvremote2 (the reference implementation).
Pairing on 16467, remote on 16466. Trusts only certificates in /tmp/tvpaired.pem
on the remote port (like a TV that knows its paired phones)."""
import asyncio, hashlib, os, random, ssl, sys, json
sys.path.insert(0, '/tmp/atvr/src')
from androidtvremote2 import polo_pb2 as P, remotemessage_pb2 as R
from cryptography import x509

LOG = open('/tmp/tvlog.jsonl', 'w', buffering=1)
def log(**k): LOG.write(json.dumps(k) + '\n')

def varint(n):
    out = b''
    while True:
        if n < 0x80: return out + bytes([n])
        out += bytes([(n & 0x7f) | 0x80]); n >>= 7

async def read_msg(r):
    n = s = 0
    while True:
        b = (await r.readexactly(1))[0]
        n |= (b & 0x7f) << s; s += 7
        if not b & 0x80: break
    return await r.readexactly(n)

def send(w, m): b = m.SerializeToString(); w.write(varint(len(b)) + b)

def nums(der):
    k = x509.load_der_x509_certificate(der).public_key().public_numbers()
    return k.n, k.e

def outer():
    m = P.OuterMessage(); m.protocol_version = 2; m.status = P.OuterMessage.Status.STATUS_OK; return m

async def pairing(r, w):
    sslobj = w.get_extra_info('ssl_object')
    client = sslobj.getpeercert(True)
    if not client: log(ev='pair_no_cert'); w.close(); return
    try:
        while True:
            m = P.OuterMessage(); m.ParseFromString(await read_msg(r))
            log(ev='pair_in', msg=str(m).replace('\n', ' '))
            o = outer()
            if m.HasField('pairing_request'):
                assert m.pairing_request.service_name == 'atvremote'
                o.pairing_request_ack.server_name = 'FakeTV'
            elif m.HasField('options'):
                e = m.options.input_encodings[0]
                assert e.type == 3 and e.symbol_length == 6 and m.options.preferred_role == 1
                o.options.preferred_role = 1
                x = o.options.input_encodings.add(); x.type = 3; x.symbol_length = 6
            elif m.HasField('configuration'):
                assert m.configuration.client_role == 1 and m.configuration.encoding.type == 3
                o.configuration_ack.SetInParent()
                cn, ce = nums(client); sn, se = nums(open_server_der())
                tail = '%04X' % random.randrange(65536)
                h = hashlib.sha256()
                for part in (f'{cn:X}', f'0{ce:X}', f'{sn:X}', f'0{se:X}', tail): h.update(bytes.fromhex(part))
                global EXPECT; EXPECT = h.digest()
                code = '%02X' % EXPECT[0] + tail
                open('/tmp/tvcode', 'w').write(code); log(ev='code', code=code)
            elif m.HasField('secret'):
                if m.secret.secret == EXPECT:
                    o.secret_ack.secret = b'ok'
                    with open('/tmp/tvpaired.pem', 'a') as f:
                        f.write(ssl.DER_cert_to_PEM_cert(client))
                    log(ev='paired')
                else:
                    o = P.OuterMessage(); o.protocol_version = 2; o.status = P.OuterMessage.Status.STATUS_BAD_SECRET
                    log(ev='bad_secret')
            send(w, o); await w.drain()
    except (asyncio.IncompleteReadError, ConnectionError):
        log(ev='pair_closed')

def open_server_der():
    return ssl.PEM_cert_to_DER_cert(open('/tmp/tv.crt').read())

async def remote(r, w):
    log(ev='remote_open')
    m = R.RemoteMessage(); m.remote_configure.code1 = 622
    m.remote_configure.device_info.model = 'FakeTV'; m.remote_configure.device_info.vendor = 'Test'
    m.remote_configure.device_info.unknown1 = 1; m.remote_configure.device_info.unknown2 = '1'
    m.remote_configure.device_info.package_name = 'androidtv-remote'; m.remote_configure.device_info.app_version = '5.0'
    send(w, m)
    stage = 'configure'; pings = 0
    async def pinger():
        nonlocal pings
        while True:
            await asyncio.sleep(1)
            p = R.RemoteMessage(); pings += 1; p.remote_ping_request.val1 = pings; send(w, p)
    task = None
    try:
        while True:
            x = R.RemoteMessage(); x.ParseFromString(await read_msg(r))
            fields = [f.name for f, _ in x.ListFields()]
            log(ev='remote_in', fields=fields, msg=str(x).replace('\n', ' '))
            if x.HasField('remote_configure') and stage == 'configure':
                assert x.remote_configure.device_info.package_name == 'atvremote'
                s = R.RemoteMessage(); s.remote_set_active.active = 622; send(w, s); stage = 'active'
            elif x.HasField('remote_set_active') and stage == 'active':
                st = R.RemoteMessage(); st.remote_start.started = True; send(w, st)
                v = R.RemoteMessage(); v.remote_set_volume_level.volume_max = 100; v.remote_set_volume_level.volume_level = 25; send(w, v)
                a = R.RemoteMessage(); a.remote_ime_key_inject.app_info.app_package = 'com.google.android.youtube.tv'; send(w, a)
                b = R.RemoteMessage(); b.remote_ime_batch_edit.ime_counter = 7; b.remote_ime_batch_edit.field_counter = 3; send(w, b)
                stage = 'running'; task = asyncio.create_task(pinger())
            await w.drain()
    except (asyncio.IncompleteReadError, ConnectionError, ssl.SSLError) as e:
        log(ev='remote_closed', why=repr(e))
    finally:
        if task: task.cancel()

async def main():
    open('/tmp/tvpaired.pem', 'w').close()
    def ctx(trust_paired):
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        c.load_cert_chain('/tmp/tv.crt', '/tmp/tv.key')
        if trust_paired:
            c.verify_mode = ssl.CERT_REQUIRED
        else:
            # pairing: take any certificate (the real TV does); Python needs a hook for that
            c.verify_mode = ssl.CERT_OPTIONAL
            c.load_verify_locations('/tmp/atvid.crt')
        return c
    pair_srv = await asyncio.start_server(pairing, '127.0.0.1', 16467, ssl=ctx(False))
    srv = await asyncio.start_server(remote_tls, '127.0.0.1', 16466)
    log(ev='up'); print('up', flush=True)
    await asyncio.gather(pair_srv.serve_forever(), srv.serve_forever())

async def remote_tls(reader, writer):
    # upgrade the plain connection to TLS with the current list of paired phones
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.load_cert_chain('/tmp/tv.crt', '/tmp/tv.key')
    c.verify_mode = ssl.CERT_REQUIRED
    if os.path.getsize('/tmp/tvpaired.pem'):
        c.load_verify_locations('/tmp/tvpaired.pem')
    try:
        await writer.start_tls(c)
    except Exception as e:
        log(ev='remote_refused', why=repr(e)); writer.close(); return
    await remote(reader, writer)

asyncio.run(main())
