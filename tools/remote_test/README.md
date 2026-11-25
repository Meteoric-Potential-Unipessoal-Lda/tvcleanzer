# Remote without ADB — checks on a computer (1.3.158 / launcher 1.40)

Google's Android TV Remote v2 (lib/services/atv_remote.dart) against a fake TV built on the
protobuf classes of androidtvremote2 (pip install androidtvremote2):
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/tv.key -out /tmp/tv.crt -days 30 -subj /CN=FakeTV
    dart run tools/remote_test/gen.dart          # the phone's certificate → /tmp/atvid.crt/.key
    python3 tools/remote_test/fake_tv.py &        # ports 16467 / 16466 (fix sys.path to androidtvremote2)
    dart run tools/remote_test/e2e.dart

The launcher's Wi-Fi remote (LanRemote / LanProto) against its own Java handshake:
    javac -d /tmp/jt launcher/src/com/tvcleanzer/launcher/LanProto.java tools/remote_test/Lan*.java
    java -cp /tmp/jt com.tvcleanzer.launcher.LanUnit
    java -cp /tmp/jt com.tvcleanzer.launcher.LanTestServer &   # port 17292
    dart run tools/remote_test/lan_e2e.dart

Both together through lib/services/no_adb.dart: dart run tools/remote_test/noadb_e2e.dart
