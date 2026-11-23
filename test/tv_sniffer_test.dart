import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/data/tv_brands.dart';
import 'package:tvcleanzer/services/tv_sniffer.dart';

/// 1.3.76: TVs recognised on the network before debugging is on.
void main() {
  test('Google Cast eureka_info: name, maker, model', () {
    final r = TvSniffer.parseEureka(
        '{"name":"Гостиная","device_info":{"manufacturer":"Sony","model_name":"BRAVIA 4K VH2"}}');
    expect(r, ('Гостиная', 'Sony', 'BRAVIA 4K VH2'));
    expect(TvSniffer.parseEureka('{"name":"TV"}'), ('TV', null, null));
    expect(TvSniffer.parseEureka('not json'), isNull);
    expect(TvSniffer.parseEureka(null), isNull);
  });

  test('Samsung and Roku answers', () {
    expect(TvSniffer.parseSamsung('{"device":{"name":"[TV] Samsung Q60","modelName":"QE55Q60"}}'),
        ('[TV] Samsung Q60', 'QE55Q60'));
    expect(TvSniffer.parseSamsung('{}'), isNull);
    expect(TvSniffer.parseRoku('<device-info><vendor-name>TCL</vendor-name><model-name>8K</model-name>'
        '<user-device-name>Kitchen</user-device-name></device-info>'), ('Kitchen', 'TCL', '8K'));
    expect(TvSniffer.parseRoku('<html></html>'), isNull);
  });

  test('Cast speakers are not TVs', () {
    expect(TvSniffer.isSpeaker('Google Nest Mini'), isTrue);
    expect(TvSniffer.isSpeaker('Google Home'), isTrue);
    expect(TvSniffer.isSpeaker('BRAVIA 4K VH2'), isFalse);
    expect(TvSniffer.isSpeaker('Homatics Box R 4K Plus'), isFalse);
  });

  test('a seen TV: title and brand', () {
    const s = SeenTv('x', 'android', name: 'Гостиная', maker: 'Sony', model: 'BRAVIA');
    expect(s.title, 'Sony BRAVIA');
    expect(const SeenTv('x', 'android', name: 'Гостиная').title, 'Гостиная');
    expect(const SeenTv('x', 'lg').title, 'LG');
    expect(const SeenTv('x', 'samsung').brandHint, 'Samsung');
    expect(const SeenTv('x', 'samsung').notAndroid, isTrue);
  });

  test('maker → brand by a whole word', () {
    expect(brandFor('Sony Corporation')?.name, 'Sony');
    expect(brandFor('Xiaomi')?.name, 'Xiaomi / Redmi');
    expect(brandFor('TCL')?.name, 'TCL');
    expect(brandFor('Hisense')?.name, 'Hisense', reason: 'never «Hi»');
    expect(brandFor('Samsung')?.unsupported, isTrue);
    expect(brandFor('Shenzhen Something'), isNull);
  });
}
