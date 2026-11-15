import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/screens/pair_screen.dart';

String _type(String text) => AddrFormatter()
    .formatEditUpdate(TextEditingValue.empty,
        TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length)))
    .text;

void main() {
  test('IP:port on a number pad', () {
    expect(_type('192.168.4.239:37155'), '192.168.4.239:37155');
    expect(_type('192.168.4.239,37155'), '192.168.4.239:37155');
    expect(_type('192.168.4.239.37155'), '192.168.4.239:37155');
    expect(_type('192.168.4.239 37155'), '192.168.4.239:37155');
    expect(_type('192.168.4'), '192.168.4');
    expect(_type('192,168.4.2'), '192168.4.2'); // a comma before the full address is dropped
    expect(_type('1.2.3.4:5:6'), '1.2.3.4:56');
  });
}
