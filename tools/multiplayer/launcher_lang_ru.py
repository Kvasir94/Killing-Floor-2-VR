"""Russian text of the player window (see launcher_i18n for how keys match).

Game terms follow Killing Floor 2's own Russian localisation (KFGame.rus): Zeds are
мутанты, the Trader is Торговец, perks are навыки, XP is опыт, difficulties are
Обычная / Трудная / Убийственная / Ад на земле, and graphics options keep the game's
names (Засветка, Взаимное затенение, Сумеречные лучи...). The in-game VR menu
shows its pages in English, so its page names ("Settings › Comfort") stay English.
"""
from launcher_i18n import Verbatim, plural

# Page names of the in-game VR menu, which the headset shows in English.
KEEP = (r"^Settings › ",)


def _count(one, few, many):
    """A template value for "N things": the number and the right plural form."""
    return lambda n, *rest: f"{n} {plural(n, one, few, many)}"


def _use(value):
    # "Use 0–100 %" under a number box; "Use Balanced" on a preset's confirm button.
    return f"Допустимо: {value}" if value[:1].isdigit() or value[:1] == "-" else f"Выбрать «{value}»"


def _settings(value):
    return f"{value} {plural(value, 'настройка', 'настройки', 'настроек')}" if value.isdigit() else f"настройки «{value}»"


def _handed(hand, grip, reload_mode):
    who = {"left": "левша", "right": "правша"}.get(hand, hand)
    return f"Ваши текущие настройки: {who}, режим хвата «{grip}», перезарядка «{reload_mode}»."


TEXT = {
    # ----- window frame, navigation and common buttons -----------------------------------------
    "Play": "Играть",
    "Settings": "Настройки",
    "Game & headset": "Игра и шлем",
    "Help": "Помощь",
    "Session": "Сеанс",
    "Your game": "Ваша игра",
    "First-time setup": "Первая настройка",
    "GETTING STARTED": "НАЧАЛО РАБОТЫ",
    "Developer mode": "Режим разработчика",
    "Continue": "Продолжить",
    "Cancel": "Отмена",
    "Back": "Назад",
    "Next": "Далее",
    "Done": "Готово",
    "OK": "ОК",
    "Open": "Открыть",
    "Reset": "Сбросить",
    "Reset…": "Сбросить…",
    "Change…": "Изменить…",
    "Check again": "Проверить снова",
    "Check now": "Проверить сейчас",
    "Clear": "Очистить",
    "Dismiss": "Скрыть",
    "Less": "Меньше",
    "More": "Больше",
    "Show password": "Показать пароль",
    "Hide password": "Скрыть пароль",
    "Type to search": "Начните вводить для поиска",
    "Recommended": "Рекомендуется",
    "Experimental": "Экспериментально",
    "Optional": "Необязательно",
    "Changed": "Изменено",
    "Standard": "Стандарт",
    "None": "Нет",
    "Off": "Выкл",
    "On": "Вкл",
    "Custom": "Свой",
    "✓ Selected": "✓ Выбрано",
    "✓  Saved": "✓  Сохранено",
    "Not saved": "Не сохранено",
    "Language": "Язык",
    "The launcher's own text. The game and the in-game VR menu keep their language.":
        "Только текст лаунчера. Сама игра и VR-меню игры остаются на своём языке.",
    "sec": "с",
    "seconds": "секунд",
    "Update available: {0}": "Доступно обновление: {0}",
    "KF2-VR is already open in another window.": "KF2-VR уже открыт в другом окне.",
    "KF2-VR couldn't open its window:\n\n{0}\n\nUse Save logs for a bug report when the launcher opens again. If you "
    "share window-error.txt from %LOCALAPPDATA%\\KF2VR\\Logs manually, review and remove personal details first.":
        "KF2-VR не смог открыть своё окно:\n\n{0}\n\nКогда лаунчер снова откроется, нажмите «Сохранить логи для "
        "отчёта об ошибке». Если отправляете window-error.txt из %LOCALAPPDATA%\\KF2VR\\Logs вручную, сначала "
        "проверьте его и удалите личные данные.",
    # The same message line by line, for when the error itself is several sentences.
    "KF2-VR couldn't open its window:": "KF2-VR не смог открыть своё окно:",
    "Use Save logs for a bug report when the launcher opens again.":
        "Когда лаунчер снова откроется, нажмите «Сохранить логи для отчёта об ошибке».",
    "If you share window-error.txt from %LOCALAPPDATA%\\KF2VR\\Logs manually, review and remove personal details first.":
        "Если отправляете window-error.txt из %LOCALAPPDATA%\\KF2VR\\Logs вручную, сначала проверьте его и удалите "
        "личные данные.",
    "Something went wrong": "Что-то пошло не так",
    "Something went wrong.": "Что-то пошло не так.",
    "That didn't work. The launcher keeps going; if it happens again, press Save logs for a bug report on the Help page.":
        "Не получилось. Лаунчер продолжает работу; если это повторится, нажмите «Сохранить логи для отчёта об "
        "ошибке» на странице «Помощь».",

    # ----- updates -------------------------------------------------------------------------------
    "Checking for a newer version…": "Проверяем, есть ли новая версия…",
    "Not checked yet this time.": "В этот раз ещё не проверялось.",
    "Couldn't check for updates. Check your internet connection.":
        "Не удалось проверить обновления. Проверьте подключение к интернету.",
    "Up to date (checked at {0}).": "Установлена последняя версия (проверено {0}).",
    "KF2-VR {0} is out (checked at {1}); the Play page links to it.":
        "Вышла KF2-VR {0} (проверено {1}); ссылка на неё есть на странице «Играть».",
    "KF2-VR {0} is out": "Вышла KF2-VR {0}",
    "Download it from the release page and extract it into a new folder.":
        "Скачайте её со страницы релиза и распакуйте в новую папку.",
    "Open release page": "Открыть страницу релиза",
    "Updates": "Обновления",
    "Check for updates": "Проверять обновления",
    "Tells you when a newer KF2-VR is out; nothing installs by itself.":
        "Сообщает о выходе новой KF2-VR; ничего не устанавливается само.",
    "You have KF2-VR {0}": "У вас KF2-VR {0}",
    "Development build": "Сборка для разработки",
    "Build {0}": "Сборка {0}",
    "{0} Jan{1}": "{0} янв.{1}", "{0} Feb{1}": "{0} февр.{1}", "{0} Mar{1}": "{0} марта{1}",
    "{0} Apr{1}": "{0} апр.{1}", "{0} May{1}": "{0} мая{1}", "{0} Jun{1}": "{0} июня{1}",
    "{0} Jul{1}": "{0} июля{1}", "{0} Aug{1}": "{0} авг.{1}", "{0} Sep{1}": "{0} сент.{1}",
    "{0} Oct{1}": "{0} окт.{1}", "{0} Nov{1}": "{0} нояб.{1}", "{0} Dec{1}": "{0} дек.{1}",

    # ----- dialogs from the window -------------------------------------------------------------
    "Locked while a game runs": "Недоступно, пока идёт игра",
    "Change settings in {0} until the game closes.": "Пока игра не закрыта, меняйте настройки в {0}.",
    "Couldn't save settings": "Не удалось сохранить настройки",
    "Epic plays in VR only": "Версия Epic работает только в VR",
    "Epic plays Solo in VR only": "Версия Epic: только соло в VR",
    "Epic support is experimental and covers Solo in VR only.":
        "Поддержка Epic экспериментальная: только одиночная игра в VR.",
    "No maps found": "Карты не найдены",
    "No Killing Floor 2 maps were found in your game folder.": "В папке игры не нашлось карт Killing Floor 2.",
    "Joining needs Steam": "Для подключения нужен Steam",
    "Joining friends works with the Steam version of Killing Floor 2 for now.":
        "Подключаться к друзьям пока можно только в Steam-версии Killing Floor 2.",
    "Still running": "Игра ещё идёт",
    "Wait for the current game to close first.": "Сначала дождитесь, пока текущая игра закроется.",
    "Epic recovery": "Восстановление Epic",
    "KF2-VR is still getting ready": "KF2-VR ещё готовится",
    "Closing stops the download. Next time it carries on where it left off.":
        "Закрытие остановит загрузку. В следующий раз она продолжится с того же места.",
    "Stop and close": "Остановить и закрыть",
    "Keep open": "Оставить открытым",
    "KF2-VR is still running": "KF2-VR ещё работает",
    "You can close this window: the game keeps going and tidies up after itself when you quit it.":
        "Это окно можно закрыть: игра продолжится и сама всё приберёт после выхода.",
    "Close window": "Закрыть окно",
    "Couldn't open the logs folder": "Не удалось открыть папку с логами",
    "Windows didn't open it. You'll find it at {0}.": "Windows её не открыл. Она находится здесь: {0}.",
    "Choose the killingfloor2 folder in your Steam or Epic library":
        "Выберите папку killingfloor2 в вашей библиотеке Steam или Epic",
    "Choose where the game server goes (about 32 GB)": "Выберите, куда установить игровой сервер (около 32 ГБ)",
    "Choose where to save your logs": "Выберите, куда сохранить логи",

    # ----- welcome and first-time setup ----------------------------------------------------------
    "Welcome to KF2-VR": "Добро пожаловать в KF2-VR",
    "Two quick steps, then you're ready to play.": "Два коротких шага — и можно играть.",
    "Pick the copy of Killing Floor 2 to play.": "Выберите копию Killing Floor 2, в которую будете играть.",
    "Killing Floor 2 wasn't found": "Killing Floor 2 не найдена",
    "Checked just now: still not found.": "Только что проверили: по-прежнему не найдена.",
    "Checked just now": "Только что проверено",
    "Your headset": "Ваш шлем",
    "Ready: {0}": "Готово: {0}",
    "No headset app is running": "Приложение шлема не запущено",
    "Find your game first": "Сначала найдите игру",
    "Choose a copy of the game first": "Сначала выберите копию игры",
    "Change any of these; Cancel puts back what you change here.":
        "Меняйте что угодно; «Отмена» вернёт всё, что вы изменили здесь.",
    "A game is running": "Идёт игра",
    "Change these in {0}; they're read-only here until the game closes.":
        "Меняйте это в {0}; здесь настройки только для чтения, пока игра не закроется.",
    "Change settings in {0}; they're read-only here until the game closes.":
        "Меняйте настройки в {0}; здесь они только для чтения, пока игра не закроется.",
    "Fill in the rest with recommended choices": "Заполнить остальное рекомендуемыми вариантами",
    "Your hand and seated choices never change.": "Выбор руки и режима сидя при этом не меняется.",
    "Finish setup": "Завершить настройку",
    "Fill in the rest?": "Заполнить остальное?",
    "Fill in the rest": "Заполнить остальное",
    "This sets {0} to the recommended choice.": "Для этих пунктов будет выбран рекомендуемый вариант: {0}.",
    "Steam": "Steam",
    "Epic Games": "Epic Games",
    "Solo, Host and Join": "Соло, хост и подключение",
    "Solo in VR only": "Только соло в VR",
    "Recommended: Solo, Host and Join": "Рекомендуется: соло, хост и подключение",
    "Experimental: Solo in VR only": "Экспериментально: только соло в VR",
    "We couldn't read your graphics card, so Balanced is recommended.":
        "Не удалось определить видеокарту, поэтому рекомендуется «Баланс».",
    "★ for your {0}.": "★ — для вашей видеокарты {0}.",
    "Selected: {0}": "Выбрано: {0}",
    "Custom: some of its settings were changed in {0}. Pick an option to use it again.":
        "Свой: часть настроек изменена в {0}. Выберите вариант, чтобы снова его использовать.",

    # ----- Play ------------------------------------------------------------------------------------
    "You're set": "Всё готово",
    "Fine-tune feel and fit in {0}.": "Ощущения и посадку рук можно точно подстроить в {0}.",
    "Settings were reorganized": "Настройки переупорядочены",
    "Your choices were kept. Reload styles are now Button, Manual and Realistic.":
        "Ваш выбор сохранён. Теперь стили перезарядки называются «Кнопка», «Вручную» и «Реалистично».",
    "Review settings": "Посмотреть настройки",
    "Game": "Игра",
    "Headset": "Шлем",
    "Choose a copy": "Выберите копию",
    "Not found": "Не найдена",
    "Start your headset app": "Запустите приложение шлема",
    "Not needed on desktop": "На мониторе не нужен",
    "PLAY IN": "ГДЕ ИГРАТЬ",
    "VR": "VR",
    "Desktop": "Монитор",
    "Play in your headset with tracked hands.": "Играть в шлеме с отслеживанием рук.",
    "Play KF2-VR on your monitor, without a headset.": "Играть в KF2-VR на мониторе, без шлема.",
    "Epic plays in VR only.": "Версия Epic работает только в VR.",
    "On your monitor, without a headset.": "На мониторе, без шлема.",
    "Choose your game": "Выберите игру",
    "A game is already running": "Игра уже запущена",
    "Choose your game first": "Сначала выберите игру",
    "Play again in one click, or choose another match.": "Сыграйте снова в один клик или выберите другой матч.",
    "Quick start a solo match in one click, or choose another match.":
        "Быстрый старт одиночного матча в один клик — или выберите другой матч.",
    "PLAY AGAIN": "СЫГРАТЬ СНОВА",
    "QUICK START": "БЫСТРЫЙ СТАРТ",
    "Solo": "Соло",
    "Hosted": "Хост",
    "Play solo": "Играть соло",
    "Host game": "Создать игру",
    "Or choose a match": "Или выберите матч",
    "Solo match": "Одиночный матч",
    "Pick a map, difficulty and length.": "Выберите карту, сложность и длину.",
    "Host a game": "Создать игру",
    "Send friends a code to join your game.": "Отправьте друзьям код для подключения к вашей игре.",
    "Join a friend": "К другу",
    "Paste the code a friend sent you.": "Вставьте код, который прислал друг.",
    "Needs the Steam copy": "Нужна Steam-версия",
    "KF2-VR plays with VAC (Steam's anti-cheat) off, so it joins only VAC-off servers.":
        "KF2-VR играет с выключенным VAC (античитом Steam), поэтому подключается только к серверам без VAC.",
    "Matches earn XP as usual.": "Опыт за матчи начисляется как обычно.",
    "Short length": "Короткая",
    "Medium length": "Средняя",
    "Long length": "Длинная",
    "Graphics: {0}": "Графика: {0}",
    "Graphics: the game's own options": "Графика: настройки самой игры",
    "The game's own options": "Настройки самой игры",
    "Custom (based on {0})": "Свой (на основе «{0}»)",
    "Custom (based on {0}).": "Свой (на основе «{0}»).",
    "Custom fit (from {0})": "Своя посадка (из «{0}»)",
    "a profile": "профиля",

    # ----- match forms ---------------------------------------------------------------------------
    "Pick your match, then start.": "Выберите матч и начинайте.",
    "Friends join with a code you send them.": "Друзья подключаются по коду, который вы им отправите.",
    "Epic opens the game's own menu: choose the map, difficulty and length there.":
        "Epic откроет меню самой игры: карту, сложность и длину выберите там.",
    "Match": "Матч",
    "Map": "Карта",
    "Difficulty": "Сложность",
    "Match length": "Длина матча",
    "Graphics": "Графика",
    "{0} maps. Type a name to search.": lambda n: f"{n} {plural(n, 'карта', 'карты', 'карт')}. "
                                                  "Начните вводить название для поиска.",
    "No map matches “{0}”.": Verbatim("Нет карт, подходящих под «{0}».", 0),
    "{0} map match “{1}”. Pick one from the list.":
        Verbatim(lambda n, q: f"Под «{q}» подходит {n} {plural(n, 'карта', 'карты', 'карт')}. Выберите из списка.", 1),
    "{0} maps match “{1}”. Pick one from the list.":
        Verbatim(lambda n, q: f"Под «{q}» подходят {n} {plural(n, 'карта', 'карты', 'карт')}. Выберите из списка.", 1),
    "No map is called “{0}”, so {1} stays chosen.": Verbatim("Карты «{0}» нет, поэтому остаётся выбранной {1}.", 0, 1),
    "Pick a map from the list": "Выберите карту из списка",
    "Killing Floor 2 maps": "Карты Killing Floor 2",
    "KF2-VR maps": "Карты KF2-VR",
    "Workshop maps": "Карты из Мастерской",
    "VR Range (practice)": "VR-полигон (тренировка)",
    "Normal": "Обычная",
    "Hard": "Трудная",
    "Suicidal": "Убийственная",
    "Hell on Earth": "Ад на земле",
    "Short (4 waves and the boss)": "Короткая (4 волны и босс)",
    "Medium (7 waves and the boss)": "Средняя (7 волн и босс)",
    "Long (10 waves and the boss)": "Длинная (10 волн и босс)",
    # Alone these name graphics levels and gore lifetimes; match lengths say "Short length" and so on.
    "Short": "Коротко",
    "Medium": "Среднее",
    "Long": "Долго",
    "Server": "Сервер",
    "First time hosting: a 9 GB download": "Первый хост: загрузка 9 ГБ",
    "The first time you press Start hosting, KF2-VR downloads the free Killing Floor 2 server from Steam into the game "
    "server folder below. Only the host needs it.":
        "При первом нажатии «Начать хост» KF2-VR скачает бесплатный сервер Killing Floor 2 из Steam в папку "
        "игрового сервера, указанную ниже. Он нужен только хосту.",
    "Server name": "Название сервера",
    "What friends see when they join.": "Это видят друзья при подключении.",
    "Password": "Пароль",
    "Leave it blank to let anyone with the code join.": "Оставьте пустым, чтобы мог подключиться любой с кодом.",
    "Game server folder": "Папка игрового сервера",
    "Installed here": "Установлен здесь",
    "The server needs about 32 GB on {0}": "Серверу нужно около 32 ГБ на {0}",
    "Only {0} GB free on {1}; the server needs about 32 GB. Choose another drive":
        "Свободно только {0} ГБ на {1}, а серверу нужно около 32 ГБ. Выберите другой диск",
    "KF2-VR keeps it on your game's drive; {0} GB free on {1}":
        "KF2-VR держит его на диске с игрой; свободно {0} ГБ на {1}",
    "Change folder…": "Сменить папку…",
    "Friends on another network": "Друзья из другой сети",
    "Friends on your home network can join right away; others may need port forwarding.":
        "Друзья из вашей домашней сети подключатся сразу; остальным может понадобиться проброс портов.",
    "In your router, forward UDP ports 7777 and 27015 to this PC, and allow the game server through Windows Firewall "
    "if asked.":
        "В роутере пробросьте UDP-порты 7777 и 27015 на этот ПК и, если спросят, разрешите игровой сервер в "
        "брандмауэре Windows.",
    "How to do it": "Как это сделать",
    "Hide the steps": "Скрыть шаги",
    "Players": "Игроки",
    "Let VR players grab and throw Zeds.": "VR-игроки могут хватать и бросать мутантов.",
    "Gravity grab": "Гравитационный захват",
    "Let VR players pull guns and pickups to their hand.": "VR-игроки могут притягивать оружие и предметы к руке.",
    "Desktop players can join": "Могут подключаться игроки без шлема",
    "Friends without a headset can join too.": "Друзья без шлема тоже могут подключиться.",
    "Friends without a headset can join if they have this KF2-VR version.":
        "Друзья без шлема могут подключиться, если у них эта же версия KF2-VR.",
    "Friends without a headset need the KF2-VR download.": "Друзьям без шлема нужно скачать KF2-VR.",
    "Zed spawns": "Появление мутантов",
    "Max Zeds at once": "Макс. мутантов одновременно",
    "Zeds per wave": "Мутантов за волну",
    "Spawn speed": "Скорость появления",
    "Standard (the game decides)": "Стандарт (решает игра)",
    "Standard (100%)": "Стандарт (100%)",
    "This Solo match won't earn XP": "Этот одиночный матч не принесёт опыта",
    "Changed Zed spawns turn XP off for this Solo match; hosted games keep XP.":
        "Изменённое появление мутантов отключает опыт в этом одиночном матче; в хостовых играх опыт остаётся.",
    "Hosted games keep XP with any Zed spawns; only Solo loses it.":
        "В хостовых играх опыт сохраняется при любом появлении мутантов; теряется он только в соло.",
    "Set all three back to Standard to earn XP again.": "Верните все три параметра на «Стандарт», чтобы снова получать опыт.",
    "No XP this match": "Без опыта в этом матче",
    "Start solo match": "Начать одиночный матч",
    "Start hosting": "Начать хост",
    "Check the server name": "Проверьте название сервера",
    "Check the password": "Проверьте пароль",
    "Mods": "Моды",
    "{0} will load": "Загрузится: {0}",
    "Workshop page": "Страница в Мастерской",
    "Workshop mod: {0}": "Мод из Мастерской: {0}",
    "Community fixes": "Исправления от сообщества",
    "Teammate health bars": "Полоски здоровья союзников",
    "Bigger scoreboard": "Расширенная таблица счёта",
    "Automatic admin login": "Автоматический вход администратора",
    "Better voting": "Улучшенное голосование",
    "Trader inventory changes": "Изменённый ассортимент Торговца",
    "Fixes bugs in the game. KF2-VR switches it on for you when another mod or a Zed spawn change needs it.":
        "Исправляет ошибки игры. KF2-VR включает его сам, когда он нужен другому моду или изменённому появлению "
        "мутантов.",
    "Shows teammates' health and armor over their heads.": "Показывает здоровье и броню союзников над их головами.",
    "A larger scoreboard with more detail.": "Таблица счёта крупнее и подробнее.",
    "Makes you the admin of your own game, so you can kick players or change maps.":
        "Делает вас администратором вашей игры: можно выгонять игроков и менять карты.",
    "Clearer in-game votes to change the map or kick a player.":
        "Понятные голосования в игре за смену карты или исключение игрока.",
    "Changes what the trader offers; its Workshop page has the details.":
        "Меняет ассортимент Торговца; подробности — на его странице в Мастерской.",
    "Needed by the mods you picked": "Нужен выбранным модам",
    "Needed by your Zed spawn changes": "Нужен для изменённого появления мутантов",
    "Use 1-48 letters, numbers, spaces or . , ' ! & ( ) + _ -":
        "Используйте 1–48 латинских букв, цифр, пробелов или . , ' ! & ( ) + _ -",
    "Type a name; friends see it when they join.": "Введите название; друзья увидят его при подключении.",
    "Use up to 64 letters, numbers, _ or -": "Не более 64 латинских букв, цифр, _ или -",
    "Solo VR required": "Нужно соло в VR",
    "Local agent test control is available in Solo VR only.":
        "Локальное тестовое управление агентом доступно только в соло в VR.",
    "Developer (this launch only)": "Разработчик (только этот запуск)",
    "Replay recording": "Запись повтора",
    "Player motion and input.": "Движения и ввод игрока.",
    "Highlight event logging": "Журнал ярких моментов",
    "Hits, kills and F9 video sync.": "Попадания, убийства и синхронизация видео по F9.",
    "Frame timings": "Время кадров",
    "Written to native.log.": "Пишется в native.log.",
    "Local agent test control": "Локальное тестовое управление агентом",
    "Unranked; allows game console commands. Solo VR only. Not saved.":
        "Без рангов; разрешает консольные команды игры. Только соло в VR. Не сохраняется.",
    "Test mode": "Тестовый режим",
    "Change perk any time and get every weapon of that perk. Unranked. Not saved.":
        "Меняйте навык в любой момент и получайте всё оружие этого навыка. Без рангов. Не сохраняется.",

    # ----- Join --------------------------------------------------------------------------------
    "Join with the code your friend sent, or with their address.":
        "Подключитесь по коду, который прислал друг, или по его адресу.",
    "Join with": "Способ подключения",
    "Join code": "Код подключения",
    "Address": "Адрес",
    "The whole code from their message": "Весь код из сообщения друга",
    "Your friend's code": "Код друга",
    "Paste": "Вставить",
    "Your friend's address": "Адрес друга",
    "Their IP address or computer name, and a port only if they gave one.":
        "IP-адрес или имя компьютера друга, а порт — только если друг его назвал.",
    "for example 203.0.113.7": "например, 203.0.113.7",
    "Leave it blank if their game has none.": "Оставьте пустым, если в игре друга пароля нет.",
    "Join": "Подключиться",
    "Joining": "Подключение",
    "Nothing is copied yet.": "В буфере обмена пока ничего нет.",
    "Add your friend's code first": "Сначала вставьте код друга",
    "Check the code": "Проверьте код",
    "Enter your friend's address first": "Сначала введите адрес друга",
    "Check the address": "Проверьте адрес",
    "This code is from a different KF2-VR version. You and your host need the same version.":
        "Этот код от другой версии KF2-VR. У вас и у хоста должна быть одна и та же версия.",
    "That doesn't look like a KF2-VR join code. Copy the whole code from your friend's message.":
        "Это не похоже на код подключения KF2-VR. Скопируйте код из сообщения друга целиком.",
    "That code is cut short or changed. Copy it again from your friend's message.":
        "Код обрезан или изменён. Скопируйте его из сообщения друга ещё раз.",
    "{0} mods": _count("мод", "мода", "модов"),
    "No mods": "Без модов",
    "Password protected": "С паролем",
    "No password": "Без пароля",
    "After the colon put the port number, such as :7777, or leave it out.":
        "После двоеточия укажите номер порта, например :7777, или не пишите его вовсе.",
    "An IP address has four numbers with dots between, such as 203.0.113.7.":
        "IP-адрес — это четыре числа через точку, например 203.0.113.7.",
    "Each number of an IP address is 0 to 255.": "Каждое число IP-адреса — от 0 до 255.",
    "Use an IP address or computer name, with an optional :port, and no spaces.":
        "Укажите IP-адрес или имя компьютера, при необходимости с :портом, без пробелов.",
    "The port after the colon must be between 1 and 65535.": "Порт после двоеточия должен быть от 1 до 65535.",
    "Use only letters, numbers, _ or -.": "Только латинские буквы, цифры, _ или -.",

    # ----- running session ---------------------------------------------------------------------
    "Hosting": "Хост",
    "In VR": "В VR",
    "On desktop": "На мониторе",
    "Starting...": "Запуск...",
    "Show details": "Показать подробности",
    "Hide details": "Скрыть подробности",
    "CODE FOR YOUR FRIENDS": "КОД ДЛЯ ДРУЗЕЙ",
    "Send it privately: it includes your game's password.": "Отправляйте лично: в нём есть пароль вашей игры.",
    "KF2-VR couldn't find your internet address, so there's no code this time. Press {0} on the Help page.":
        "KF2-VR не смог определить ваш интернет-адрес, поэтому кода в этот раз нет. Нажмите «{0}» на странице "
        "«Помощь».",
    "Copy code": "Скопировать код",
    "Copied. Send it to your friends in a private message.": "Скопировано. Отправьте друзьям в личном сообщении.",
    "Friends on another network also need UDP ports 7777 and 27015 forwarded to this PC.":
        "Друзьям из другой сети также нужен проброс UDP-портов 7777 и 27015 на этот ПК.",
    "Copy the line below into Epic > Library > Killing Floor 2 > Manage > Launch Options, turn the switch on, and press "
    "Launch in Epic within five minutes.":
        "Скопируйте строку ниже в Epic > Библиотека > Killing Floor 2 > Управление > Параметры запуска, включите "
        "переключатель и в течение пяти минут нажмите «Запустить» в Epic.",
    "Copy launch options": "Скопировать параметры запуска",
    "Save your old Launch Options first, keep this window open, and put them back after you quit.":
        "Сначала сохраните свои старые параметры запуска, не закрывайте это окно и верните их после выхода из игры.",
    "Done. In Epic, put your previous Launch Options back before you play normally.":
        "Готово. Перед обычной игрой верните в Epic прежние параметры запуска.",
    "All done. Killing Floor 2 is back to normal.": "Всё готово. Killing Floor 2 возвращена в обычное состояние.",
    "Back to Play": "Назад к игре",
    "If it keeps happening, press {0}.": "Если это повторяется, нажмите «{0}».",
    "Checking your game and files...": "Проверяем игру и файлы...",
    "Code accepted. Getting ready...": "Код принят. Готовимся...",
    "Setting up the game server...": "Настраиваем игровой сервер...",
    "Downloading the game server. The first time is about 9 GB (32 GB once installed).":
        "Скачиваем игровой сервер. В первый раз это около 9 ГБ (32 ГБ после установки).",
    "Game server ready. Starting it...": "Игровой сервер готов. Запускаем...",
    "Connecting to the game server...": "Подключаемся к игровому серверу...",
    "Your game is up. Send your friends the code below.": "Ваша игра запущена. Отправьте друзьям код ниже.",
    "Copy the line below into Epic > Library > Killing Floor 2 > Manage > Launch Options.":
        "Скопируйте строку ниже в Epic > Библиотека > Killing Floor 2 > Управление > Параметры запуска.",
    "Epic connected. Choose Play Solo Offline, your map and perk, then Ready. Keep this window open.":
        "Epic подключена. Выберите «Играть соло автономно», карту и навык, затем «Готово». Не закрывайте это окно.",
    "Killing Floor 2 is starting. Pick your perk and press Ready. Keep this window open while you play.":
        "Killing Floor 2 запускается. Выберите навык и нажмите «Готово». Не закрывайте это окно во время игры.",
    "Checking your game and files": "Проверка игры и файлов",
    "Join code accepted": "Код подключения принят",
    "Setting up the game server": "Настройка игрового сервера",
    "Downloading the game server (about 9 GB the first time)": "Загрузка игрового сервера (около 9 ГБ в первый раз)",
    "Starting the game server": "Запуск игрового сервера",
    "Connecting to the game server": "Подключение к игровому серверу",
    "Your game is up": "Ваша игра запущена",
    "Paste the launch line into Epic": "Вставьте строку запуска в Epic",
    "Epic connected": "Epic подключена",
    "Killing Floor 2 is starting": "Killing Floor 2 запускается",
    "Your copy of Killing Floor 2 doesn't match this KF2-VR build. Let Steam finish updating KF2, then get the newest "
    "KF2-VR from where you downloaded this one.":
        "Ваша копия Killing Floor 2 не подходит к этой сборке KF2-VR. Дайте Steam закончить обновление KF2, затем "
        "скачайте новейшую KF2-VR оттуда же, откуда скачали эту.",
    "Start normal Killing Floor 2 from Steam once, quit it, then try again.":
        "Один раз запустите обычную Killing Floor 2 из Steam, выйдите из неё и попробуйте снова.",
    "Your headset isn't ready. Start Quest Link / Air Link, SteamVR or your headset's PC app, then try again. Or choose "
    "Desktop.":
        "Шлем не готов. Запустите Quest Link / Air Link, SteamVR или ПК-приложение вашего шлема и попробуйте снова. "
        "Или выберите «Монитор».",
    "KF2-VR is already running in another window. Close that game first.":
        "KF2-VR уже запущен в другом окне. Сначала закройте ту игру.",
    "A previous KF2-VR session didn't finish tidying up. Press Help > Repair, then try again.":
        "Прошлый сеанс KF2-VR не закончил уборку. Нажмите «Помощь» > «Восстановить» и попробуйте снова.",
    "Steam isn't running or isn't signed in. Open Steam, sign in, then try again.":
        "Steam не запущен или вы не вошли в аккаунт. Откройте Steam, войдите и попробуйте снова.",
    "Killing Floor 2 is already open. Close it, then try again.":
        "Killing Floor 2 уже открыта. Закройте её и попробуйте снова.",
    "Couldn't reach your friend's game. Check the code is the newest one, and ask them to make sure their game says it's up.":
        "Не удалось достучаться до игры друга. Убедитесь, что код самый свежий, и попросите друга проверить, что его "
        "игра запущена.",
    "Some KF2-VR files are missing or damaged. Delete this folder and unzip a fresh copy.":
        "Часть файлов KF2-VR отсутствует или повреждена. Удалите эту папку и распакуйте свежую копию.",
    "There isn't enough free disk space for the game server. Free some space, then try again.":
        "Для игрового сервера не хватает места на диске. Освободите место и попробуйте снова.",
    "The game server download didn't finish. Check your internet and disk space, then try again.":
        "Загрузка игрового сервера не завершилась. Проверьте интернет и место на диске и попробуйте снова.",
    "The game server stopped while starting. Save logs for a bug report if it keeps happening.":
        "Игровой сервер остановился при запуске. Если это повторяется, сохраните логи для отчёта об ошибке.",
    "That server has VAC (Steam anti-cheat) on. KF2-VR can only join servers with VAC off.":
        "На этом сервере включён VAC (античит Steam). KF2-VR может подключаться только к серверам без VAC.",
    "That map isn't installed. Pick a different map.": "Эта карта не установлена. Выберите другую.",
    "That join code isn't valid. Copy the whole code from your friend again.":
        "Код подключения недействителен. Скопируйте код друга целиком ещё раз.",
    "Your friend has a different KF2-VR version. You both need the same version.":
        "У друга другая версия KF2-VR. Вам обоим нужна одна и та же версия.",
    "This KF2-VR package can't use DLSS. Set DLSS to Off in Graphics.":
        "Этот пакет KF2-VR не может использовать DLSS. Выключите DLSS в настройках графики.",

    # ----- Game & headset ----------------------------------------------------------------------
    "Your copy of the game and your headset, plus first-time setup, updates and resets.":
        "Ваша копия игры и шлем, а также первая настройка, обновления и сброс.",
    "Your copy of the game and your headset.": "Ваша копия игры и шлем.",
    "Killing Floor 2 on {0}": "Killing Floor 2 в {0}",
    "Killing Floor 2 on {0} (experimental: Solo in VR only)": "Killing Floor 2 в {0} (экспериментально: только соло в VR)",
    "KF2-VR uses the headset app that's running on this PC.": "KF2-VR использует приложение шлема, запущенное на этом ПК.",
    "Start SteamVR, Quest Link or your headset's PC app; you can also play on a flat screen.":
        "Запустите SteamVR, Quest Link или ПК-приложение вашего шлема; можно также играть на обычном мониторе.",
    "If Killing Floor 2 is installed, start it from Steam once, then press Check again. Installed somewhere KF2-VR "
    "can't see? Choose its folder.":
        "Если Killing Floor 2 установлена, один раз запустите её из Steam и нажмите «Проверить снова». Установлена "
        "там, где KF2-VR её не видит? Укажите её папку.",
    "Get Killing Floor 2 on Steam": "Купить Killing Floor 2 в Steam",
    "Choose game folder…": "Выбрать папку игры…",
    "With the Epic copy you can play Solo in VR only; hosting and joining friends need the Steam copy.":
        "С копией из Epic доступна только одиночная игра в VR; для хоста и подключения к друзьям нужна Steam-версия.",
    "Headset app": "Приложение шлема",
    # Headset app names stay as their makers write them.
    "Virtual Desktop": "Virtual Desktop", "SteamVR": "SteamVR", "Meta Quest Link": "Meta Quest Link",
    "Windows Mixed Reality": "Windows Mixed Reality", "PICO Connect": "PICO Connect",
    "Run first-time setup again": "Пройти первую настройку заново",
    "Hand, seated mode, movement, turning, reloads and graphics on one page.":
        "Рука, режим сидя, передвижение, повороты, перезарядка и графика на одной странице.",
    "Reset all settings": "Сбросить все настройки",
    "RESET": "СБРОС",
    "Puts every setting back to its default. Kept: your calibration, saved matches, game copy and host details.":
        "Возвращает все настройки к значениям по умолчанию. Сохраняются калибровка, сохранённые матчи, выбор копии "
        "игры и данные хоста.",
    "Reset all settings?": "Сбросить все настройки?",
    "This puts every setting back to its default.": "Все настройки вернутся к значениям по умолчанию.",
    "Your calibration, saved matches, game copy and host details are kept.":
        "Калибровка, сохранённые матчи, выбор копии игры и данные хоста сохранятся.",
    "Developer": "Разработчик",
    "Developer tools": "Инструменты разработчика",
    "Recording, highlight logging and frame timings for this launch.":
        "Запись, журнал ярких моментов и время кадров для этого запуска.",
    "This launch only.": "Только для этого запуска.",
    "VR only. Local files; no video, audio or automatic sharing. Never saved: every new window starts with these off. "
    "Local agent test control is on the Solo page.":
        "Только VR. Локальные файлы; без видео, звука и автоматической отправки. Не сохраняется: каждое новое окно "
        "открывается с этими параметрами выключенными. Тестовое управление агентом — на странице одиночного матча.",
    "Checkout": "Рабочая копия",
    "Workspace: {0}": "Рабочая папка: {0}",
    "Selected build: {0}": "Выбранная сборка: {0}",
    "This build is older than the source (allowed for this window).":
        "Эта сборка старше исходников (разрешено для этого окна).",
    "Not that folder": "Не та папка",
    "That folder doesn't contain Killing Floor 2. Look for the killingfloor2 folder inside steamapps\\common or your "
    "Epic Games folder.":
        "В этой папке нет Killing Floor 2. Найдите папку killingfloor2 внутри steamapps\\common или в папке Epic Games.",
    "Couldn't use that folder": "Не удалось использовать эту папку",
    "KF2-VR can't write to {0}. Pick another folder. ({1})": "KF2-VR не может писать в {0}. Выберите другую папку. ({1})",
    "Can't use this copy": "Эту копию нельзя использовать",
    "This copy of Killing Floor 2 doesn't match this KF2-VR version. Let Steam or Epic finish updating it, or get the "
    "newest KF2-VR.":
        "Эта копия Killing Floor 2 не подходит к этой версии KF2-VR. Дайте Steam или Epic закончить обновление или "
        "скачайте новейшую KF2-VR.",
    "Selected package changed": "Выбранный пакет изменился",
    "The selected package changed while this window was open. Reopen Play-KF2VR.cmd.":
        "Выбранный пакет изменился, пока было открыто это окно. Перезапустите Play-KF2VR.cmd.",
    "Play this older build?": "Запустить эту старую сборку?",
    "The selected package is older than the current source. Its files are intact.":
        "Выбранный пакет старше текущих исходников. Его файлы не повреждены.",
    "Play older build": "Запустить старую сборку",

    # ----- Help --------------------------------------------------------------------------------
    "Getting started, playing with friends, and what to do when something goes wrong.":
        "Начало работы, игра с друзьями и что делать, если что-то пошло не так.",
    "Getting started": "Начало работы",
    "Start your headset's PC app: SteamVR, Quest Link or Virtual Desktop.":
        "Запустите ПК-приложение шлема: SteamVR, Quest Link или Virtual Desktop.",
    "Press Play solo, or choose a match. (Play opens once first-time setup is done.)":
        "Нажмите «Играть соло» или выберите матч. (Страница «Играть» откроется после первой настройки.)",
    "On the Play page, press Play solo or choose a match.":
        "На странице «Играть» нажмите «Играть соло» или выберите матч.",
    "In the game, open {0} to tune feel and fit.": "Откройте {0}, чтобы настроить ощущения и посадку рук.",
    "Press the Menu button on your left controller, or press and hold both sticks.":
        "Нажмите кнопку «Меню» на левом контроллере или нажмите и удерживайте оба стика.",
    "The in-game VR menu": "VR-меню игры",
    "the in-game VR menu": "VR-меню игры",
    "It has the same comfort, hands and graphics settings as Settings here, plus snap angle, turn speed, height and hand fit.":
        "В нём те же настройки комфорта, рук и графики, что и здесь, а также угол поворота рывком, скорость "
        "поворота, рост и посадка рук.",
    "Playing with friends": "Игра с друзьями",
    "Host a game and send friends its code; they press Join a friend and paste it. You all need the same KF2-VR version.":
        "Создайте игру и отправьте друзьям её код; они нажимают «К другу» и вставляют его. У всех должна быть одна "
        "и та же версия KF2-VR.",
    "If something goes wrong": "Если что-то пошло не так",
    "The game opens on the monitor, not in the headset": "Игра открывается на мониторе, а не в шлеме",
    "Start your headset app before you press Play. {0} shows the headset app KF2-VR found; press Check again there after "
    "starting it.":
        "Запустите приложение шлема до нажатия «Играть». На странице «{0}» видно, какое приложение шлема нашёл "
        "KF2-VR; после его запуска нажмите там «Проверить снова».",
    "Friends can't join": "Друзья не могут подключиться",
    "You all need the same KF2-VR version. Friends on another network may need port forwarding: Host a game says how.":
        "У всех должна быть одна и та же версия KF2-VR. Друзьям из другой сети может понадобиться проброс портов: "
        "как это сделать, сказано на странице «Создать игру».",
    "The game won't start after a crash": "Игра не запускается после вылета",
    "Use Repair below, then press Play again.": "Нажмите «Восстановить» ниже и снова нажмите «Играть».",
    "Repair and bug reports": "Восстановление и отчёты об ошибках",
    "Repair after a crash": "Восстановить после вылета",
    "If the game crashed or was closed from Task Manager, this puts Killing Floor 2 back to normal and keeps your "
    "settings. Close the game first.":
        "Если игра вылетела или была закрыта через диспетчер задач, это вернёт Killing Floor 2 в обычное состояние "
        "и сохранит ваши настройки. Сначала закройте игру.",
    "Repair": "Восстановить",
    "Save logs for a bug report": "Сохранить логи для отчёта об ошибке",
    "Asks where to save, then saves a ZIP of your logs with personal details removed and opens its folder.":
        "Спрашивает, куда сохранить, затем сохраняет ZIP с логами без личных данных и открывает его папку.",
    "Save logs": "Сохранить логи",
    "Report a bug": "Сообщить об ошибке",
    "Opens the KF2-VR thread on the Flat2VR Discord; attach your logs and say what happened.":
        "Открывает ветку KF2-VR в Discord Flat2VR; приложите логи и опишите, что случилось.",
    "Logs folder": "Папка с логами",
    "The raw logs on this PC; they aren't anonymized, so keep them private.":
        "Исходные логи на этом ПК; они не обезличены, поэтому не публикуйте их.",
    "Open folder": "Открыть папку",
    "About": "О программе",
    "KF2-VR {0}": "KF2-VR {0}",
    "Made by Kvasir94 and optimumbox.": "Авторы: Kvasir94 и optimumbox.",
    "Epic Games support is experimental: Solo in VR only.": "Поддержка Epic Games экспериментальная: только соло в VR.",
    "A fan project, not affiliated with Tripwire Interactive. The hands, gloves and watch come from Killing Floor 2's own "
    "first-person arms; their rights stay with their owners.":
        "Фанатский проект, не связанный с Tripwire Interactive. Руки, перчатки и часы взяты из собственных рук от "
        "первого лица Killing Floor 2; права на них принадлежат их владельцам.",
    "Post it with Help > Report a bug": "Отправьте его через «Помощь» > «Сообщить об ошибке»",
    "Couldn't gather logs": "Не удалось собрать логи",
    "Logs ready": "Логи готовы",
    "Your logs are copied. {0}: click in the message box, press Ctrl+V, and say what you were doing when it went wrong.":
        "Логи скопированы. {0}: щёлкните в поле сообщения, нажмите Ctrl+V и опишите, что вы делали, когда "
        "возникла проблема.",
    "{0}: drag the highlighted file into your report and say what you were doing.":
        "{0}: перетащите выделенный файл в сообщение и опишите, что вы делали.",
    "Saved as {0}; its folder just opened with the file selected. Personal paths, names, account IDs and addresses are "
    "anonymized, and passwords and join codes are removed. Review the ZIP before sharing it.":
        "Сохранено как {0}; его папка открыта, файл выделен. Личные пути, имена, ID аккаунтов и адреса обезличены, "
        "пароли и коды подключения удалены. Проверьте ZIP перед отправкой.",
    "Couldn't fix it yet": "Пока не удалось исправить",
    "Partly fixed": "Исправлено частично",
    "Some things couldn't be fixed automatically. Press {0}.": "Часть проблем не удалось исправить автоматически. Нажмите «{0}».",
    "All fixed": "Всё исправлено",
    "Killing Floor 2 is back to normal.": "Killing Floor 2 возвращена в обычное состояние.",

    # ----- Graphics and controls dialogs -------------------------------------------------------
    "These apply to every match, and save as you choose. More options are in Settings › Graphics & HUD.":
        "Применяются ко всем матчам и сохраняются сразу. Больше параметров — в «Настройки › Графика и HUD».",
    "Use Graphics preset: {0}?": "Выбрать пресет графики «{0}»?",
    "This replaces the values you changed by hand.": "Это заменит значения, которые вы меняли вручную.",
    "Use {0}": _use,
    "Use {0}: {1}?": "{0}: выбрать «{1}»?",
    "and {0} more": "и ещё {0}",
    "Your controls": "Ваше управление",
    "With your current settings: {0}-handed, grip mode {1}, reload mode {2}.": _handed,
    "LEFT HAND": "ЛЕВАЯ РУКА",
    "RIGHT HAND": "ПРАВАЯ РУКА",
    "GUN HAND": "РУКА С ОРУЖИЕМ",
    "MOVEMENT HAND": "РУКА ПЕРЕДВИЖЕНИЯ",
    "BOTH HANDS": "ОБЕ РУКИ",
    "Stick": "Стик",
    "Move. Click it to sprint.": "Ходьба. Нажмите стик, чтобы бежать.",
    "Turn.": "Поворот.",
    "Pull down to crouch.": "Потяните вниз, чтобы присесть.",
    "Menu button": "Кнопка «Меню»",
    "Open {0}.": "Открыть {0}.",
    "Reload the gun in that hand.": "Перезарядить оружие в этой руке.",
    "Eject the mag from the gun in that hand; you rack it yourself.":
        "Выбросить магазин из оружия в этой руке; затвор передёргиваете сами.",
    "Eject the mag from the gun in that hand; an empty trigger also starts a reload.":
        "Выбросить магазин из оружия в этой руке; нажатие спуска на пустом оружии тоже начинает перезарядку.",
    "Hold it to change fire mode. (X or A on Quest.)": "Удерживайте, чтобы сменить режим огня. (X или A на Quest.)",
    "Hold it to change fire mode.": "Удерживайте, чтобы сменить режим огня.",
    "(X or A on Quest.)": "(X или A на Quest.)",
    "Trigger": "Спуск",
    "Fire the gun in that hand, or pick a menu item.": "Выстрел из оружия в этой руке или выбор пункта меню.",
    "Grip": "Хват",
    "Grab gear or brace a gun; at your chest, take a grenade and let go to throw.":
        "Взять предмет или поддержать оружие; у груди — взять гранату и отпустить, чтобы бросить.",
    "Point an open hand at a pickup and flick to pull it to you.":
        "Направьте открытую ладонь на предмет и дёрните рукой, чтобы притянуть его.",
    "Lower button": "Нижняя кнопка",
    "Upper button": "Верхняя кнопка",
    "Open that hand's weapon wheel. (Y or B on Quest.)": "Открыть колесо оружия этой руки. (Y или B на Quest.)",
    "Both sticks": "Оба стика",
    "Press and hold both to open {0}.": "Нажмите и удерживайте оба, чтобы открыть {0}.",

    # ----- Settings page -----------------------------------------------------------------------
    "Changes save automatically. ★ marks our recommendation.":
        "Изменения сохраняются автоматически. ★ — наша рекомендация.",
    "Search settings": "Поиск настроек",
    "Essentials": "Основное",
    "View your controls": "Посмотреть управление",
    "Reset {0}…": "Сбросить «{0}»…",
    "Reset {0}?": "Сбросить «{0}»?",
    "This puts {0} back to the defaults.": "Раздел «{0}» вернётся к значениям по умолчанию.",
    "Back to {0}": "Вернуть «{0}»",
    "Set by the {0}; changing one makes it Custom.":
        "Эти значения задаёт настройка «{0}»; если изменить любое из них, она станет «Свой».",
    "{0} settings": _settings,
    "{0} setting": _settings,
    "{0} appears when you choose {1}.": "{0}: появится, если выбрать {1}.",
    "{0} appear when you choose {1}.": "{0}: появятся, если выбрать {1}.",
    "More settings are in {0}.": "Другие настройки — в {0}.",
    "{0} and in {1}": "{0} и в {1}",
    "Killing Floor 2's own Options menu": "меню «Параметры» самой Killing Floor 2",
    "In Killing Floor 2's own Options menu": "В меню «Параметры» самой Killing Floor 2",
    "In {0}, {1}": "В {0}: {1}",
    "{0}: in {1}, {2}.": "{0}: в {1}, раздел {2}.",
    "{0}: in Killing Floor 2's own Options menu.": "{0}: в меню «Параметры» самой Killing Floor 2.",
    "More {0} settings are in Killing Floor 2's own Options menu.":
        "Другие настройки ({0}) — в меню «Параметры» самой Killing Floor 2.",
    "More {0} switches are in {1}: {2}.": "Другие переключатели ({0}) — в {1}: {2}.",
    "No settings match “{0}”.": Verbatim("Нет настроек, подходящих под «{0}».", 0),
    "Try another word, such as reload, turn or shadows.": "Попробуйте другое слово, например «перезарядка», «поворот» или «тени».",
    "{0} result for “{1}”": Verbatim(lambda n, q: f"{n} {plural(n, 'результат', 'результата', 'результатов')} "
                                               f"по запросу «{q}»", 1),
    "{0} results for “{1}”": Verbatim(lambda n, q: f"{n} {plural(n, 'результат', 'результата', 'результатов')} "
                                                f"по запросу «{q}»", 1),
    "“{0}” is set outside the launcher": Verbatim("«{0}» настраивается вне лаунчера", 0),
    "Set elsewhere": "Настраивается в другом месте",
    "Solo only": "Только соло",
    "Not available with the current settings": "Недоступно при текущих настройках",
    "Enter {0}–{1} {2}": "Введите {0}–{1} {2}",
    "Enter {0}–{1}": "Введите {0}–{1}",
    "{0} must be between {1} and {2} {3}.": "{0}: значение должно быть от {1} до {2} {3}.",
    "{0} must be between {1} and {2} .": "{0}: значение должно быть от {1} до {2}.",
    "other options": "другие варианты",
    "with other choices": "при других вариантах",
    "Hand and gun fit": "Посадка рук и оружия",
    "hand fit": "посадка рук",
    "Calibrate height": "Калибровка роста",
    "Calibrate hands, gun, pouch, grenade": "Калибровка рук, оружия, подсумка, гранаты",
    "Calibrate menu, watch & ammo counter": "Калибровка меню, часов и счётчика патронов",
    "Calibrate menu position": "Положение меню",
    "Calibrate watch and ammo counter": "Положение часов и счётчика патронов",
    "Snap angle": "Угол поворота рывком",
    "Turn speed": "Скорость поворота",
    "Menu position": "Положение меню",
    "Watch position": "Положение часов",
    # Lower-case forms the Settings page builds sentences from.
    "reload mode": "режим перезарядки", "grip mode": "режим хвата", "ammo rules": "правила боеприпасов",
    "HUD preset": "Пресет HUD", "graphics preset": "пресет графики", "locomotion": "передвижение",
    "teleport": "телепорт", "reload": "перезарядка", "grip": "хват", "aim & bullet path": "прицел и траектория",
    "movement": "передвижение", "weapon wheel": "колесо оружия", "image": "изображение", "hud": "HUD",
    "menu": "меню", "body": "тела", "gore limit": "лимиты расчленения", "gore lifetime": "время расчленения",
    "screen effect": "эффекты на экране", "music & dialogue": "музыка и диалоги", "shadow tuning": "тени",
    "pickups & zed grabs": "подбор и захват мутантов", "melee": "ближний бой", "customize": "дополнительно",
    "more": "прочее", "corpse physics": "физика трупов", "effect lifetimes": "время эффектов",
    "gore & bodies": "кровь и тела", "hud & menus": "HUD и меню",
    # What to choose for hidden settings to show: "...appear when you choose <this>" (accusative in Russian).
    "snap turning": "поворот рывками", "smooth turning": "плавный поворот", "teleport movement": "передвижение телепортом",
    "Manual or Realistic reloads": "перезарядку «Вручную» или «Реалистично»",
    "lost rounds in dropped mags": "потерю патронов в сброшенных магазинах",
    "custom aim assist": "свою помощь в прицеливании", "the laser sight on": "включённый лазерный прицел",
    "auto-return on": "включённый автовозврат", "DLSS on": "включённый DLSS",

    # ----- settings-definition.json: categories and first-time setup --------------------------
    "Comfort": "Комфорт",
    "How you move and turn, and staying comfortable in VR.": "Как вы ходите и поворачиваетесь, и комфорт в VR.",
    "Customize comfort": "Настроить комфорт",
    "Your height calibration is kept.": "Калибровка роста сохранится.",
    "Hands & Weapons": "Руки и оружие",
    "How you hold, reload and aim, and what you can grab.": "Как вы держите оружие, перезаряжаетесь и целитесь, и что можно хватать.",
    "Customize hands & weapons": "Настроить руки и оружие",
    "Your hand and gun calibration is kept.": "Калибровка рук и оружия сохранится.",
    "Graphics & HUD": "Графика и HUD",
    "How the game looks, and what you see on your watch and gun.": "Как выглядит игра и что показывают часы и оружие.",
    "Customize graphics & HUD": "Настроить графику и HUD",
    "Your menu, watch and ammo counter placement is kept.": "Положение меню, часов и счётчика патронов сохранится.",
    "Audio": "Звук",
    "Your microphone in VR.": "Ваш микрофон в VR.",
    "Customize audio": "Настроить звук",
    "Online, the host's setting applies": "В сетевой игре действует настройка хоста",
    "Online, the host's setting applies.": "В сетевой игре действует настройка хоста.",
    "A few choices to start with; you can change any of them later in Settings. ★ marks our recommendation.":
        "Несколько вариантов для начала; любой из них потом можно изменить в настройках. ★ — наша рекомендация.",
    "Dominant hand": "Ведущая рука",
    "Seated mode": "Режим сидя",
    "Locomotion": "Передвижение",
    "Grip mode": "Режим хвата",
    "Reload mode": "Режим перезарядки",
    "Ammo rules": "Правила боеприпасов",
    "Graphics preset": "Пресет графики",
    "Damage numbers": "Числа урона",
    "Left-handed: your watch is on your right wrist and you move with the right stick.":
        "Левша: часы на правом запястье, ходьба правым стиком.",
    "Right-handed: your watch is on your left wrist and you move with the left stick.":
        "Правша: часы на левом запястье, ходьба левым стиком.",
    "Play standing up.": "Игра стоя.",
    "Raises your view so you can play sitting down.": "Поднимает обзор, чтобы можно было играть сидя.",
    "Turn in quick 30° steps (change the angle in the in-game VR menu).":
        "Поворот быстрыми шагами по 30° (угол меняется в VR-меню игры).",
    "Turn smoothly.": "Плавный поворот.",
    "No numbers when you hit Zeds.": "Без чисел при попадании по мутантам.",
    "Shows the damage you deal over Zeds' heads.": "Показывает нанесённый урон над головами мутантов.",
    "show with Manual or Realistic reloads": "появляется при перезарядке «Вручную» или «Реалистично»",

    # ----- presets -----------------------------------------------------------------------------
    "How you reload and cycle guns.": "Как вы перезаряжаете оружие и досылаете патрон.",
    "Button": "Кнопка",
    "Press a button to reload; guns rack and cycle themselves, as in the normal game.":
        "Перезарядка кнопкой; затвор передёргивается сам, как в обычной игре.",
    "press a button, guns cycle themselves": "кнопкой, затвор передёргивается сам",
    "Manual": "Вручную",
    "Swap mags and rack slides, bolts and pumps by hand. An empty trigger pull starts the reload and a new mag pushes "
    "out the old one.":
        "Меняйте магазины и передёргивайте затворы, рукоятки и цевьё руками. Спуск на пустом оружии начинает "
        "перезарядку, а новый магазин выталкивает старый.",
    "mags and racking by hand, with help": "магазины и затвор руками, с подсказками",
    "Realistic": "Реалистично",
    "Everything by hand, with no help: eject the old mag yourself, rack slides, bolts and pumps, and you can rack a "
    "loaded gun.":
        "Всё руками, без помощи: сами выбрасываете старый магазин, передёргиваете затворы, рукоятки и цевьё; можно "
        "передёрнуть и заряженное оружие.",
    "everything by hand, no help": "всё руками, без помощи",
    "How rounds are counted when you reload by hand.": "Как считаются патроны при ручной перезарядке.",
    "Rounds are counted as in the normal game.": "Патроны считаются как в обычной игре.",
    "counted as in the normal game": "считаются как в обычной игре",
    "A reload keeps the round in the chamber, and a dropped mag's rounds are lost unless you pick it up.":
        "При перезарядке патрон в патроннике сохраняется, а патроны сброшенного магазина теряются, если его не "
        "подобрать.",
    "chambered rounds and dropped mags count": "учитываются патрон в патроннике и сброшенные магазины",
    "How grip holds guns in each hand.": "Как кнопка хвата удерживает оружие в каждой руке.",
    "Mixed": "Смешанный",
    "One press holds a gun in your gun hand; your other hand holds only while you squeeze.":
        "В руке с оружием оно удерживается одним нажатием; другая рука держит, только пока вы сжимаете хват.",
    "one press holds the gun": "одно нажатие удерживает оружие",
    "Hold": "Удержание",
    "Both hands hold only while you squeeze grip.": "Обе руки держат, только пока вы сжимаете хват.",
    "keep squeezing": "держите сжатым",
    "Toggle": "Переключение",
    "Both hands: press grip to hold, press again to let go.":
        "Обе руки: нажмите хват, чтобы взять, и ещё раз — чтобы отпустить.",
    "press once to hold, again to let go": "нажать, чтобы взять, ещё раз — отпустить",
    "Smooth or Teleport movement, with Snap or Smooth turning.":
        "Плавное передвижение или телепорт, с поворотом рывками или плавным поворотом.",
    "Smooth + Snap turn": "Плавно + рывками",
    "Smooth + Smooth turn": "Плавно + плавный поворот",
    "Teleport + Snap turn": "Телепорт + рывками",
    "Teleport + Smooth turn": "Телепорт + плавный поворот",
    "What the watch and gun show you.": "Что показывают часы и оружие.",
    "Full": "Полный",
    "Watch and the ammo counter on the gun.": "Часы и счётчик патронов на оружии.",
    "watch and ammo counter": "часы и счётчик патронов",
    "Minimal": "Минимум",
    "Watch only.": "Только часы.",
    "watch only": "только часы",
    "Overall detail and lighting. Render scale, DLSS, Bloom and Gore & bodies are separate settings.":
        "Общая детализация и освещение. Масштаб рендеринга, DLSS, засветка и «Кровь и тела» — отдельные настройки.",
    "Quality": "Качество",
    "The most detail and lighting; needs a fast graphics card.": "Максимум деталей и освещения; нужна быстрая видеокарта.",
    "Balanced": "Баланс",
    "Less detail and lighting, for a steadier frame rate.": "Меньше деталей и освещения ради более стабильной частоты кадров.",
    "Performance": "Производительность",
    "The least detail, for the highest frame rate.": "Минимум деталей ради максимальной частоты кадров.",

    # ----- Comfort settings --------------------------------------------------------------------
    "How the stick moves you.": "Как стик перемещает вас.",
    "Smooth": "Плавно",
    "Teleport": "Телепорт",
    "Walk with the stick.": "Ходьба стиком.",
    "Aim with the stick and let go to jump there.": "Наведите стиком и отпустите, чтобы переместиться туда.",
    "Turning": "Поворот",
    "How the turning stick turns you.": "Как стик поворота поворачивает вас.",
    "Snap turn": "Рывками",
    "Smooth turn": "Плавный",
    "Turn in quick steps (30° unless you change it in the in-game VR menu).":
        "Поворот быстрыми шагами (30°, если не изменить в VR-меню игры).",
    "Turn smoothly while you hold the stick.": "Плавный поворот, пока стик отклонён.",
    "Degrees per snap turn. 30° is the default.": "Градусов за один поворот рывком. По умолчанию 30°.",
    "Only with snap turning": "Только при повороте рывками",
    "How fast Smooth turn turns you.": "Как быстро работает плавный поворот.",
    "Only with smooth turning": "Только при плавном повороте",
    "Movement direction": "Направление движения",
    "Which way pushing the stick forward takes you.": "Куда вы идёте, когда толкаете стик вперёд.",
    "Head": "Голова",
    "Hand": "Рука",
    "Where you look.": "Туда, куда смотрите.",
    "Where your movement hand points.": "Туда, куда указывает рука передвижения.",
    "where you look": "куда смотрите",
    "where your hand points": "куда указывает рука",
    "Raises your view for playing seated; set your seated height in the in-game VR menu.":
        "Поднимает обзор для игры сидя; рост сидя задаётся в VR-меню игры.",
    "Stand or sit as you play and recapture your height.": "Встаньте или сядьте, как будете играть, и заново замерьте рост.",
    "Haptic intensity": "Сила вибрации",
    "Controller vibration. 0% turns it off.": "Вибрация контроллеров. 0% — выключить.",
    "Weapon wheel slow-mo": "Замедление у колеса оружия",
    "Solo only: the world slows while you choose a weapon.": "Только соло: мир замедляется, пока вы выбираете оружие.",
    "Shows the first-time setup choices again.": "Снова показывает варианты первой настройки.",
    "Stick crouch": "Присед стиком",
    "Pull the turning stick down to crouch.": "Потяните стик поворота вниз, чтобы присесть.",
    "Movement": "Передвижение",
    "Auto-turn on Clot grab": "Автоповорот при захвате зомби",
    "Turn toward a Clot that grabs you.": "Поворачивать вас к зомби (Clot), который вас схватил.",
    "Teleport blink": "Затемнение при телепорте",
    "A brief fade when you teleport.": "Короткое затемнение во время телепорта.",
    "Only with teleport movement": "Только при передвижении телепортом",
    "Teleport fade out": "Затемнение перед телепортом",
    "How long the view takes to fade out.": "Сколько длится затемнение обзора.",
    "Teleport fade in": "Проявление после телепорта",
    "How long the view takes to come back.": "Сколько длится возвращение обзора.",
    "Teleport facing": "Направление после телепорта",
    "Pick which way you face when you land, instead of keeping your facing.":
        "Выбирать, куда вы будете смотреть после перемещения, вместо сохранения направления.",
    "Solo world speed at the wheel": "Скорость мира у колеса (соло)",
    "How slow the world gets while Weapon wheel slow-mo is on.":
        "Насколько замедляется мир, когда включено замедление у колеса оружия.",
    "Weapon wheel": "Колесо оружия",

    # ----- Hands & Weapons settings ------------------------------------------------------------
    "Your main hand. The watch and HUD go on your other wrist, and movement and the menu switch hands to match.":
        "Ваша основная рука. Часы и HUD — на другом запястье, а передвижение и меню переходят на соответствующие руки.",
    "Left": "Левая",
    "Right": "Правая",
    "Movement hand": "Рука передвижения",
    "The hand whose stick moves you; it follows Dominant hand unless you change it.":
        "Рука, стик которой отвечает за ходьбу; следует за ведущей рукой, если не изменить.",
    "Reload hints": "Подсказки перезарядки",
    "Glows and rings showing where the next reload step goes.": "Подсветка и кольца показывают следующий шаг перезарядки.",
    "Point at a gun or pickup and flick to pull it to your hand.":
        "Наведите руку на оружие или предмет и дёрните, чтобы притянуть его.",
    "Laser sight": "Лазерный прицел",
    "A laser from the gun you hold shows where it will hit.": "Лазер из оружия в руке показывает, куда оно попадёт.",
    "Gun pitch": "Наклон оружия",
    "Independent gun-angle calibration. Adjust with a live preview in headset.":
        "Отдельная калибровка угла оружия. Настраивайте в шлеме с живым предпросмотром.",
    "Gun yaw": "Поворот оружия",
    "Gun roll": "Крен оружия",
    "Hand forward": "Рука вперёд",
    "Saved physical offset. Use the headset editor to see the actual fit or pickup volume.":
        "Сохранённое физическое смещение. Реальную посадку или зону подбора видно в редакторе в шлеме.",
    "cm": "см",
    "m": "м",
    "s": "с",
    "Hand outward": "Рука наружу",
    "Hand height": "Высота руки",
    "Grenade zone size": "Размер зоны гранат",
    "Size of the actual pickup volume. Both ammunition pouches remain permanently linked; position them in headset.":
        "Размер зоны подбора. Оба подсумка с боеприпасами всегда связаны; располагайте их в шлеме.",
    "Ammo pouch size": "Размер подсумка",
    "Grenade forward": "Граната вперёд",
    "Grenade side": "Граната вбок",
    "Grenade height": "Высота гранаты",
    "Pouch forward": "Подсумок вперёд",
    "Pouch width": "Ширина подсумка",
    "Pouch height": "Высота подсумка",
    "Manual reloading": "Ручная перезарядка",
    "Reload and cycle guns by hand. Off: X / A reloads.": "Перезарядка и досылание патрона руками. Выкл: перезарядка на X / A.",
    "Reloads": "Перезарядка",
    "Rack a loaded gun": "Передёргивать заряженное оружие",
    "Working the action on a loaded gun throws out the chambered round, which is lost.":
        "Если передёрнуть затвор заряженного оружия, патрон из патронника вылетит и потеряется.",
    "Auto-eject on empty trigger": "Автосброс магазина при пустом спуске",
    "Pulling the trigger on an empty gun ejects the mag, as X / A does, instead of clicking.":
        "Спуск на пустом оружии выбрасывает магазин, как X / A, вместо щелчка.",
    "Only with Manual or Realistic reloads": "Только при перезарядке «Вручную» или «Реалистично»",
    "Auto-eject on new mag": "Автосброс при новом магазине",
    "Taking a mag from your pouch drops the one in the gun, so you don't eject it first.":
        "Когда вы берёте магазин из подсумка, старый выпадает сам, и его не нужно выбрасывать заранее.",
    "Button ejects a full mag": "Кнопка сбрасывает полный магазин",
    "X / A drops the mag even when it's full; a part-used mag always drops.":
        "X / A сбрасывает магазин, даже если он полный; начатый магазин сбрасывается всегда.",
    "Sprint while reloading": "Бег во время перезарядки",
    "Keep running while you reload by hand instead of pausing your sprint.":
        "Продолжать бег при ручной перезарядке, а не прерывать его.",
    "Perk reload assist": "Помощь навыка при перезарядке",
    "Perks that reload faster also guide mags into the gun.":
        "Навыки с быстрой перезарядкой ещё и помогают вставить магазин в оружие.",
    "Keep chambered round": "Сохранять патрон в патроннике",
    "A reload before the gun is empty keeps the round in the chamber.":
        "При перезарядке до опустошения патрон в патроннике сохраняется.",
    "Dropped mags lose their rounds": "Сброшенные магазины теряют патроны",
    "Rounds left in a mag you drop, or live rounds you eject from a cylinder, are lost.":
        "Патроны в сброшенном магазине и выброшенные из барабана целые патроны теряются.",
    "Recover dropped mags": "Подбор сброшенных магазинов",
    "Pick a dropped mag back up to get its rounds back.": "Подберите сброшенный магазин, чтобы вернуть его патроны.",
    "Only with lost rounds in dropped mags": "Только если патроны в сброшенных магазинах теряются",
    "Main grip": "Основной хват",
    "Toggle: a grabbed gun stays in your hand until you drop it. Hold: keep squeezing.":
        "Переключение: взятое оружие остаётся в руке, пока вы его не бросите. Удержание: держите хват сжатым.",
    "Support grip": "Вспомогательный хват",
    "Hold: squeeze to keep your other hand on pumps and grips. Toggle: press once on, once off.":
        "Удержание: сжимайте, чтобы другая рука оставалась на цевье и рукоятках. Переключение: нажатие — взять, ещё "
        "нажатие — отпустить.",
    "Support-hand carry": "Удержание второй рукой",
    "Let go with your gun hand and your other hand keeps holding a two-handed gun by its foregrip. It can't fire until "
    "your gun hand takes it back; letting go then drops it.":
        "Если отпустить оружие основной рукой, вторая продолжит держать двуручное оружие за цевьё. Стрелять нельзя, "
        "пока основная рука его не возьмёт; если отпустить и вторую — оружие упадёт.",
    "Gun angle": "Угол оружия",
    "How guns sit in your hand. Fine-tune the fit in the in-game VR menu.":
        "Как оружие лежит в руке. Точную посадку настройте в VR-меню игры.",
    "Relaxed wrist": "Расслабленное запястье",
    "Straight": "Прямо",
    "Two-handed aiming": "Прицеливание двумя руками",
    "Both hands steer a two-handed gun; when off, the gun hand aims and the other hand only braces.":
        "Двуручным оружием управляют обе руки; если выключено, целится основная рука, а вторая только поддерживает.",
    "Aim assist": "Помощь в прицеливании",
    "Helps shots that only just miss.": "Помогает выстрелам, которые чуть-чуть промахиваются.",
    "Aim & bullet path": "Прицел и траектория",
    "Shots go exactly where you aim.": "Выстрелы летят точно туда, куда вы целитесь.",
    "Shots that just miss are nudged onto the head, as the game does for gamepads.":
        "Чуть промахнувшиеся выстрелы смещаются в голову, как игра делает для геймпадов.",
    "Your own strength and range, set in the in-game VR menu.": "Своя сила и дальность, задаются в VR-меню игры.",
    "no help": "без помощи",
    "nudges near misses onto the head": "смещает почти попавшие выстрелы в голову",
    "your own strength and range": "своя сила и дальность",
    "Aim assist strength": "Сила помощи в прицеливании",
    "How strongly a near miss is pulled to the head. 100% is the game's normal amount.":
        "Насколько сильно почти попавший выстрел притягивается к голове. 100% — обычное значение игры.",
    "Only with custom aim assist": "Только при своей помощи в прицеливании",
    "Aim assist area": "Зона помощи в прицеливании",
    "How far from the head a shot can land and still get help. 100% is the game's normal area.":
        "Как далеко от головы может пройти выстрел и всё ещё получить помощь. 100% — обычная зона игры.",
    "Aim assist min range": "Мин. дистанция помощи",
    "Closer shots get no help. Can't be more than the max range.":
        "Ближе этой дистанции помощи нет. Не может быть больше максимальной дистанции.",
    "Aim assist max range": "Макс. дистанция помощи",
    "Farther shots get no help. Up to 100 m; can't be less than the min range.":
        "Дальше этой дистанции помощи нет. До 100 м; не может быть меньше минимальной дистанции.",
    "Bullet path": "Траектория пуль",
    "Bullets always leave the muzzle; this sets where they fly to. Guns with no sights always shoot along the barrel.":
        "Пули всегда вылетают из дула; эта настройка задаёт, куда они летят. Оружие без прицела всегда стреляет "
        "вдоль ствола.",
    "Sight line": "Линия прицела",
    "Barrel": "Ствол",
    "Meet at 20 m": "Сведение на 20 м",
    "From the muzzle to whatever your sights are on, so shots land on the sights at any range.":
        "От дула туда, куда наведён прицел, поэтому выстрелы попадают в прицел на любой дистанции.",
    "From the muzzle straight along the barrel, like a real gun, so shots land a little below the sights.":
        "От дула прямо вдоль ствола, как у настоящего оружия, поэтому выстрелы ложатся чуть ниже прицела.",
    "From the muzzle to the spot your sights are on 20 m away: on target at 20 m, a little low closer and a little high "
    "farther out.":
        "От дула в точку прицела на 20 м: точно на 20 м, чуть ниже на меньших дистанциях и чуть выше на больших.",
    "lands on your sights at any range": "попадает в прицел на любой дистанции",
    "straight along the barrel": "прямо вдоль ствола",
    "on your sights at 20 m only": "в прицел только на 20 м",
    "Laser source": "Источник лазера",
    "The gun's own laser emitter where it has one, or the barrel.": "Собственный лазерный модуль оружия, если он есть, или ствол.",
    "Only with the laser sight on": "Только с включённым лазерным прицелом",
    "Gun's emitter": "Модуль оружия",
    "Auto-return dropped guns": "Автовозврат брошенного оружия",
    "Dropped guns come back to you on their own.": "Брошенное оружие само возвращается к вам.",
    "Pickups & Zed grabs": "Подбор и захват мутантов",
    "Auto-return delay": "Задержка автовозврата",
    "Seconds before a dropped gun comes back.": "Через сколько секунд брошенное оружие вернётся.",
    "Only with auto-return on": "Только с включённым автовозвратом",
    "Recall from weapon wheel": "Возврат через колесо оружия",
    "Call a dropped gun back from the weapon wheel.": "Вернуть брошенное оружие через колесо оружия.",
    "Zed grab and throw": "Захват и бросок мутантов",
    "Grab and throw Zeds with a free hand.": "Хватайте и бросайте мутантов свободной рукой.",
    "Melee hit stop": "Стоп-кадр при ударе",
    "A short pause on melee hits so they feel solid.": "Короткая пауза при ударе в ближнем бою для ощущения веса.",
    "Melee": "Ближний бой",
    "Physical melee": "Физический ближний бой",
    "Hit by swinging melee weapons with your own arm.": "Бейте, размахивая оружием ближнего боя собственной рукой.",

    # ----- Graphics & HUD settings -------------------------------------------------------------
    "Render scale": "Масштаб рендеринга",
    "Resolution per eye: lower runs faster but looks softer.": "Разрешение на каждый глаз: ниже — быстрее, но мягче картинка.",
    "DLSS": "DLSS",
    "NVIDIA upscaling for the headset; Auto uses Quality on RTX cards and stays off on others.":
        "Апскейлинг NVIDIA для шлема; «Авто» включает «Качество» на картах RTX и выключен на остальных.",
    "Auto": "Авто",
    "Full resolution (DLAA)": "Полное разрешение (DLAA)",
    "Ultra performance": "Ультрапроизводительность",
    "Menu distance": "Расстояние до меню",
    "Distance from your head. Adjust physically in headset.": "Расстояние от головы. Настраивается руками в шлеме.",
    "Menu height": "Высота меню",
    "Vertical offset. Backdrop changes preserve placement.": "Вертикальное смещение. Смена фона не меняет положение.",
    "Menu size": "Размер меню",
    "Scale of the menu panel.": "Масштаб панели меню.",
    "Wristwatch size": "Размер часов",
    "Use Wristwatch Fit in headset for position, rotation and a live watch preview.":
        "Положение, поворот и живой предпросмотр часов — через Wristwatch Fit в шлеме.",
    "Watch forward": "Часы вперёд",
    "Watch side": "Часы вбок",
    "Watch height": "Высота часов",
    "Watch pitch": "Наклон часов",
    "Saved watch rotation. Use Wristwatch Fit in headset for a live preview.":
        "Сохранённый поворот часов. Живой предпросмотр — через Wristwatch Fit в шлеме.",
    "Watch yaw": "Поворот часов",
    "Watch roll": "Крен часов",
    "Readout size": "Размер счётчика",
    "Scale of the weapon ammo readout.": "Масштаб счётчика патронов на оружии.",
    "Readout forward": "Счётчик вперёд",
    "Forward offset along the gun.": "Смещение вперёд вдоль оружия.",
    "Readout height": "Высота счётчика",
    "Vertical offset from the gun.": "Вертикальное смещение от оружия.",
    "Bloom": "Засветка",
    "Glow around bright lights.": "Свечение вокруг ярких источников света.",
    "Image": "Изображение",
    "Low": "Низкое",
    "High": "Высокое",
    "DLSS sharpening": "Резкость DLSS",
    "Sharpening after DLSS. 0% turns it off.": "Повышение резкости после DLSS. 0% — выключить.",
    "Only with DLSS on": "Только с включённым DLSS",
    "Ambient occlusion": "Взаимное затенение",
    "Soft shadows in corners and under objects.": "Мягкие тени в углах и под предметами.",
    "Shadow tuning": "Настройка теней",
    "Screen-space reflections": "Отражения в экранном пространстве",
    "Reflections on wet and shiny surfaces.": "Отражения на мокрых и блестящих поверхностях.",
    "Environment detail": "Детализация окружения",
    "Detail of level geometry, props and foliage.": "Детализация геометрии уровня, объектов и растительности.",
    "Ultra": "Отличное",
    "Character detail": "Детализация персонажей",
    "Detail of Zed and player models.": "Детализация моделей мутантов и игроков.",
    "Effects quality": "Качество эффектов",
    "Detail of muzzle flashes, fire, explosions and blood.": "Детализация вспышек выстрелов, огня, взрывов и крови.",
    "Texture quality": "Качество текстур",
    "Texture resolution. Higher settings need more video memory.": "Разрешение текстур. Чем выше, тем больше нужно видеопамяти.",
    "Texture filtering": "Фильтрация текстур",
    "Sharpness of floors and walls seen at an angle. 16× is sharpest and costs little.":
        "Чёткость пола и стен под углом. 16× — самая чёткая и почти бесплатная.",
    "Bilinear": "Билинейная",
    "Trilinear": "Трилинейная",
    "Shadows": "Тени",
    "Shadow detail and distance; one of the bigger costs.": "Детализация и дальность теней; одна из самых затратных настроек.",
    "Volumetric lighting": "Объёмное освещение",
    "Light scattering visibly through fog and smoke.": "Видимое рассеяние света в тумане и дыме.",
    "Light shafts": "Сумеречные лучи",
    "Visible beams of light from bright sources.": "Видимые лучи света от ярких источников.",
    "World shadow detail": "Детализация теней мира",
    "Detail of shadows from the main light. Higher is slower.": "Детализация теней от основного света. Выше — медленнее.",
    "Object shadow detail": "Детализация теней объектов",
    "Detail of shadows from characters and props. Higher is slower.":
        "Детализация теней от персонажей и объектов. Выше — медленнее.",
    "Shadow sharpness": "Чёткость теней",
    "How crisp shadow edges are. Higher is slower.": "Насколько чёткие края у теней. Выше — медленнее.",
    "Shadow distance": "Дальность теней",
    "How far away shadows are drawn. Farther is slower.": "На каком расстоянии рисуются тени. Дальше — медленнее.",
    "Near": "Близко",
    "Far": "Далеко",
    "Very far": "Очень далеко",
    "Gore intensity": "Жестокость",
    "How much gore and dismemberment you see.": "Сколько крови и расчленения вы видите.",
    "Bodies": "Тела",
    "Body limit": "Лимит тел",
    "More bodies look better in big waves and cost frame rate.":
        "Больше тел — эффектнее в больших волнах, но ниже частота кадров.",
    "Very high": "Очень высокое",
    "Bodies react to hits": "Тела реагируют на попадания",
    "Dead bodies still react to shots and can lose limbs.": "Мёртвые тела реагируют на выстрелы и могут терять конечности.",
    "Ragdoll physics": "Физика тряпичной куклы",
    "Bodies tumble and fall with real physics.": "Тела падают и кувыркаются по законам физики.",
    "Bodies collide with bodies": "Столкновения тел между собой",
    "Bodies bump into other bodies.": "Тела сталкиваются с другими телами.",
    "Bodies collide with Zeds": "Столкновения тел с мутантами",
    "Bodies bump into living Zeds and players.": "Тела сталкиваются с живыми мутантами и игроками.",
    "Resting bodies collide": "Столкновения с лежащими телами",
    "Bodies that have settled still block other bodies.": "Улёгшиеся тела по-прежнему мешают другим телам.",
    "Blood effect limit": "Лимит эффектов крови",
    "Higher shows more and costs frame rate.": "Выше — больше эффектов, но ниже частота кадров.",
    "Gore limits": "Лимиты расчленения",
    "Gore effect limit": "Лимит эффектов расчленения",
    "Splats per frame": "Брызг за кадр",
    "Wounds per body": "Ран на тело",
    "Blood splats": "Брызги крови",
    "Blood pools": "Лужи крови",
    "Gore lasts": "Время жизни расчленения",
    "Longer looks messier and costs frame rate.": "Дольше — кровавее, но ниже частота кадров.",
    "Gore lifetimes": "Время жизни эффектов",
    "Very long": "Очень долго",
    "Wounds last": "Время жизни ран",
    "Splats last": "Время жизни брызг",
    "Pools last": "Время жизни луж",
    "Body parts last": "Время жизни частей тел",
    "Bile splatter": "Брызги желчи",
    "Bloat bile over your view. It costs frame rate and is heavy on the CPU.":
        "Желчь толстяка (Bloat) на экране. Снижает частоту кадров и сильно нагружает процессор.",
    "Screen effects": "Эффекты на экране",
    "Blood splatter": "Брызги крови на экране",
    "Blood over your view when you're hit; the red damage tint stays either way.":
        "Кровь на экране при получении урона; красный оттенок урона остаётся в любом случае.",
    "Other players' headshot effects": "Эффекты хедшотов других игроков",
    "Cosmetic headshot visuals and sounds from other players. Normal headshot gore stays.":
        "Косметические эффекты и звуки хедшотов от других игроков. Обычное расчленение при хедшоте остаётся.",
    "Brightness": "Яркость",
    "The game's brightness (gamma). Shared with its brightness screen.":
        "Яркость игры (гамма). Общая с экраном настройки яркости самой игры.",
    "Motion blur": "Размытие при движении",
    "Smears the image as you move and turn.": "Размывает картинку при движении и поворотах.",
    "Radial blur": "Радиальное размытие",
    "Blurs the edges of your view during intense moments.": "Размывает края обзора в напряжённые моменты.",
    "Depth of field": "Глубина резкости",
    "Blurs scenery outside the focus distance.": "Размывает всё вне дистанции фокуса.",
    "Film grain": "Зернистость",
    "A grainy film texture over the image.": "Зернистость плёнки поверх изображения.",
    "Lens flares": "Блики на объективе",
    "Streaks and glare around bright lights.": "Полосы и блики вокруг ярких источников света.",
    "Watch": "Часы",
    "Health, armor and dosh on your wrist.": "Здоровье, броня и деньги на запястье.",
    "HUD": "HUD",
    "Ammo counter on gun": "Счётчик патронов на оружии",
    "Ammo count shown on the gun.": "Количество патронов показывается на оружии.",
    "Shows the damage you deal as numbers over Zeds' heads.": "Показывает нанесённый урон числами над головами мутантов.",
    "HUD colors": "Цвета HUD",
    "Standard or Classic health and armor colors.": "Стандартные или классические цвета здоровья и брони.",
    "Classic": "Классические",
    "Kill ticker": "Лента убийств",
    "Recent kills at the edge of your view.": "Последние убийства на краю обзора.",
    "Boss health bar": "Полоса здоровья босса",
    "The boss's health bar.": "Полоса здоровья босса.",
    "Teammate marker size": "Размер меток союзников",
    "Size of the markers over teammates.": "Размер меток над союзниками.",
    "Menu hand": "Рука для меню",
    "The hand that points at menus.": "Рука, которой вы указываете на меню.",
    "Menus": "Меню",
    "Menu backdrop": "Фон меню",
    "What's behind the VR menu and the game's own menus.": "Что видно за VR-меню и меню самой игры.",
    "VR studio": "VR-студия",
    "Live world": "Живой мир",

    # ----- Audio settings ----------------------------------------------------------------------
    "Master volume": "Общая громкость",
    "Overall game volume.": "Общая громкость игры.",
    "Effects volume": "Громкость эффектов",
    "Weapons, Zeds and the world around you.": "Оружие, мутанты и окружающий мир.",
    "Dialogue volume": "Громкость диалогов",
    "The Trader and character voices.": "Голоса Торговца и персонажей.",
    "Music volume": "Громкость музыки",
    "The soundtrack.": "Саундтрек.",
    "Voice chat volume": "Громкость голосового чата",
    "Other players' voices.": "Голоса других игроков.",
    "Microphone": "Микрофон",
    "When your voice goes out to friends.": "Когда ваш голос слышат друзья.",
    "Open mic": "Открытый микрофон",
    "Push to talk": "Нажать, чтобы говорить",
    "Whenever you're unmuted.": "Всегда, когда микрофон не выключен.",
    "Only while you hold Caps Lock, or a controller button you bind in your headset app.":
        "Только пока зажат Caps Lock или кнопка контроллера, назначенная в приложении шлема.",
    "Music vocals": "Вокал в музыке",
    "Sung vocals in the music.": "Пение в музыкальных треках.",
    "Music & dialogue": "Музыка и диалоги",
    "Battle chatter": "Разговоры в бою",
    "How often characters talk in battle.": "Как часто персонажи говорят в бою.",
    "Reduced": "Реже",

    # ----- joining parts back together (tried last, in this order) ------------------------------
    "{0} — {1}": "{0} — {1}",
    "{0}: {1} → {2}": "{0}: {1} → {2}",
    "{0}: {1}": "{0}: {1}",
    "{0} ({1})": "{0} ({1})",
    "{0}, {1}": "{0}, {1}",
    "{0} and {1}": "{0} и {1}",
}
