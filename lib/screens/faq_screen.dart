import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';

/// One question with its answer (both through [tr]).
class FaqItem {
  final String q, a;
  const FaqItem(this.q, this.a);
}

class FaqSection {
  final String title;
  final IconData icon;
  final List<FaqItem> items;
  const FaqSection(this.title, this.icon, this.items);
}

/// The questions people ask most in the chat and in store reviews, with the answers that
/// worked for them. The same facts as Volodka's knowledge base (claude/volodka/knowledge):
/// change both together.
List<FaqSection> faqSections() => [
      FaqSection(tr('Подключение'), Icons.wifi_rounded, [
        FaqItem(tr('Приложение не находит телевизор'),
            tr('Телефон и телевизор должны быть в одной сети Wi‑Fi: не гостевой, а если у роутера две сети (2,4 и 5 ГГц) — подключите оба к одной. Выключите VPN на телефоне. На ТВ должна быть включена отладка (кнопка «Как включить отладку на моём ТВ?»). Можно ввести IP телевизора вручную: он есть в настройках сети на ТВ.')),
        FaqItem(tr('Телевизор спрашивает «Разрешить отладку?»'),
            tr('Это TVCleanzer. Отметьте «Всегда разрешать с этого компьютера» и нажмите «ОК» — тогда вопрос больше не появится.')),
        FaqItem(tr('TCL не подключается'),
            tr('В «Для разработчиков» включите не только «Отладку по USB», но и «Заводская разблокировка», затем снова нажмите поиск в TVCleanzer.')),
        FaqItem(tr('Китайский Xiaomi подключался, а после перезагрузки — нет'),
            tr('На китайских прошивках отладка по сети выключается при каждой перезагрузке. Включите её снова: Настройки → 账号与安全 (Аккаунт и безопасность) → ADB调试. Если пункта нет — «О телевизоре», 7 раз нажмите ОК на «Модель».')),
        FaqItem(tr('Samsung, LG, Hisense, Huawei — почему не работает?'),
            tr('Это не Android: Samsung — Tizen, LG — webOS, Hisense — VIDAA, Huawei Vision — HarmonyOS. Отладки по ADB там нет. TVCleanzer работает с Android TV, Google TV, Яндекс ТВ, Салют ТВ, приставками и проекторами на Android.')),
      ]),
      FaqSection(tr('Очистка и возврат'), Icons.cleaning_services_rounded, [
        FaqItem(tr('Что безопасно убирать?'),
            tr('«Рекомендуем убрать» — реклама, обновлялки и сборщики данных, проверенные по спискам для разных моделей. «На ваше усмотрение» — функции вроде голоса и трансляции: отмечайте, только если не пользуетесь. Систему, входы HDMI, пульт и главный экран TVCleanzer не трогает.')),
        FaqItem(tr('После очистки что-то перестало работать'),
            tr('Ничего не удаляется навсегда. Откройте «Историю» и нажмите «Вернуть» у нужной очистки или «Вернуть всё скрытое», потом перезагрузите телевизор. Если приложение выключил сам телевизор, появится кнопка «Открыть» — на ТВ откроется его страница, там нажмите «Включить».')),
        FaqItem(tr('Телевизор сам выключается или гаснет во время фильма'),
            tr('Это таймер экрана: через сколько-то минут без пульта экран гаснет, а если заставки нет — телевизор выключается. Видео-приложения обычно этого не допускают, но IPTV-плееры и браузер — допускают. «⋮» у телевизора → «Экран и сон» → поставьте 2–4 часа.')),
        FaqItem(tr('Перестал работать VPN'),
            tr('VPN — ваш выбор, TVCleanzer его не запрещает. Верните скрытое через «Историю» и перезагрузите ТВ; если не помогло — переустановите VPN-приложение. Пока телефон подключается к ТВ, VPN на телефоне лучше выключить.')),
        FaqItem(tr('Китайский Xiaomi завис на логотипе'),
            tr('Выньте вилку, зажмите на пульте ОК и «Назад» и вставьте вилку — откроется меню восстановления. Выберите «Reboot», а если не помогло — «Wipe user data» (сбросит настройки). На китайских прошивках TVCleanzer больше не трогает приложения Xiaomi.')),
        FaqItem(tr('Флешка не видна, пока включена отладка'),
            tr('Так устроены некоторые прошивки (например, Xiaomi MOOQ1): пока включена отладка, порт USB занят ею. Когда закончите, нажмите «⋮» у телевизора → «Выключить отладку на ТВ» — флешка появится.')),
        FaqItem(tr('Поиск печатает иероглифы, меню на чужом языке'),
            tr('«⋮» у телевизора → «Язык и клавиатура ТВ»: выберите клавиатуру с русским языком и язык системы. Если в прошивке нет русского перевода, надёжнее English.')),
      ]),
      FaqSection(tr('Возможности'), Icons.auto_awesome_rounded, [
        FaqItem(tr('Как закинуть IPTV-плейлист или фильм без флешки?'),
            tr('Вкладка «Приложения» → «Отправить файл на ТВ» → «Выбрать файл». Файл появится на телевизоре в «Загрузки» → «TVCleanzer». Плейлист потом добавьте в IPTV-приложении: «Добавить плейлист» → «Файл».')),
        FaqItem(tr('Как искать голосом?'),
            tr('«Пульт» → микрофон в поле текста → скажите, что найти. Поиск откроется в приложении, которое сейчас на экране ТВ (YouTube, VK Видео…). Кнопка ➤ набирает текст в поле ввода на телевизоре.')),
        FaqItem(tr('Как включить музыку в фоторамке?'),
            tr('Вкладка «Лаунчер» → «Фоторамка» → «Добавить музыку». Музыка играет, пока на экране фоторамка, а без фото — под часы. Громкость — пультом телевизора.')),
        FaqItem(tr('Как убрать приветствие, уменьшить часы или скрыть память?'),
            tr('Вкладка «Лаунчер» → группы «Верхняя панель» и «Часы»: «Приветствие», «Часы вверху», «Дата и погода в одну строку», «Память на главном экране». То же на телевизоре: шестерёнка → настройки лаунчера.')),
        FaqItem(tr('Как сделать круглые значки?'),
            tr('Вкладка «Лаунчер» → «Значки и плитки» → «Форма значков» → «Круглые». В «Авто» круглыми станут только значки в доке и «Витрине»; чтобы везде — в «Иконках приложений» выберите «Иконки». На телевизоре: шестерёнка → настройки лаунчера → «Форма значков».')),
        FaqItem(tr('Что значат цвета значка сети?'),
            tr('Зелёный — интернет есть, синий — работает VPN, оранжевый — сеть есть, а интернета нет (роутер, провайдер или VPN), красный — нет сети.')),
      ]),
      FaqSection(tr('Лаунчер'), Icons.dashboard_rounded, [
        FaqItem(tr('Как обновить лаунчер на телевизоре?'),
            tr('Обычно он обновляется сам: откройте TVCleanzer, когда на ТВ открыт наш лаунчер. Если на вкладке «Лаунчер» есть оранжевая кнопка «Обновить лаунчер на ТВ» — нажмите её. Настройки и избранное сохранятся.')),
        FaqItem(tr('«Домой» открывает не наш лаунчер'),
            tr('Вкладка «Лаунчер» → «Сделать главным ещё раз». На Xiaomi, Google TV, Яндекс ТВ и Салют ТВ родной экран остаётся, а «Домой» к нам ведёт служба «TVCleanzer: кнопка Домой» — не выключайте её в специальных возможностях ТВ.')),
        FaqItem(tr('Громкость при зажатии меняется по одному делению'),
            tr('Обновите лаунчер. Затем на ТВ: шестерёнка → настройки лаунчера → «Громкость при зажатии» → «Как у телевизора».')),
        FaqItem(tr('«ТВ» открывает не эфир'),
            tr('В «Источниках» на главном экране удерживайте ОК на «ТВ» и выберите приложение эфира — обычно в названии есть TV, Live или «Эфир».')),
        FaqItem(tr('Как переставить, скрыть или добавить в избранное?'),
            tr('На ТВ удерживайте ОК на приложении: «Добавить в избранное», «Переместить» (стрелками, ОК — готово), «Скрыть с главного экрана». Скрытые возвращаются в настройках лаунчера → «Скрытые приложения».')),
        FaqItem(tr('Как вернуть родной главный экран?'),
            tr('Вкладка «Лаунчер» → «Лаунчер на телевизоре» → «Вернуть стандартный лаунчер». Не удаляйте наш лаунчер в настройках ТВ: если родной экран был выключен, останется чёрный экран.')),
      ]),
    ];

/// «Частые вопросы»: sections with expandable answers and a search over both.
class FaqScreen extends StatefulWidget {
  const FaqScreen({super.key});
  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  String _q = '';

  bool _hit(FaqItem i) {
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    return i.q.toLowerCase().contains(q) || i.a.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final sections = faqSections();
    final shown = [
      for (final s in sections)
        if (s.items.any(_hit)) FaqSection(s.title, s.icon, s.items.where(_hit).toList()),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Частые вопросы'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: tr('Поиск по вопросам'),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
          const Gap(12),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(tr('Ничего не нашлось. Нажмите «?» вверху главного экрана и пришлите отчёт — разберёмся.'),
                  style: const TextStyle(color: AppColors.fgMid, height: 1.4)),
            ),
          for (final s in shown) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Row(children: [
                Icon(s.icon, size: 18, color: AppColors.accent),
                const Gap(8),
                Text(s.title,
                    style: GoogleFonts.syne(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
              ]),
            ),
            for (final i in s.items)
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: PageStorageKey(i.q),
                  initiallyExpanded: _q.isNotEmpty,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 12),
                  iconColor: AppColors.fgMid,
                  collapsedIconColor: AppColors.fgMuted,
                  title: Text(i.q, style: const TextStyle(color: AppColors.fg, fontSize: 14, fontWeight: FontWeight.w600)),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(i.a,
                          style: const TextStyle(color: AppColors.fgMid, fontSize: 13.5, height: 1.5)),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
