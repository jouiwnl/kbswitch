#!/usr/bin/env bash
# Instala o kbswitch neste Mac. Rode nos DOIS Macs. Não precisa de SSH.
#
#   ./install.sh                 # sem canal entre os Macs (usa atalho/lock/idle)
#   ./install.sh --ntfy          # gera um tópico ntfy novo (rode no 1º Mac)
#   ./install.sh --ntfy TOPICO   # usa o tópico gerado no 1º Mac (rode no 2º)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/kbswitch"
CONF="$HOME/.config/kbswitch.conf"
LABEL="com.$(id -un).kbswitch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/kbswitch.log"

export PATH="$HOME/homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

NTFY_TOPIC=""
if [[ "${1:-}" == "--ntfy" ]]; then
  NTFY_TOPIC="${2:-kbswitch-$(openssl rand -hex 12)}"
fi

export PATH="$HOME/.local/bin:$PATH"
if ! command -v blueutil >/dev/null; then
  # Compila direto do código-fonte oficial: só precisa das Command Line Tools
  # (o brew exige Xcode completo quando o prefixo não é o padrão).
  echo "Compilando blueutil a partir do código-fonte…"
  xcode-select -p >/dev/null 2>&1 || { echo "Instale as Command Line Tools: xcode-select --install"; exit 1; }
  SRC="$(mktemp -d)"
  git clone -q --depth 1 https://github.com/toy/blueutil "$SRC"
  make -C "$SRC" build >/dev/null
  mkdir -p "$HOME/.local/bin"
  install -m 755 "$SRC/blueutil" "$HOME/.local/bin/blueutil"
  rm -rf "$SRC"
fi
blueutil --version

KB_ADDR="$(system_profiler SPBluetoothDataType 2>/dev/null \
  | awk '/Magic Keyboard/ {f=1} f && /Address:/ {print $2; exit}')"
if [[ -z "$KB_ADDR" ]]; then
  read -rp "Não achei o Magic Keyboard. Informe o endereço (ex: B0:BE:83:E5:C2:97): " KB_ADDR
fi
KB_ADDR="$(echo "$KB_ADDR" | tr 'A-F:' 'a-f-')"
echo "Teclado: $KB_ADDR"

mkdir -p "$(dirname "$BIN")" "$(dirname "$CONF")" "$(dirname "$PLIST")"
install -m 755 "$HERE/kbswitch.sh" "$BIN"

cat > "$CONF" <<EOF
KB_ADDR="$KB_ADDR"

# Canal entre os Macs via ntfy (só HTTPS de saída). Vazio = desligado.
NTFY_TOPIC="$NTFY_TOPIC"
NTFY_SERVER="https://ntfy.sh"

# Soltar o teclado automaticamente quando a tela bloquear (1 = sim).
RELEASE_ON_LOCK=0
# Soltar o teclado após N segundos sem nenhum input neste Mac (0 = nunca).
RELEASE_IDLE_SECS=0

POLL_SECS=2
IDLE_THRESHOLD_SECS=2
COOLDOWN_SECS=20
PAIR_RETRY_SECS=30
EOF

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Pronto. Daemon rodando como $LABEL."
[[ -n "$NTFY_TOPIC" ]] && echo "Tópico ntfy: $NTFY_TOPIC   (use no outro Mac: ./install.sh --ntfy $NTFY_TOPIC)"
echo "Config: $CONF"
echo "Log:    tail -f $LOG"
echo "Soltar: $BIN release   (ligue isso a um atalho no app Atalhos)"
