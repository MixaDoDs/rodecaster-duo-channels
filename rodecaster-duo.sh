#!/usr/bin/env bash
# rodecaster-duo.sh — раздельные каналы и программный mix-minus
# для RØDECaster Duo на Linux (PipeWire + WirePlumber).
#
#   ./rodecaster-duo.sh install     поставить конфиги и перезапустить звук
#   ./rodecaster-duo.sh uninstall   убрать всё, что поставил скрипт
#   ./rodecaster-duo.sh status      показать устройства и куда идёт Discord
#   ./rodecaster-duo.sh test        проверить тоном, что mix-minus не пропускает Chat
#
# https://github.com/MixaDoDs/rodecaster-duo-channels
set -euo pipefail

VERSION="1.0.0"
MARKER="# managed-by: rodecaster-duo-channels"
EXPECTED_CHANNELS=15

PW_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d"
WP_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
SPLIT_CONF="$PW_DIR/90-rodecaster-duo-split.conf"
MIXMINUS_CONF="$PW_DIR/91-rodecaster-duo-mixminus.conf"
WP_CONF="$WP_DIR/99-rodecaster-duo.conf"

# ── вывод ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_BLU=$'\e[34m' C_DIM=$'\e[2m' C_B=$'\e[1m' C_0=$'\e[0m'
else
    C_RED="" C_GRN="" C_YLW="" C_BLU="" C_DIM="" C_B="" C_0=""
fi
info() { printf '%s::%s %s\n' "$C_BLU" "$C_0" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$C_GRN" "$C_0" "$*"; }
warn() { printf '%s !%s %s\n' "$C_YLW" "$C_0" "$*" >&2; }
die()  { printf '%s ✗%s %s\n' "$C_RED" "$C_0" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
${C_B}rodecaster-duo.sh${C_0} $VERSION — каналы и mix-minus для RØDECaster Duo

${C_B}Использование:${C_0}
  $0 install [опции]   поставить конфиги PipeWire/WirePlumber
  $0 uninstall         удалить конфиги, поставленные этим скриптом
  $0 status            показать виртуальные устройства и маршруты Discord
  $0 music [ГРОМКОСТЬ] громкость музыки, которую слышат в Discord
                       (50%, +5%, -3dB; без аргумента — показать текущую)
  $0 test              проверить изоляцию mix-minus тестовым тоном (нужен python3)

${C_B}Опции install:${C_0}
  --default-mic chatmic|mainmix|keep
                       микрофон по умолчанию (по умолчанию: chatmic)
  --music-level V      громкость музыки для Discord
                       (по умолчанию 50%, если её ещё не меняли)
  --latency N          node.latency = N/48000 для всех петель (по умолчанию не задаётся)
  --no-restart         только записать файлы, звук не перезапускать
  --dry-run            показать, что будет записано, ничего не меняя
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "нужна команда '$1' ($2)"; }

# ── поиск пульта ─────────────────────────────────────────────────────────────
DUO_ID=""      # usb-R__DE_RODECaster_Duo_<serial>-00
DUO_CARD=""    # alsa_card.usb-...

find_card() {
    DUO_CARD=$(pactl list short cards | awk '$2 ~ /^alsa_card\.usb-R__DE_RODECaster_Duo_/ {print $2; exit}')
}

find_multitrack() {
    pactl list short sources | awk '$2 ~ /^alsa_input\.usb-R__DE_RODECaster_Duo_.*\.pro-input-1$/ {print $2, $5; exit}'
}

wait_for() {  # wait_for <секунды> <команда...>
    local deadline=$((SECONDS + $1)); shift
    until "$@" >/dev/null 2>&1; do
        ((SECONDS >= deadline)) && return 1
        sleep 0.2
    done
}

has_multitrack() { [[ -n "$(find_multitrack)" ]]; }

duo_nodes_ready() {
    pactl list short sinks | grep -qF "alsa_output.$DUO_ID.pro-output-1" &&
    pactl list short sinks | grep -qF "alsa_output.$DUO_ID.pro-output-0" &&
    has_multitrack
}

detect_duo() {
    lsusb 2>/dev/null | grep -qi '19f7:' || warn "lsusb не видит устройств RØDE — проверь кабель"
    find_card
    [[ -n "$DUO_CARD" ]] || die "RØDECaster Duo не найден в PipeWire. Подключи пульт и попробуй снова."

    if ! has_multitrack; then
        local profile
        profile=$(pactl list cards | awk -v c="$DUO_CARD" '$1=="Name:"{n=$2} n==c && /Active Profile:/{print $3; exit}')
        info "профиль карты: ${profile:-?} — нужен pro-audio, переключаю"
        pactl set-card-profile "$DUO_CARD" pro-audio \
            || die "не удалось включить профиль pro-audio для $DUO_CARD"
        wait_for 10 has_multitrack || die "после переключения профиля Multitrack так и не появился"
    fi

    local name channels
    read -r name channels < <(find_multitrack)
    channels=${channels%ch}
    if [[ "$channels" != "$EXPECTED_CHANNELS" ]]; then
        die "Multitrack отдаёт ${channels} кан., а раскладка снята для ${EXPECTED_CHANNELS}.
   Похоже, у тебя другая прошивка (например 1.7.3, USB PID 19f7:0095).
   Для неё есть готовый проект: https://github.com/parzival-space/rodecaster-pro-2-virtual-devices-pipewire"
    fi

    DUO_ID=${name#alsa_input.}
    DUO_ID=${DUO_ID%.pro-input-1}
    ok "найден RØDECaster Duo: ${C_DIM}${DUO_ID}${C_0} (${channels} кан.)"
}

# ── генерация конфигов ───────────────────────────────────────────────────────
LATENCY=""
lat() { [[ -n "$LATENCY" ]] && printf '%*snode.latency = "%s/48000"\n' "$1" "" "$LATENCY"; return 0; }

# split_source <node> <описание> <nick> <AUX-позиции> <позиции выхода> <priority>
split_source() {
    cat <<EOF
    {   name = libpipewire-module-loopback
        args = {
            node.description = "$2"
            capture.props = {
                node.name         = "$1.capture"
                target.object     = "alsa_input.$DUO_ID.pro-input-1"
                audio.position    = [ $4 ]
                stream.dont-remix = true
$(lat 16)            }
            playback.props = {
                node.name         = "$1"
                node.description  = "$2"
                node.nick         = "$3"
                media.class       = "Audio/Source"
                audio.position    = [ $5 ]
                priority.session  = $6
$(lat 16)            }
        }
    }
EOF
}

gen_split() {
    cat <<EOF
$MARKER
# RØDECaster Duo — нарезка 15-канального Multitrack на отдельные источники.
#
# Раскладка каналов (снята замером, прошивка с USB PID 19f7:004f):
#   AUX0/AUX1   Main Mix
#   AUX2        Mic 1
#   AUX3        Mic 2
#   AUX4..AUX6  не задействованы (Bluetooth / USB 2)
#   AUX7/AUX8   SMART Pads
#   AUX9/AUX10  USB 1 Main — возврат того, что ПК отдал в Main
#   AUX11/AUX12 USB 1 Chat — возврат того, что ПК отдал в Chat
#   AUX13/AUX14 не задействованы

context.modules = [
$(split_source rode_duo_mainmix "RØDE Main Mix"   "Main Mix"   "AUX0 AUX1" "FL FR" 1000)
$(split_source rode_duo_mic1    "RØDE Mic 1"      "Mic 1"      "AUX2"      "MONO"  1500)
$(split_source rode_duo_mic2    "RØDE Mic 2"      "Mic 2"      "AUX3"      "MONO"  1400)
$(split_source rode_duo_pads    "RØDE SMART Pads" "SMART Pads" "AUX7 AUX8" "FL FR" 1300)
]
EOF
}

# bus_feed <имя> <описание> <AUX-позиции>
bus_feed() {
    cat <<EOF
    {   name = libpipewire-module-loopback
        args = {
            node.description = "$2"
            capture.props = {
                node.name         = "rode_mm_$1.capture"
                target.object     = "alsa_input.$DUO_ID.pro-input-1"
                audio.position    = [ $3 ]
                stream.dont-remix = true
$(lat 16)            }
            playback.props = {
                node.name         = "rode_mm_$1"
                node.description  = "$2"
                target.object     = "rode_duo_mixbus"
                audio.position    = [ FL FR ]
$(lat 16)            }
        }
    }
EOF
}

gen_mixminus() {
    cat <<EOF
$MARKER
# RØDECaster Duo — программный mix-minus для созвонов.
#
# Аппаратный возврат pro-input-0 содержит канал Chat, поэтому собеседники
# слышат сами себя. Здесь микс собирается из дорожек Multitrack без AUX11/12:
#   AUX2 Mic 1 · AUX3 Mic 2 · AUX7/8 SMART Pads · AUX9/10 звук ПК из Main
#
# Шина обязана быть Audio/Sink: на Audio/Source/Virtual WirePlumber
# игнорирует target.object и уводит поток на выход по умолчанию — петля.

context.objects = [
    {   factory = adapter
        args = {
            factory.name     = support.null-audio-sink
            node.name        = "rode_duo_mixbus"
            node.description = "RØDE mix-minus (служебная шина)"
            node.nick        = "mix-minus bus"
            media.class      = "Audio/Sink"
            audio.position   = "FL,FR"
            object.linger    = true
            priority.session = 100
$(lat 12)        }
    }
]

context.modules = [
$(bus_feed mic1  "mix-minus <- Mic 1"               "AUX2")
$(bus_feed mic2  "mix-minus <- Mic 2"               "AUX3")
$(bus_feed pads  "mix-minus <- SMART Pads"          "AUX7 AUX8")
$(bus_feed music "mix-minus <- музыка (USB 1 Main)" "AUX9 AUX10")
    {   name = libpipewire-module-loopback
        args = {
            node.description = "RØDE Chat Mic"
            capture.props = {
                node.name           = "rode_duo_chatmic.capture"
                target.object       = "rode_duo_mixbus"
                stream.capture.sink = true
                audio.position      = [ FL FR ]
$(lat 16)            }
            playback.props = {
                node.name        = "rode_duo_chatmic"
                node.description = "RØDE Chat Mic (mix-minus, без эха ДС)"
                node.nick        = "Chat Mic"
                media.class      = "Audio/Source"
                audio.position   = [ FL FR ]
                priority.session = 1800
                device.icon-name = "audio-input-microphone"
$(lat 16)            }
        }
    }
]
EOF
}

gen_wireplumber() {
    cat <<EOF
$MARKER
# RØDECaster Duo — понятные имена и маршрутизация голосовых приложений.
# Имя файла начинается с 99-, чтобы перекрыть имена из пакета
# rodecaster-duo-pipewire (51-rodecaster-duo-rename.conf), если он стоит.

monitor.alsa.rules = [
  {
    # Без этого после рестарта/перезагрузки пульт может подняться в другом
    # профиле, и Multitrack со всеми виртуальными каналами пропадёт.
    matches = [ { device.name = "alsa_card.$DUO_ID" } ]
    actions = { update-props = {
      device.profile = "pro-audio"
    } }
  }
  {
    matches = [ { node.name = "alsa_output.$DUO_ID.pro-output-1" } ]
    actions = { update-props = {
      node.description = "RØDE Duo — Main (музыка, игры, браузер)"
      node.nick        = "Main"
      priority.session = 2000
    } }
  }
  {
    matches = [ { node.name = "alsa_output.$DUO_ID.pro-output-0" } ]
    actions = { update-props = {
      node.description = "RØDE Duo — Chat (Discord, Zoom)"
      node.nick        = "Chat"
      priority.session = 900
    } }
  }
  {
    # Не mix-minus: канал Chat в нём присутствует. Для созвонов — RØDE Chat Mic.
    matches = [ { node.name = "alsa_input.$DUO_ID.pro-input-0" } ]
    actions = { update-props = {
      node.description = "RØDE Duo — Chat-In (копия микса, даёт эхо!)"
      node.nick        = "Chat-In"
      priority.session = 100
    } }
  }
  {
    matches = [ { node.name = "alsa_input.$DUO_ID.pro-input-1" } ]
    actions = { update-props = {
      node.description = "RØDE Duo — Multitrack (15 каналов, для OBS)"
      node.nick        = "Multitrack"
      priority.session = 50
    } }
  }
]

stream.rules = [
  {
    # WEBRTC VoiceEngine — Discord и звонки из Chromium-браузеров.
    matches = [
      { application.name = "~.*WEBRTC.*"   media.class = "Stream/Output/Audio" }
      { application.name = "~[Dd]iscord.*" media.class = "Stream/Output/Audio" }
      { application.name = "~.*[Zz]oom.*"  media.class = "Stream/Output/Audio" }
    ]
    actions = { update-props = {
      target.object        = "alsa_output.$DUO_ID.pro-output-0"
      state.restore-target = false
    } }
  }
  {
    matches = [
      { application.name = "~.*WEBRTC.*"   media.class = "Stream/Input/Audio" }
      { application.name = "~[Dd]iscord.*" media.class = "Stream/Input/Audio" }
      { application.name = "~.*[Zz]oom.*"  media.class = "Stream/Input/Audio" }
    ]
    actions = { update-props = {
      target.object        = "rode_duo_chatmic"
      state.restore-target = false
    } }
  }
]
EOF
}

# ── запись файлов ────────────────────────────────────────────────────────────
DRY_RUN=0

write_conf() {  # write_conf <путь> <генератор>
    local path=$1 content
    content=$("$2")
    if ((DRY_RUN)); then
        printf '\n%s── %s ──%s\n%s\n' "$C_B" "$path" "$C_0" "$content"
        return
    fi
    mkdir -p "$(dirname "$path")"
    if [[ -e "$path" ]] && ! grep -qF "$MARKER" "$path"; then
        local backup
        backup="$path.bak-$(date +%Y%m%d-%H%M%S)"
        mv "$path" "$backup"
        warn "чужой файл сохранён как $backup"
    fi
    printf '%s\n' "$content" > "$path"
    ok "записан $path"
}

# ── перезапуск с сохранением профилей карт ───────────────────────────────────
# После рестарта PipeWire профили других карт иногда сбрасываются в off —
# запоминаем их и возвращаем.
snapshot_profiles() {
    pactl list cards | awk '$1=="Name:"{n=$2} /Active Profile:/{print n, $3}'
}

restart_audio() {
    local snapshot
    snapshot=$(snapshot_profiles)
    info "перезапускаю pipewire, pipewire-pulse, wireplumber"
    systemctl --user restart pipewire pipewire-pulse wireplumber
    wait_for 20 pactl info || die "pipewire-pulse не поднялся"
    wait_for 20 sh -c 'pactl list short sources | grep -q rode_duo_chatmic' \
        || die "виртуальные устройства не появились — смотри: journalctl --user -u pipewire -b"

    local card profile now
    while read -r card profile; do
        [[ -z "$card" || "$profile" == "off" ]] && continue
        now=$(pactl list cards | awk -v c="$card" '$1=="Name:"{n=$2} n==c && /Active Profile:/{print $3; exit}')
        if [[ -n "$now" && "$now" != "$profile" ]]; then
            pactl set-card-profile "$card" "$profile" && info "вернул профиль $profile для $card"
        fi
    done <<< "$snapshot"
    ok "звук перезапущен"
}

# Сразу после рестарта карты ещё появляются, и WirePlumber может перебить
# только что выставленное значение — ставим, ждём, перепроверяем.
set_default() {  # set_default sink|source <имя>
    local kind=$1 name=$2 stable=0
    local deadline=$((SECONDS + 10))
    while ((SECONDS < deadline)); do
        [[ "$(pactl "get-default-$kind")" == "$name" ]] || { pactl "set-default-$kind" "$name"; stable=0; }
        sleep 0.5
        [[ "$(pactl "get-default-$kind")" == "$name" ]] && ((++stable >= 3)) && return 0
    done
    warn "не удалось закрепить $name как $kind по умолчанию"
}

# ── команды ──────────────────────────────────────────────────────────────────
cmd_install() {
    local default_mic="chatmic" restart=1 music_level=""
    while (($#)); do
        case "$1" in
            --default-mic) default_mic=${2:?}; shift ;;
            --latency)     LATENCY=${2:?}; shift
                           [[ "$LATENCY" =~ ^[0-9]+$ ]] || die "--latency ждёт число, например 256" ;;
            --music-level) music_level=${2:?}; shift ;;
            --no-restart)  restart=0 ;;
            --dry-run)     DRY_RUN=1 ;;
            -h|--help)     usage; exit 0 ;;
            *)             die "неизвестная опция: $1" ;;
        esac
        shift
    done
    [[ "$default_mic" =~ ^(chatmic|mainmix|keep)$ ]] || die "--default-mic: chatmic, mainmix или keep"

    need pactl "пакет libpulse или pipewire-pulse"
    need systemctl "systemd"
    pactl info 2>/dev/null | grep -q 'on PipeWire' || die "звуковой сервер — не PipeWire"
    local wpver
    wpver=$(wireplumber --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -n "$wpver" ]] && [[ "$(printf '%s\n0.5\n' "$wpver" | sort -V | head -1)" != "0.5" ]]; then
        die "нужен WirePlumber 0.5+, установлен $wpver"
    fi

    detect_duo
    write_conf "$SPLIT_CONF"    gen_split
    write_conf "$MIXMINUS_CONF" gen_mixminus
    write_conf "$WP_CONF"       gen_wireplumber
    ((DRY_RUN)) && { info "dry-run: ничего не изменено"; return; }

    if ((restart)); then
        restart_audio
        wait_for 15 duo_nodes_ready || die "после рестарта пульт не поднялся в профиле pro-audio"
        set_default sink "alsa_output.$DUO_ID.pro-output-1"
        case "$default_mic" in
            chatmic) set_default source rode_duo_chatmic ;;
            mainmix) set_default source rode_duo_mainmix ;;
        esac
        ok "выход по умолчанию: $(pactl get-default-sink)"
        ok "микрофон по умолчанию: $(pactl get-default-source)"
        wait_for 10 music_stream_id || die "не найден поток rode_mm_music"
        # Уже подобранную громкость не трогаем: 50% только для нетронутой (100%).
        if [[ -z "$music_level" && "$(music_volume)" == 100%* ]]; then
            music_level="50%"
        fi
        [[ -n "$music_level" ]] && set_music_volume "$music_level"
        ok "музыка для Discord: $(music_volume) — менять: $0 music 40%"
    else
        info "перезапусти звук сам: systemctl --user restart pipewire pipewire-pulse wireplumber"
    fi

    cat <<EOF

${C_B}Готово.${C_0} В Discord: Настройки → Голос и видео
  Устройство ввода:  ${C_GRN}RØDE Chat Mic (mix-minus, без эха ДС)${C_0}
  Устройство вывода: ${C_GRN}RØDE Duo — Chat (Discord, Zoom)${C_0}
Проверка изоляции: $0 test
EOF
}

cmd_uninstall() {
    local removed=0 f
    for f in "$SPLIT_CONF" "$MIXMINUS_CONF" "$WP_CONF"; do
        if [[ -e "$f" ]]; then
            if grep -qF "$MARKER" "$f"; then
                rm -f "$f"; ok "удалён $f"; removed=1
            else
                warn "пропускаю $f — файл создан не этим скриптом"
            fi
        fi
    done
    ((removed)) || { info "удалять нечего"; return; }
    local snapshot
    snapshot=$(snapshot_profiles)
    systemctl --user restart pipewire pipewire-pulse wireplumber
    wait_for 20 pactl info || die "pipewire-pulse не поднялся"
    while read -r card profile; do
        [[ -z "$card" || "$profile" == "off" ]] && continue
        pactl set-card-profile "$card" "$profile" 2>/dev/null || true
    done <<< "$snapshot"
    ok "звук перезапущен, виртуальные устройства убраны"
}

describe() {  # describe sources|sinks — описания устройств пульта
    pactl list "$1" | awk '/^\tName:/{n=$2} /^\tDescription:/{sub(/^\tDescription: /,""); if ((n ~ /^rode_duo_/ || n ~ /RODECaster_Duo/) && n !~ /\.monitor$/) print "  " $0}'
}

describe_one() {  # describe_one sources|sinks <name>
    pactl list "$1" | awk -v want="$2" '/^\tName:/{n=$2} /^\tDescription:/ && n==want {sub(/^\tDescription: /,""); print; found=1; exit} END{if(!found) print want}'
}

# ── громкость музыки в mix-minus ─────────────────────────────────────────────
# Дорожка музыки в Multitrack снимается до фейдера, поэтому фейдер пульта
# на неё не влияет — громкость для собеседников задаётся здесь.
# WirePlumber запоминает её и восстанавливает после перезапуска.
music_stream_id() {
    local id
    id=$(pactl list sink-inputs | awk '/^Sink Input #/{id=substr($3,2)} /node.name = "rode_mm_music"/{print id; exit}')
    [[ -n "$id" ]] && echo "$id"
}

music_volume() {
    pactl list sink-inputs | awk -v id="$(music_stream_id)" '
        /^Sink Input #/{cur=substr($3,2)}
        cur==id && /^\tVolume:/{printf "%s (%s дБ)\n", $5, $7; exit}'
}

set_music_volume() {
    local v=$1 id
    [[ "$v" =~ ^[+-]?[0-9]+(\.[0-9]+)?(%|dB)?$ ]] || die "громкость: 50%, +5%, -5%, -3dB или 0.5"
    id=$(music_stream_id) || die "поток rode_mm_music не найден — сначала $0 install"
    pactl set-sink-input-volume "$id" "$v"
}

cmd_music() {
    need pactl "pipewire-pulse"
    music_stream_id >/dev/null || die "поток rode_mm_music не найден — сначала $0 install"
    if (($#)); then
        set_music_volume "$1"
        ok "музыка для Discord: $(music_volume)"
    else
        echo "музыка для Discord: $(music_volume)"
    fi
}

cmd_status() {
    need pactl "pipewire-pulse"
    printf '%sВходы:%s\n' "$C_B" "$C_0"
    describe sources
    printf '%sВыходы:%s\n' "$C_B" "$C_0"
    describe sinks
    printf '%sМузыка для Discord:%s %s\n' "$C_B" "$C_0" "$(music_volume)"
    printf '%sПо умолчанию:%s\n  выход     %s\n  микрофон  %s\n' "$C_B" "$C_0" \
        "$(describe_one sinks "$(pactl get-default-sink)")" \
        "$(describe_one sources "$(pactl get-default-source)")"

    printf '%sГолосовые приложения:%s\n' "$C_B" "$C_0"
    local src_names sink_names apps
    src_names=$(pactl list short sources | awk '{print $1, $2}')
    sink_names=$(pactl list short sinks | awk '{print $1, $2}')
    apps=$({
        pactl list sink-inputs   | awk -v k=out '/^Sink Input/{d=""} /^\tSink:/{d=$2} /application.name =/{sub(/.*= /,""); gsub(/"/,""); print k, d, $0}'
        pactl list source-outputs | awk -v k=in '/^Source Output/{d=""} /^\tSource:/{d=$2} /application.name =/{sub(/.*= /,""); gsub(/"/,""); print k, d, $0}'
    } | grep -iE 'webrtc|discord|zoom' || true)
    if [[ -z "$apps" ]]; then
        echo "  нет активных (Discord не в голосовом канале?)"
        return
    fi
    while read -r kind id app; do
        local target
        if [[ $kind == out ]]; then
            target=$(awk -v i="$id" '$1==i{print $2}' <<< "$sink_names")
            printf '  %-22s слушает → %s\n' "$app" "${target:-?}"
        else
            target=$(awk -v i="$id" '$1==i{print $2}' <<< "$src_names")
            if [[ "$target" == rode_duo_chatmic ]]; then
                printf '  %-22s пишет   ← %s%s%s\n' "$app" "$C_GRN" "$target" "$C_0"
            else
                printf '  %-22s пишет   ← %s%s%s  (ожидался rode_duo_chatmic)\n' "$app" "$C_YLW" "${target:-?}" "$C_0"
            fi
        fi
    done <<< "$apps"
}

cmd_test() {
    need python3 "для генерации тона и анализа"
    need pw-record "pipewire"
    need pw-play "pipewire"
    detect_duo
    pactl list short sources | grep -q rode_duo_chatmic || die "RØDE Chat Mic не найден — сначала $0 install"

    TEST_TMP=$(mktemp -d)
    trap 'rm -rf "$TEST_TMP"' EXIT
    local tmp=$TEST_TMP

    python3 - "$tmp/tone.wav" <<'PY'
import math, struct, sys, wave
sr = 48000
frames = [0] * (2 * sr) + [int(0.3 * 32767 * math.sin(2 * math.pi * 7351 * i / sr)) for i in range(4 * sr)] + [0] * (2 * sr)
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(b"".join(struct.pack("<hh", s, s) for s in frames))
PY

    warn "сейчас в наушниках пульта дважды пропищит тон 7 кГц по 4 секунды — убавь громкость"
    local level_main level_chat
    probe() {  # probe <sink> <wav-out>
        timeout 9 pw-record --target=rode_duo_chatmic --channels=2 --format=s16 --rate=48000 "$2" >/dev/null 2>&1 &
        local rec=$!
        pw-play --target="$1" "$tmp/tone.wav" >/dev/null 2>&1
        wait "$rec" 2>/dev/null || true
        python3 - "$2" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], "rb") as w:
    ch, sr = w.getnchannels(), w.getframerate()
    data = struct.unpack("<%dh" % (w.getnframes() * ch), w.readframes(w.getnframes()))
n, best = sr, -120.0
k = round(7351 * n / sr); coef = 2 * math.cos(2 * math.pi * k / n)
for start in range(2 * sr, 6 * sr, sr):          # только окна с тоном
    s1 = s2 = 0.0
    for i in range(n):
        s1, s2 = data[(start + i) * ch] / 32768 + coef * s1 - s2, s1
    mag = math.sqrt(max(s1 * s1 + s2 * s2 - coef * s1 * s2, 0)) * 2 / n
    best = max(best, 20 * math.log10(mag) if mag > 0 else -120.0)
print("%.0f" % best)
PY
    }
    info "тон → Main (музыка), слушаю RØDE Chat Mic"
    level_main=$(probe "alsa_output.$DUO_ID.pro-output-1" "$tmp/main.wav")
    info "тон → Chat (Discord), слушаю RØDE Chat Mic"
    level_chat=$(probe "alsa_output.$DUO_ID.pro-output-0" "$tmp/chat.wav")

    printf '\n  музыка  → Chat Mic: %4s дБ  (нужно выше −50)\n' "$level_main"
    printf '  Discord → Chat Mic: %4s дБ  (нужно ниже −70)\n\n' "$level_chat"
    local fail=0
    ((level_main > -50)) || { warn "музыка не доходит до Chat Mic — проверь фейдер/мьют USB 1 на пульте"; fail=1; }
    ((level_chat < -70)) || { warn "звук Discord проникает в Chat Mic — mix-minus не работает"; fail=1; }
    ((fail)) && die "проверка не пройдена"
    ok "mix-minus работает: изоляция $((level_main - level_chat)) дБ"
}

main() {
    local cmd=${1:-}
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        install)         cmd_install "$@" ;;
        uninstall)       cmd_uninstall ;;
        status)          cmd_status ;;
        music)           cmd_music "$@" ;;
        test)            cmd_test ;;
        -v|--version)    echo "$VERSION" ;;
        ""|-h|--help|help) usage ;;
        *)               usage >&2; exit 2 ;;
    esac
}

main "$@"
