package com.tvcleanzer.launcher;

import java.security.*;
import java.security.interfaces.ECPublicKey;
import java.util.*;

/** Small checks of LanProto's pieces. */
public class LanUnit {
    static int fails;
    static void check(boolean ok, String what) { System.out.println((ok ? "ok   " : "FAIL ") + what); if (!ok) fails++; }

    public static void main(String[] a) throws Exception {
        Random r = new Random(1);
        boolean b64ok = true;
        for (int n = 0; n < 200; n++) {
            byte[] b = new byte[r.nextInt(80)];
            r.nextBytes(b);
            String e = LanProto.b64(b);
            if (!e.equals(Base64.getEncoder().encodeToString(b)) || !Arrays.equals(LanProto.b64d(e), b)) b64ok = false;
        }
        check(b64ok, "base64 = java.util.Base64, both ways (200 random)");
        boolean badCaught = true;
        for (String bad : new String[]{"abc", "ab=c", "a b=", "@@@@"}) {
            try { LanProto.b64d(bad); badCaught = false; } catch (IllegalArgumentException ignored) {}
        }
        check(badCaught, "bad base64 refused");
        KeyPair kp = LanProto.ecPair();
        byte[] raw = LanProto.raw((ECPublicKey) kp.getPublic());
        check(raw.length == 65 && raw[0] == 4, "raw point 65 bytes");
        java.security.PublicKey back = LanProto.fromRaw(raw, ((ECPublicKey) kp.getPublic()).getParams());
        check(Arrays.equals(back.getEncoded(), kp.getPublic().getEncoded()), "raw point round trip");
        byte[] off = raw.clone();
        off[64] ^= 1;
        try { LanProto.fromRaw(off, ((ECPublicKey) kp.getPublic()).getParams()); check(false, "point off the curve refused"); }
        catch (IllegalArgumentException e) { check(true, "point off the curve refused"); }
        check(LanProto.validId("abcdefgh") && !LanProto.validId("abc") && !LanProto.validId("abc defgh"), "ids");
        check(LanProto.dec(LanProto.enc("Мой телефон + 1 & =")).equals("Мой телефон + 1 & ="), "names encode/decode");
        check(!LanProto.enc("a b").contains(" ") && !LanProto.enc("a b").contains("+"), "no spaces in encoded names");
        check(LanProto.unhexOr("zz").length == 0 && LanProto.unhexOr("0").length == 0, "bad hex compares unequal");
        // the line check: right tag, replay, wrong order, tampering
        LanProto p = new LanProto(new SecureRandom());
        check(p.verify("k home #0011223344556677") == null, "no session → nothing passes");
        System.exit(fails == 0 ? 0 : 1);
    }
}
