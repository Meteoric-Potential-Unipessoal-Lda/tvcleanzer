import '../l10n/l10n.dart';
import 'tv_guides.dart';

/// A TV brand in the first-run guide. A brand is not a platform: Haier ships Android TV,
/// Google TV and Яндекс ТВ, Xiaomi a global and a Chinese firmware. So the brand narrows
/// the list, and the owner picks the home screen he sees ([guides], most likely first).
class TvBrand {
  final String name;

  /// [TvGuide.id]s; empty = every guide.
  final List<String> guides;

  /// Other spellings people type (Cyrillic, models, sub-brands).
  final String search;
  const TvBrand(this.name, this.guides, {this.search = ''});

  bool matches(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return true;
    return name.toLowerCase().contains(s) || search.toLowerCase().contains(s);
  }

  /// Only platforms TVCleanzer can't work with (Samsung, LG…).
  bool get unsupported =>
      guides.isNotEmpty && guides.every((id) => !guideById(id).supported);
}

const _yandexBoards = ['yandex', 'cvte', 'androidTv'];

List<TvBrand> tvBrands() => [
      const TvBrand('Xiaomi / Redmi', ['xiaomi', 'xiaomiCn', 'googleTv'], search: 'mi tv ксиоми сяоми редми ми тв'),
      const TvBrand('Haier', ['androidTv', 'googleTv', 'yandex'], search: 'хаер хайер'),
      const TvBrand('TCL', ['androidTv', 'googleTv'], search: 'тсл ткл'),
      const TvBrand('Sony', ['googleTv', 'androidTv'], search: 'сони bravia бравиа'),
      const TvBrand('Philips', ['philips'], search: 'филипс'),
      const TvBrand('Hisense', ['googleTv', 'notAndroid'], search: 'хайсенс хисенс vidaa'),
      const TvBrand('Kivi', ['androidTv', 'googleTv'], search: 'киви'),
      const TvBrand('DEXP', ['androidTv', 'yandex'], search: 'дексп'),
      const TvBrand('Hartens', ['androidTv'], search: 'хартенс'),
      const TvBrand('Hyundai', ['yandex', 'androidTv'], search: 'хендай хундай'),
      const TvBrand('Thomson', ['androidTv', 'googleTv'], search: 'томсон'),
      const TvBrand('Toshiba', ['androidTv', 'yandex', 'notAndroid'], search: 'тошиба'),
      const TvBrand('Skyworth', ['androidTv', 'googleTv'], search: 'скайворт'),
      const TvBrand('BBK', _yandexBoards, search: 'ббк'),
      const TvBrand('Starwind', _yandexBoards, search: 'старвинд'),
      const TvBrand('Hi', _yandexBoards, search: 'хай'),
      const TvBrand('Leff', _yandexBoards, search: 'лефф'),
      const TvBrand('Tuvio', _yandexBoards, search: 'тувио'),
      const TvBrand('Artel', _yandexBoards, search: 'артель'),
      const TvBrand('SunWind', _yandexBoards, search: 'санвинд'),
      const TvBrand('Polar', _yandexBoards, search: 'полар'),
      const TvBrand('Erisson', _yandexBoards, search: 'эриссон'),
      TvBrand(tr('Яндекс (модели YNDX)'), const ['yandex', 'yandexStation'], search: 'yandex yndx алиса'),
      const TvBrand('Sber', ['sber'], search: 'сбер салют sberbox сбербокс'),
      const TvBrand('Amazon Fire TV', ['fire'], search: 'амазон файр'),
      TvBrand(tr('Приставка'), const ['androidTv', 'googleTv', 'xiaomi', 'sber', 'fire'],
          search: 'box tv box mi box ugoos homatics chromecast x96 h96 tanix приставка бокс'),
      TvBrand(tr('Проектор'), const ['projector', 'hy300'],
          search: 'projector xgimi nebula anker hy300 magcubic wanbo formovie проектор'),
      const TvBrand('Samsung', ['notAndroid'], search: 'самсунг tizen'),
      const TvBrand('LG', ['notAndroid'], search: 'лж элджи webos'),
      const TvBrand('Huawei', ['notAndroid'], search: 'хуавей harmony'),
      TvBrand(tr('Другая марка'), const [], search: 'other другой'),
    ];

/// How to tell this home screen from the others (the platform question).
String guideLooks(String id) => switch (id) {
      'androidTv' => tr('Ряды приложений и каналов, настройки — шестерёнка справа вверху.'),
      'googleTv' => tr('Вверху вкладки «Для вас», «Фильмы», «Сериалы», «Приложения».'),
      'xiaomi' => tr('Главный экран PatchWall с подборками фильмов, меню на русском или английском.'),
      'xiaomiCn' => tr('Меню на китайском или «перешит на русский» продавцом.'),
      'yandex' => tr('Главный экран Яндекса, на пульте кнопка Алисы.'),
      'cvte' => tr('В «Для разработчиков» нет пункта про отладку.'),
      'sber' => tr('Главный экран Салют ТВ, ассистенты Салют.'),
      'fire' => tr('Вверху «Главная», «Найти», «Прямой эфир».'),
      'projector' => tr('Проектор на Android TV или Google TV.'),
      'hy300' => tr('Недорогой проектор со своим простым меню.'),
      'philips' => tr('Проверим, Android ли это.'),
      'yandexStation' => tr('Телевизор самого Яндекса, модель начинается с YNDX.'),
      _ => tr('Tizen, webOS, VIDAA, HarmonyOS — не Android.'),
    };
