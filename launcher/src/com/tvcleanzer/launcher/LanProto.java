package com.tvcleanzer.launcher;

import java.io.IOException;
import java.math.BigInteger;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.util.Arrays;

import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * 1.40: the Wi-Fi remote's handshake and line check (see LanRemote for the wire), plain Java
 * with no Android in it, so the same code is tested on a computer against the phone's client.
 */
final class LanProto {
    /** One connection's lines. */
    interface Io {
        String read() throws IOException;
        void line(String s) throws IOException;
        /** Waiting for a code typed on the phone: a longer read timeout. */
        void slow() throws IOException;
    }

    /** Where the phones' keys live and how the code is shown. */
    interface Host {
        byte[] key(String id);
        void keep(String id, byte[] key, String name);
        /** null: a pairing may start now; else the answer ("busy", "later"). */
        String pairStart();
        void pairEnd(boolean failed);
        void showCode(String code, String phone);
        void codeDone(boolean ok);
    }

    final String tvNonce;
    String id;
    private byte[] sessKey;
    private long seq;
    private final SecureRandom rnd;

    LanProto(SecureRandom rnd) {
        this.rnd = rnd;
        byte[] b = new byte[16];
        rnd.nextBytes(b);
        tvNonce = hex(b);
    }

    String hello(int api, String name) { return "TVC1 " + tvNonce + " " + api + " " + enc(name); }

    /** Reads the phone's first line and pairs or checks it; true: the session is on. */
    boolean handshake(Io io, Host h) throws Exception {
        String first = io.read();
        if (first == null) return false;
        String[] w = first.split(" ");
        if (w.length == 5 && w[0].equals("pair")) return pair(io, h, w);
        if (w.length == 4 && w[0].equals("auth")) return auth(io, h, w);
        io.line("what");
        return false;
    }

    static boolean validId(String s) { return s.matches("[A-Za-z0-9_-]{8,64}"); }
    static boolean validNonce(String s) { return s.matches("[0-9a-f]{32}"); }

    private boolean auth(Io io, Host h, String[] w) throws Exception {
        String phoneNonce = w[2];
        if (!validId(w[1]) || !validNonce(phoneNonce)) {
            io.line("what");
            return false;
        }
        id = w[1];
        byte[] k = h.key(id);
        if (k == null || !MessageDigest.isEqual(unhexOr(w[3]), hmac(k, "a|" + tvNonce + "|" + phoneNonce + "|" + id))) {
            io.line("who");
            return false;
        }
        io.line("ok " + hex(hmac(k, "o|" + tvNonce + "|" + phoneNonce)));
        sessKey = hmac(k, "sess|" + tvNonce + "|" + phoneNonce);
        return true;
    }

    private boolean pair(Io io, Host h, String[] w) throws Exception {
        String phoneNonce = w[2], phoneKey = w[3], name = dec(w[4]);
        if (!validId(w[1]) || !validNonce(phoneNonce)) {
            io.line("what");
            return false;
        }
        id = w[1];
        if (name.length() > 60) name = name.substring(0, 60);
        String no = h.pairStart();
        if (no != null) {
            io.line(no);
            return false;
        }
        boolean shown = false, failed = false;
        try {
            KeyPair kp = ecPair();
            PublicKey phone;
            try {
                phone = fromRaw(b64d(phoneKey), ((ECPublicKey) kp.getPublic()).getParams());
            } catch (Exception e) {
                io.line("what");
                return false;
            }
            KeyAgreement ka = KeyAgreement.getInstance("ECDH");
            ka.init(kp.getPrivate());
            ka.doPhase(phone, true);
            byte[] z = ka.generateSecret();
            String tvKey = b64(raw((ECPublicKey) kp.getPublic()));
            String code = String.format(java.util.Locale.ROOT, "%06d", rnd.nextInt(1_000_000));
            String t = tvNonce + "|" + phoneNonce + "|" + id + "|" + phoneKey + "|" + tvKey;
            MessageDigest d = MessageDigest.getInstance("SHA-256");
            d.update(z);
            d.update(code.getBytes(StandardCharsets.US_ASCII));
            byte[] p = d.digest();
            h.showCode(code, name);
            shown = true;
            io.line("code " + tvKey);
            io.slow();
            for (int left = 2; left >= 0; left--) {
                String l = io.read();
                if (l == null || !l.startsWith("code ")) return false;
                if (MessageDigest.isEqual(unhexOr(l.substring(5)), hmac(p, "c|" + t))) {
                    byte[] k = hmac(p, "k|" + t);
                    h.keep(id, k, name);
                    io.line("paired " + hex(hmac(p, "s|" + t)));
                    sessKey = hmac(k, "sess|" + tvNonce + "|" + phoneNonce);
                    h.codeDone(true);
                    shown = false;
                    return true;
                }
                io.line(left > 0 ? "bad " + left : "fail");
            }
            failed = true;
            return false;
        } finally {
            h.pairEnd(failed);
            if (shown) h.codeDone(false);
        }
    }

    /** The command in a session line «command #tag», or null when the tag is wrong. */
    String verify(String l) {
        if (sessKey == null) return null;
        int i = l.lastIndexOf(" #");
        if (i < 0 || l.length() - i != 18) return null;
        String cmd = l.substring(0, i);
        byte[] want = Arrays.copyOf(hmac(sessKey, (++seq) + "|" + cmd), 8);
        return MessageDigest.isEqual(want, unhexOr(l.substring(i + 2))) ? cmd : null;
    }

    // ── crypto and text bits ─────────────────────────────────────────────────────────────

    static KeyPair ecPair() throws Exception {
        KeyPairGenerator g = KeyPairGenerator.getInstance("EC");
        g.initialize(new ECGenParameterSpec("secp256r1"));
        return g.generateKeyPair();
    }

    /** 04 ‖ x ‖ y, 65 bytes. */
    static byte[] raw(ECPublicKey k) {
        byte[] out = new byte[65];
        out[0] = 4;
        put32(k.getW().getAffineX(), out, 1);
        put32(k.getW().getAffineY(), out, 33);
        return out;
    }

    private static void put32(BigInteger v, byte[] out, int off) {
        byte[] b = v.toByteArray();
        int n = Math.min(b.length, 32);
        System.arraycopy(b, b.length - n, out, off + 32 - n, n);
    }

    static PublicKey fromRaw(byte[] b, ECParameterSpec params) throws Exception {
        if (b == null || b.length != 65 || b[0] != 4) throw new IllegalArgumentException("bad key");
        BigInteger x = new BigInteger(1, Arrays.copyOfRange(b, 1, 33));
        BigInteger y = new BigInteger(1, Arrays.copyOfRange(b, 33, 65));
        // on the curve? (y² = x³ − 3x + b mod p) — a point off it would leak the key bit by bit
        BigInteger p = ((java.security.spec.ECFieldFp) params.getCurve().getField()).getP();
        BigInteger a = params.getCurve().getA(), bb = params.getCurve().getB();
        if (x.signum() < 0 || x.compareTo(p) >= 0 || y.signum() < 0 || y.compareTo(p) >= 0
                || !y.multiply(y).mod(p).equals(x.pow(3).add(a.multiply(x)).add(bb).mod(p))) {
            throw new IllegalArgumentException("not on the curve");
        }
        return KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(new ECPoint(x, y), params));
    }

    static byte[] hmac(byte[] key, String msg) {
        try {
            Mac m = Mac.getInstance("HmacSHA256");
            m.init(new SecretKeySpec(key, "HmacSHA256"));
            return m.doFinal(msg.getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(Character.forDigit((x >> 4) & 15, 16)).append(Character.forDigit(x & 15, 16));
        return sb.toString();
    }

    static byte[] unhex(String s) {
        if (s.length() % 2 != 0) throw new IllegalArgumentException("odd hex");
        byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < b.length; i++) {
            int hi = Character.digit(s.charAt(2 * i), 16), lo = Character.digit(s.charAt(2 * i + 1), 16);
            if (hi < 0 || lo < 0) throw new IllegalArgumentException("bad hex");
            b[i] = (byte) (hi << 4 | lo);
        }
        return b;
    }

    /** Bad hex compares unequal instead of throwing. */
    static byte[] unhexOr(String s) {
        try { return unhex(s.trim()); } catch (Throwable t) { return new byte[0]; }
    }

    static String enc(String s) {
        try { return URLEncoder.encode(s, "UTF-8").replace("+", "%20"); } catch (Exception e) { return ""; }
    }

    static String dec(String s) {
        try { return URLDecoder.decode(s.replace("+", "%2B"), "UTF-8"); } catch (Exception e) { return ""; }
    }

    private static final char[] B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();

    /** Base64 with padding (android.util.Base64 is not on a computer, java.util's not on API < 26). */
    static String b64(byte[] b) {
        StringBuilder sb = new StringBuilder((b.length + 2) / 3 * 4);
        for (int i = 0; i < b.length; i += 3) {
            int n = (b[i] & 255) << 16 | (i + 1 < b.length ? (b[i + 1] & 255) << 8 : 0) | (i + 2 < b.length ? b[i + 2] & 255 : 0);
            sb.append(B64[n >> 18 & 63]).append(B64[n >> 12 & 63]);
            sb.append(i + 1 < b.length ? B64[n >> 6 & 63] : '=');
            sb.append(i + 2 < b.length ? B64[n & 63] : '=');
        }
        return sb.toString();
    }

    static byte[] b64d(String s) {
        if (s.length() % 4 != 0) throw new IllegalArgumentException("bad base64");
        int pad = s.endsWith("==") ? 2 : s.endsWith("=") ? 1 : 0;
        byte[] out = new byte[s.length() / 4 * 3 - pad];
        int o = 0;
        for (int i = 0; i < s.length(); i += 4) {
            int n = 0;
            for (int j = 0; j < 4; j++) {
                char c = s.charAt(i + j);
                int v = c == '=' ? 0 : c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ? c - 'a' + 26
                        : c >= '0' && c <= '9' ? c - '0' + 52 : c == '+' ? 62 : c == '/' ? 63 : -1;
                if (v < 0 || (c == '=' && i + j < s.length() - pad)) throw new IllegalArgumentException("bad base64");
                n = n << 6 | v;
            }
            for (int j = 2; j >= 0 && o < out.length; j--) {
                if (j == 2) out[o++] = (byte) (n >> 16);
                else if (j == 1) out[o++] = (byte) (n >> 8);
                else out[o++] = (byte) n;
            }
        }
        return out;
    }
}
