import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvcleanzer/data/tv_brands.dart';
import 'package:tvcleanzer/data/tv_guides.dart';
import 'package:tvcleanzer/screens/onboarding_screen.dart';
import 'package:tvcleanzer/services/tv_discovery.dart';

/// 1.3.73: the first-run connection guide.
void main() {
  test('every brand points at real guides', () {
    final ids = {for (final g in tvGuides) g.id};
    expect(ids.length, tvGuides.length, reason: 'guide ids are unique');
    for (final b in tvBrands()) {
      for (final id in b.guides) {
        expect(ids, contains(id), reason: '${b.name} → $id');
      }
    }
  });

  test('every guide has steps and a «how it looks» line', () {
    for (final g in tvGuides) {
      expect(g.steps, isNotEmpty, reason: g.id);
      expect(guideLooks(g.id), isNotEmpty, reason: g.id);
    }
  });

  test('brands: search in both alphabets, unsupported only when nothing works', () {
    final all = tvBrands();
    TvBrand by(String n) => all.firstWhere((b) => b.name == n);
    expect(by('Haier').matches('хайер'), isTrue);
    expect(by('Xiaomi / Redmi').matches('redmi'), isTrue);
    expect(by('Xiaomi / Redmi').matches('samsung'), isFalse);
    expect(by('Samsung').unsupported, isTrue);
    expect(by('LG').unsupported, isTrue);
    expect(by('Hisense').unsupported, isFalse, reason: 'Hisense Google TV works');
    expect(by('Haier').unsupported, isFalse);
    expect(all.where((b) => b.matches('')).length, all.length);
  });

  test('brand advice goes only to that brand', () {
    final all = tvBrands();
    TvBrand by(String n) => all.firstWhere((b) => b.name == n);
    final atv = guideById('androidTv');
    final tcl = atv.note!;
    expect(by('Haier').notesFor(atv), isNot(contains(tcl)));
    expect(by('Kivi').notesFor(atv), isEmpty);
    expect(by('TCL').notesFor(atv), [tcl]);
    expect(by('TCL').notesFor(guideById('googleTv')).first, tcl);
    expect(by('Philips').tip, guideById('philips').note);
    expect(by('Philips').notesFor(atv), [guideById('philips').note]);
    expect(by('Xiaomi / Redmi').notesFor(guideById('xiaomiCn')), [guideById('xiaomiCn').note]);
  });

  test('the guide shows once, and never to an owner who already has a TV', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await OnboardingScreen.needed(hasTv: false), isTrue);
    expect(await OnboardingScreen.needed(hasTv: true), isFalse);
    expect(await OnboardingScreen.needed(hasTv: false), isFalse, reason: 'marked done by the owner with a TV');
    SharedPreferences.setMockInitialValues({});
    await OnboardingScreen.markDone();
    expect(await OnboardingScreen.needed(hasTv: false), isFalse);
  });

  test('VPN check never throws', () async {
    expect(await TvDiscovery.vpnActive(), isA<bool>());
  });
}
