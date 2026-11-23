#!/usr/bin/env bash
# kbswitch — troca automática do Magic Keyboard entre dois Macs, SEM SSH.
#
# Por que é preciso "soltar" o teclado:
#   o Magic Keyboard só aceita um Mac por vez. Enquanto ele está conectado no
#   Mac A, o Mac B não consegue parear. Então alguém precisa liberar no Mac A.
#
# Formas de liberar (combine como quiser no ~/.config/kbswitch.conf):
#   1. Atalho de teclado: `kbswitch release` ligado a um atalho no app Atalhos.
#      Você aperta o atalho no Mac atual (com o próprio teclado) e vai pro outro.
#   2. RELEASE_ON_LOCK=1: solta o teclado quando a tela deste Mac bloqueia.
#   3. RELEASE_IDLE_SECS=N: solta se este Mac ficar N segundos sem nenhum input.
#   4. NTFY_TOPIC=...: os dois Macs conversam por um canal de pub/sub (ntfy.sh)
#      usando só conexões de SAÍDA via HTTPS. Totalmente automático.
#
# Para pegar o teclado: o daemon percebe que você está mexendo no trackpad
# deste Mac sem o teclado conectado e re-pareia sozinho.
#
# Comandos: daemon | grab | release | status

set -u

CONF="${KBSWITCH_CONF:-$HOME/.config/kbswitch.conf}"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && source "$CONF"

KB_ADDR="${KB_ADDR:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
RELEASE_ON_LOCK="${RELEASE_ON_LOCK:-0}"
RELEASE_IDLE_SECS="${RELEASE_IDLE_SECS:-0}"
POLL_SECS="${POLL_SECS:-2}"
IDLE_THRESHOLD_SECS="${IDLE_THRESHOLD_SECS:-2}"
COOLDOWN_SECS="${COOLDOWN_SECS:-20}"
PAIR_RETRY_SECS="${PAIR_RETRY_SECS:-30}"

export PATH="$HOME/.local/bin:$HOME/homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ME="$(hostname -s)"

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$ME" "$*"; }

need() {
  command -v blueutil >/dev/null || { log "blueutil não encontrado (brew install blueutil)"; exit 1; }
  [[ -n "$KB_ADDR" ]] || { log "KB_ADDR não definido em $CONF"; exit 1; }
}

is_connected() { [[ "$(blueutil --is-connected "$KB_ADDR" 2>/dev/null)" == "1" ]]; }

# Segundos desde o último input de qualquer HID (trackpad, mouse, teclado).
idle_secs() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }

screen_locked() {
  ioreg -n Root -d1 -a 2>/dev/null | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'
}

notify() { osascript -e "display notification \"$1\" with title \"kbswitch\"" >/dev/null 2>&1; }

release_local() {
  blueutil --disconnect "$KB_ADDR" >/dev/null 2>&1
  blueutil --unpair "$KB_ADDR" >/dev/null 2>&1
  log "teclado liberado neste Mac ($1)"
}

ntfy_send() {
  [[ -n "$NTFY_TOPIC" ]] || return 1
  curl -fsS -m 5 -d "release $ME" "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1
}

# Escuta o canal; quando o OUTRO Mac pede, solta o teclado aqui.
ntfy_listen() {
  while true; do
    curl -sN --max-time 3600 "$NTFY_SERVER/$NTFY_TOPIC/raw" 2>/dev/null |
      while IFS= read -r line; do
        [[ "$line" == release\ * && "$line" != "release $ME" ]] || continue
        is_connected && release_local "pedido de ${line#release }"
      done
    sleep 5
  done
}

grab() {
  if is_connected; then log "teclado já está conectado aqui"; return 0; fi

  log "tentando conexão direta…"
  if blueutil --connect "$KB_ADDR" >/dev/null 2>&1 && sleep 1 && is_connected; then
    log "conectado (caminho rápido)"; return 0
  fi

  if ntfy_send; then log "pedi para o outro Mac soltar o teclado"; sleep 3; fi

  log "re-pareando…"
  blueutil --unpair "$KB_ADDR" >/dev/null 2>&1
  local deadline=$(( SECONDS + PAIR_RETRY_SECS )) warned=0
  while (( SECONDS < deadline )); do
    blueutil --pair "$KB_ADDR" >/dev/null 2>&1
    blueutil --connect "$KB_ADDR" >/dev/null 2>&1
    sleep 1
    if is_connected; then log "conectado após re-parear"; return 0; fi
    if (( !warned )); then
      log "ainda não conectou — solte o teclado no outro Mac ou desligue/ligue o teclado"
      notify "Solte o teclado no outro Mac (atalho) ou desligue e ligue o Magic Keyboard"
      warned=1
    fi
    sleep 2
  done
  log "falhou ao conectar em ${PAIR_RETRY_SECS}s"
  return 1
}

daemon() {
  log "daemon iniciado (teclado $KB_ADDR, ntfy: ${NTFY_TOPIC:-off}, lock: $RELEASE_ON_LOCK, idle: $RELEASE_IDLE_SECS)"
  if [[ -n "$NTFY_TOPIC" ]]; then
    ntfy_listen &
    trap 'kill $(jobs -p) 2>/dev/null' EXIT
  fi

  local last_attempt=-999 hits=0 idle
  while true; do
    idle="$(idle_secs)"; idle="${idle:-0}"
    if is_connected; then
      hits=0
      if (( RELEASE_ON_LOCK )) && screen_locked; then
        release_local "tela bloqueada"
      elif (( RELEASE_IDLE_SECS > 0 && idle >= RELEASE_IDLE_SECS )); then
        release_local "ocioso há ${idle}s"
      fi
    elif ! screen_locked || (( !RELEASE_ON_LOCK )); then
      # Exige atividade em 2 verificações seguidas para evitar toques acidentais.
      if (( idle < IDLE_THRESHOLD_SECS )); then hits=$(( hits + 1 )); else hits=0; fi
      if (( hits >= 2 && SECONDS - last_attempt > COOLDOWN_SECS )); then
        log "atividade detectada neste Mac sem teclado — puxando"
        last_attempt=$SECONDS
        grab
        hits=0
      fi
    fi
    sleep "$POLL_SECS"
  done
}

status() {
  echo "Teclado:    $KB_ADDR"
  echo "Conectado:  $(is_connected && echo sim || echo não)"
  echo "Idle HID:   $(idle_secs)s"
  echo "Bloqueado:  $(screen_locked && echo sim || echo não)"
  echo "ntfy:       ${NTFY_TOPIC:-(desligado)}"
  echo "Lock/Idle:  RELEASE_ON_LOCK=$RELEASE_ON_LOCK RELEASE_IDLE_SECS=$RELEASE_IDLE_SECS"
}

need
case "${1:-}" in
  daemon)  daemon ;;
  grab)    grab ;;
  release) release_local "manual" ;;
  status)  status ;;
  *) echo "uso: $0 {daemon|grab|release|status}"; exit 2 ;;
esac
