"""Reference SPAKE2 (BoringSSL spake25519, as used by `adb pair`), pure Python.
Used to produce test vectors for the Dart port. Ported from BoringSSL
crypto/curve25519/spake25519.cc (Apache-2.0)."""
import hashlib

p = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493       # prime order (kOrder)
d = (-121665 * pow(121666, p - 2, p)) % p
I = pow(2, (p - 1) // 4, p)

def inv(x): return pow(x, p - 2, p)

def xrecover(y):
    xx = (y * y - 1) * inv(d * y * y + 1)
    x = pow(xx, (p + 3) // 8, p)
    if (x * x - xx) % p != 0: x = (x * I) % p
    if (x * x - xx) % p != 0: raise ValueError('not on curve')
    if x % 2 != 0: x = p - x
    return x

By = 4 * inv(5) % p
B = (xrecover(By), By)

def add(P, Q):
    (x1, y1), (x2, y2) = P, Q
    x3 = (x1 * y2 + x2 * y1) * inv(1 + d * x1 * x2 * y1 * y2)
    y3 = (y1 * y2 + x1 * x2) * inv(1 - d * x1 * x2 * y1 * y2)
    return (x3 % p, y3 % p)

def neg(P): return ((-P[0]) % p, P[1])

def mul(P, k):
    R = (0, 1)
    Q = P
    while k > 0:
        if k & 1: R = add(R, Q)
        Q = add(Q, Q)
        k >>= 1
    return R

def encode(P):
    x, y = P
    b = bytearray(y.to_bytes(32, 'little'))
    b[31] |= (x & 1) << 7
    return bytes(b)

def decode(s):
    y = int.from_bytes(s, 'little') & ((1 << 255) - 1)
    if y >= p: raise ValueError('bad y')
    x = xrecover(y)
    if (x & 1) != (s[31] >> 7): x = p - x
    P = (x, y)
    if (-P[0] * P[0] + P[1] * P[1] - 1 - d * P[0] * P[0] * P[1] * P[1]) % p != 0: raise ValueError('not on curve')
    return P

M = (31406539342727633121250288103050113562375374900226415211311216773867585644232,
     21177308356423958466833845032658859666296341766942662650232962324899758529114)
N = (49918732221787544735331783592030787422991506689877079631459872391322455579424,
     54629554431565467720832445949441049581317094546788069926228343916274969994000)
assert encode(M).hex() == '5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e'
assert encode(N).hex() == '10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778'

def sc_reduce(b64): return int.from_bytes(b64, 'little') % L

def password_scalar(password):
    h = hashlib.sha512(password).digest()
    w = sc_reduce(h)
    # BoringSSL "password scalar hack": add l, 2l, 4l so w is a multiple of 8
    if w & 1: w += L
    if w & 2: w += 2 * L
    if w & 4: w += 4 * L
    assert w % 8 == 0
    return w, h

def lp(b): return len(b).to_bytes(8, 'little') + b

class Spake2:
    def __init__(self, alice, my_name, their_name, password, rand64):
        self.alice, self.my, self.their = alice, my_name, their_name
        r = sc_reduce(rand64)
        self.priv = (r * 8) % (1 << 256)              # left_shift_3 on 32 bytes
        self.w, self.ph = password_scalar(password)
        P = mul(B, self.priv)
        mask = mul(M if alice else N, self.w)
        self.msg = encode(add(P, mask))

    def process(self, their_msg):
        Q = decode(their_msg)
        mask = mul(N if self.alice else M, self.w)
        dh = mul(add(Q, neg(mask)), self.priv)
        h = hashlib.sha512()
        if self.alice:
            for x in (self.my, self.their, self.msg, their_msg): h.update(lp(x))
        else:
            for x in (self.their, self.my, their_msg, self.msg): h.update(lp(x))
        h.update(lp(encode(dh))); h.update(lp(self.ph))
        return h.digest()

if __name__ == '__main__':
    client, server = b'adb pair client\x00', b'adb pair server\x00'
    pw = b'123456' + bytes(range(64))                 # code + exported keying material
    a = Spake2(True, client, server, pw, bytes([1] * 64))
    b = Spake2(False, server, client, pw, bytes([2] * 64))
    ka, kb = a.process(b.msg), b.process(a.msg)
    assert ka == kb, 'keys differ'
    wrong = Spake2(False, server, client, b'654321' + bytes(range(64)), bytes([2] * 64))
    assert a.process(wrong.msg) != wrong.process(a.msg)
    print('alice_msg', a.msg.hex())
    print('bob_msg  ', b.msg.hex())
    print('key      ', ka.hex())
