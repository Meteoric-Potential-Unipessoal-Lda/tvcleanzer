# Политика конфиденциальности TVCleanzer

Действует с 9 ноября 2026 г. · Разработчик: Meteoric Potential Unipessoal Lda · Связь: [EMAIL ПОДДЕРЖКИ]

## Коротко
TVCleanzer не собирает и не передаёт ваши личные данные. У приложения нет аккаунтов, рекламы и аналитики.

## Что делает приложение с сетью
- **Локальная сеть.** Приложение ищет телевизоры в вашей Wi-Fi сети и подключается к ним по протоколу отладки Android (ADB, порт 5555). Все команды телевизору идут напрямую с телефона по локальной сети и никуда больше не отправляются.
- **Подключение по коду.** Для Google TV с «Беспроводной отладкой» приложение один раз сопрягается с телевизором по коду с его экрана и дальше подключается к нему по зашифрованному каналу — тоже только внутри вашей сети.
- **Шрифты.** Шрифты интерфейса загружаются с Google Fonts (fonts.gstatic.com). Это обычный запрос файла без данных о вас; как любой сайт, Google видит IP-адрес запроса.
- **База приложений.** При запуске приложение скачивает обновлённый список приложений для очистки с GitHub (raw.githubusercontent.com). Это обычный запрос файла: он не содержит данных о вас или вашем телевизоре. Как любой сайт, GitHub видит IP-адрес запроса.

## Что хранится на телефоне
Только на вашем телефоне и только для работы приложения:
- ключ для подключения к телевизору (создаётся на телефоне и никуда не передаётся);
- история очисток и ускорений — чтобы вы могли всё вернуть;
- последний выбранный телевизор (адрес в сети и модель) и настройки оформления.

Удалите приложение — удалятся и эти данные.

## Фото
Если вы выбираете фото для фона лаунчера, приложение получает только это фото и отправляет его напрямую на ваш телевизор по локальной сети. Фото никуда больше не загружается.

## Отчёт о проблеме
Кнопка «Сообщить о проблеме» копирует в буфер обмена модель телевизора, версию Android и журнал ошибок (IP-адреса скрыты). Приложение само ничего не отправляет: вы решаете, вставить ли этот текст в чат.

## Дети
Приложение не собирает данных ни о ком, в том числе о детях. Детский режим лаунчера хранит PIN только на телевизоре в зашифрованном (хешированном) виде.

## Изменения
Если политика изменится, новая версия появится на этой странице с новой датой.

---

# TVCleanzer Privacy Policy

Effective November 9, 2026 · Developer: Meteoric Potential Unipessoal Lda · Contact: [SUPPORT EMAIL]

TVCleanzer does not collect or share personal data. No accounts, no ads, no analytics.

- **Local network:** the app finds TVs on your Wi-Fi and talks to them directly over Android's debugging protocol (ADB, port 5555). Commands go from your phone to your TV and nowhere else.
- **Pairing by code:** for Google TV with Wireless debugging the app pairs once using the code shown on the TV and then connects over an encrypted channel — still only inside your network.
- **Fonts:** interface fonts are loaded from Google Fonts (fonts.gstatic.com); the request carries no data about you, Google sees its IP address like any website.
- **Package list:** on start the app downloads an updated list of removable apps from GitHub (raw.githubusercontent.com). The request carries no data about you or your TV; GitHub sees the request's IP address like any website.
- **Stored on your phone only:** the key used to connect to your TV, your clean/boost history (so you can undo it), the last TV you used and your appearance settings. Deleting the app deletes them.
- **Photos:** a photo you pick as the launcher background is sent directly to your TV over your local network and nowhere else.
- **Problem reports:** "Report a problem" copies device info and an error log (IP addresses masked) to your clipboard; the app sends nothing by itself.
- **Children:** no data is collected about anyone, children included. The kids-mode PIN is stored only on the TV, hashed.
