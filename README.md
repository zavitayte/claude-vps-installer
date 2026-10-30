# Claude VPS

Установщик удалённого рабочего стола Linux с официальным приложением **Claude Desktop** на собственном сервере. Одна команда на сервере, одна — на компьютере с Windows.

## Что понадобится

- Сервер с **Ubuntu 24.04**, от 2 ядер и 4 ГБ памяти (на 1 ядре / 2 ГБ рабочий стол тормозит).
- IP сервера и доступ root.
- Компьютер с Windows 10/11 (SSH и «Подключение к удалённому рабочему столу» уже встроены).

## 1. Установка на сервере

Зайдите на сервер (`ssh root@IP_СЕРВЕРА`) и выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/zavitayte/claude-vps-installer/main/install.sh | bash
```

Занимает 15–30 минут. В конце скрипт покажет пароль пользователя `claude` (он также сохранён в `/root/claude-vps-credentials.txt`) и предложит перезагрузить сервер.

Свой пароль или имя пользователя:

```bash
curl -fsSL https://raw.githubusercontent.com/zavitayte/claude-vps-installer/main/install.sh | CLAUDE_USER=claude CLAUDE_PASSWORD='ваш_пароль' bash
```

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `CLAUDE_USER` | `claude` | Пользователь рабочего стола |
| `CLAUDE_PASSWORD` | генерируется | Пароль пользователя |
| `XRDP_PUBLIC` | `0` | `1` — RDP слушает все адреса, а не только localhost |
| `NO_REBOOT` | `0` | `1` — не перезагружать в конце |

### Что делает скрипт

1. Создаёт пользователя `claude` и генерирует пароль.
2. Ставит XFCE, xrdp, gnome-keyring, Firefox.
3. Настраивает xrdp: сеанс XFCE, доступ к сертификату, RDP **только на 127.0.0.1** (снаружи порт 3389 закрыт, вход через SSH-туннель).
4. Выключает lightdm.
5. Скачивает ключ репозитория Anthropic и **проверяет отпечаток** `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE` — если не совпал, установка останавливается.
6. Подключает официальный apt-репозиторий и ставит `claude-desktop`.
7. Раскладка us/ru по Alt+Shift (в том числе после переподключения).
8. Хранилище паролей открывается автоматически при входе.
9. Запрещает автообновлениям перезапускать xrdp (иначе окно RDP закрывается через секунду).
10. Кладёт значок Claude на рабочий стол.

Скрипт можно запускать повторно — настройки не дублируются.

## 2. Подключение с Windows

Скачайте [`connect.ps1`](connect.ps1) и один раз выполните в PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\connect.ps1 -Ip IP_СЕРВЕРА -CreateShortcut
```

Откроется окно SSH — введите пароль пользователя `claude` и **не закрывайте его**, пока работаете. Затем запустится удалённый рабочий стол. На рабочем столе Windows появится ярлык **Claude VPS** — дальше подключайтесь по нему.

<details>
<summary>Вручную, без скрипта</summary>

```powershell
ssh -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L 3390:127.0.0.1:3389 claude@IP_СЕРВЕРА
```

Затем `Win+R` → `mstsc` → `localhost:3390` → пользователь `claude`.
</details>

Перед вводом пароля на экране входа переключите Windows на английскую раскладку.

### Папка с компьютера внутри Claude

```powershell
subst Z: "C:\Users\ВАШЕ_ИМЯ\Documents\Projects"
```

В mstsc: «Показать параметры» → «Локальные ресурсы» → «Подробнее» → «Диски» → отметьте `Z:`. На сервере папка появится в `~/thinclient_drives`.

## Если что-то пошло не так

| Проблема | Решение |
|---|---|
| Окно рабочего стола закрывается через секунду | Под root на сервере: `pkill -KILL -u claude`, затем подключиться заново |
| Пропал буфер обмена / завис проброс папки | В терминале сервера: `fusermount -uz ~/thinclient_drives`, затем Log Out и вход |
| Ctrl+V не вставляет в терминал | В терминале Linux — `Ctrl+Shift+V` |
| Claude Code не видит файлы сервера | Создайте сессию с окружением **Local**, а не Cloud |

## Важно

Пользуйтесь Claude в соответствии с [условиями использования](https://www.anthropic.com/legal/consumer-terms) и [списком поддерживаемых стран](https://www.anthropic.com/supported-countries) Anthropic.
