package com.tvcleanzer.launcher;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.*;

/** LanProto on a computer: the launcher's handshake and line check, keys in memory. */
public class LanTestServer {
    static final Map<String, byte[]> keys = new HashMap<>();
    static PrintWriter log;
    static boolean pairing;
    static final long[] fails = new long[3];
    static int fi;

    public static void main(String[] a) throws Exception {
        log = new PrintWriter(new FileWriter("/tmp/lanlog"), true);
        ServerSocket ss = new ServerSocket(17292, 4, InetAddress.getByName("127.0.0.1"));
        System.out.println("up");
        SecureRandom rnd = new SecureRandom();
        while (true) {
            Socket s = ss.accept();
            new Thread(() -> {
                try { session(s, rnd); } catch (Throwable t) { log.println("ERR " + t); }
                try { s.close(); } catch (Throwable ignored) {}
            }).start();
        }
    }

    static void session(Socket s, SecureRandom rnd) throws Exception {
        s.setSoTimeout(30000);
        BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
        OutputStream out = s.getOutputStream();
        LanProto p = new LanProto(rnd);
        LanProto.Io io = new LanProto.Io() {
            public String read() throws IOException { return in.readLine(); }
            public void line(String l) throws IOException { synchronized (out) { out.write((l + "\n").getBytes(StandardCharsets.UTF_8)); out.flush(); } log.println("> " + l); }
            public void slow() throws IOException { s.setSoTimeout(120000); }
        };
        LanProto.Host h = new LanProto.Host() {
            public byte[] key(String id) { synchronized (keys) { return keys.get(id); } }
            public void keep(String id, byte[] k, String n) { synchronized (keys) { keys.put(id, k); } log.println("KEEP " + id + " " + n); }
            public String pairStart() {
                synchronized (keys) {
                    long now = System.currentTimeMillis(), oldest = Long.MAX_VALUE;
                    for (long f : fails) oldest = Math.min(oldest, f);
                    if (oldest > 0 && now - oldest < 600000) return "later";
                    if (pairing) return "busy";
                    pairing = true; return null;
                }
            }
            public void pairEnd(boolean failed) { synchronized (keys) { pairing = false; if (failed) fails[fi++ % 3] = System.currentTimeMillis(); } log.println("PAIREND " + failed); }
            public void showCode(String code, String phone) {
                try (FileWriter f = new FileWriter("/tmp/lancode")) { f.write(code); } catch (IOException e) { throw new RuntimeException(e); }
                log.println("CODE " + code + " for " + phone);
            }
            public void codeDone(boolean ok) { log.println("CODEDONE " + ok); }
        };
        io.line(p.hello(33, "Тестовый ТВ"));
        if (!p.handshake(io, h)) { log.println("HANDSHAKE no"); return; }
        log.println("IN " + p.id);
        io.line("st svc=1 dpad=1 text=1 mouse=1 vol=5/15 muted=0 app=com.test");
        String l;
        while ((l = in.readLine()) != null) {
            String c = p.verify(l);
            if (c == null) { io.line("err mac"); log.println("BADMAC " + l); return; }
            log.println("CMD " + c);
            if (c.equals("p")) io.line("pong");
            else if (c.startsWith("t ")) io.line("t ok");
            else if (c.equals("k back")) io.line("no k back");
        }
        log.println("OUT " + p.id);
    }
}
