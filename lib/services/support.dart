import 'package:url_launcher/url_launcher.dart';

/// Author and donations.
///
/// App Store / Google Play builds are made with `--dart-define=STORE=true`: the stores allow
/// tips only through their own in-app purchases, so those builds show the author's Telegram
/// and no donation links. The Telegram APK and the Windows build show both.
class Support {
  Support._();

  static const storeBuild = bool.fromEnvironment('STORE');

  static const author = 'Андрей Жердев';
  static const telegram = 'https://t.me/zherdyevofficial';
  static const telegramShort = 't.me/zherdyevofficial';

  /// Fill in after registering (name, link). Empty = the donate button is hidden.
  static const donations = <(String, String)>[
    ('Boosty', 'https://boosty.to/zherdyevofficial/donate'),
    ('Buy Me a Coffee', 'https://buymeacoffee.com/zherdyev'),
  ];

  static bool get canDonate => !storeBuild && donations.isNotEmpty;

  static Future<bool> open(String url) async {
    try {
      return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
