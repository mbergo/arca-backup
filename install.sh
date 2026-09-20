#!/usr/bin/env bash
# arca — instalador interativo.
# Uso:  ./install.sh              (pergunta tudo)
#       ./install.sh --defaults   (aceita os padrões, só pede o que é obrigatório)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$HOME/.config/arca"
BIN_DIR="$HOME/.local/bin"
DEFAULTS=0
[[ "${1:-}" == "--defaults" ]] && DEFAULTS=1

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
log()  { printf '\033[1;34m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

ask() { # ask <pergunta> <padrão>
  local resposta
  if [[ $DEFAULTS == 1 ]]; then printf '%s' "$2"; return; fi
  read -r -p "$1 [$2]: " resposta </dev/tty
  printf '%s' "${resposta:-$2}"
}
confirm() { # confirm <pergunta> <s|n>
  local resposta
  if [[ $DEFAULTS == 1 ]]; then [[ "$2" == s ]]; return; fi
  read -r -p "$1 [$( [[ $2 == s ]] && echo 'S/n' || echo 's/N' )]: " resposta </dev/tty
  resposta="${resposta:-$2}"
  [[ "${resposta,,}" == s* || "${resposta,,}" == y* ]]
}

bold "┌──────────────────────────────────────────┐"
bold "│  arca — backup do home para a nuvem      │"
bold "└──────────────────────────────────────────┘"
echo

# ── 1. dependências ──────────────────────────────────────────────────────────
log "verificando restic e rclone"
faltando=()
for b in restic rclone; do command -v "$b" >/dev/null || faltando+=("$b"); done

if [[ ${#faltando[@]} -gt 0 ]]; then
  echo "   faltam: ${faltando[*]}"
  if   command -v apt-get >/dev/null; then INSTALA="sudo apt-get install -y ${faltando[*]}"
  elif command -v dnf     >/dev/null; then INSTALA="sudo dnf install -y ${faltando[*]}"
  elif command -v pacman  >/dev/null; then INSTALA="sudo pacman -S --noconfirm ${faltando[*]}"
  elif command -v zypper  >/dev/null; then INSTALA="sudo zypper install -y ${faltando[*]}"
  elif command -v brew    >/dev/null; then INSTALA="brew install ${faltando[*]}"
  else die "instale manualmente: ${faltando[*]}"; fi
  if confirm "instalar agora com: $INSTALA ?" s; then
    eval "$INSTALA"
  else
    die "sem restic e rclone não dá para seguir"
  fi
fi
log "restic $(restic version | awk '{print $2}') · rclone $(rclone version | head -1 | awk '{print $2}')"
echo

# ── 2. remote do Google Drive ────────────────────────────────────────────────
REMOTE="$(ask "nome do remote no rclone" "gdrive")"
if rclone listremotes 2>/dev/null | grep -qx "${REMOTE}:"; then
  log "remote '$REMOTE' já existe"
else
  bold "Autorização do Google Drive"
  cat <<'TXT'
   O rclone vai abrir o navegador para você autorizar a conta.
   Em máquina sem navegador, ele mostra um comando para rodar em outra
   máquina e colar o token de volta.

   Opcional: usar credenciais OAuth próprias (mais rápido e sem limite
   compartilhado). Como obter está no README, seção "Credenciais próprias".
TXT
  CID=""; CSEC=""
  if confirm "tem client_id e client_secret próprios para usar?" n; then
    CID="$(ask  "client_id" "")"
    CSEC="$(ask "client_secret" "")"
  fi
  args=(config create "$REMOTE" drive scope=drive)
  [[ -n "$CID"  ]] && args+=("client_id=$CID")
  [[ -n "$CSEC" ]] && args+=("client_secret=$CSEC")
  rclone "${args[@]}" || die "falhou ao criar o remote"
  log "remote '$REMOTE' criado"
fi
echo

# ── 3. onde guardar ──────────────────────────────────────────────────────────
CAMINHO="$(ask "pasta do backup dentro do Drive" "Backups/arca-$(hostname -s)")"
FONTE="$(ask   "o que fazer backup" "$HOME")"
echo

# ── 4. senha do repositório ──────────────────────────────────────────────────
mkdir -p "$CONF_DIR"
if [[ -f "$CONF_DIR/password" ]]; then
  log "senha do repositório já existe em $CONF_DIR/password"
else
  if confirm "gerar uma senha aleatória para o repositório?" s; then
    head -c 32 /dev/urandom | base64 | tr -d '\n' > "$CONF_DIR/password"
  else
    read -r -s -p "digite a senha: " P </dev/tty; echo
    printf '%s' "$P" > "$CONF_DIR/password"
  fi
  chmod 600 "$CONF_DIR/password"
  echo
  bold "══════════════════════════════════════════════════════════════"
  bold " SENHA DO REPOSITÓRIO — guarde fora desta máquina."
  bold " Sem ela o backup é irrecuperável. Nem o Google abre."
  echo
  echo "   $(cat "$CONF_DIR/password")"
  bold "══════════════════════════════════════════════════════════════"
  echo
  [[ $DEFAULTS == 1 ]] || read -r -p "anotou? enter para seguir " </dev/tty
fi

# ── 5. arquivos ──────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$CONF_DIR"
install -m 755 "$REPO_DIR/bin/arca" "$BIN_DIR/arca"
if [[ -f "$CONF_DIR/excludes.txt" ]] && ! confirm "sobrescrever o excludes.txt atual?" n; then
  log "excludes mantido"
else
  sed "s|__HOME__|$HOME|g" "$REPO_DIR/lib/excludes.txt" > "$CONF_DIR/excludes.txt"
fi

NICE=1;  confirm "rodar em prioridade baixa (nice+ionice)?" s || NICE=0
LIMITE="$(ask "limite de upload em KiB/s (0 = sem limite)" "0")"

cat > "$CONF_DIR/config" <<CFG
# arca — configuração. Editável a qualquer momento.
ARCA_REMOTE="$REMOTE"
ARCA_REPO="rclone:$REMOTE:$CAMINHO"
ARCA_PASSWORD_FILE="$CONF_DIR/password"
ARCA_EXCLUDES="$CONF_DIR/excludes.txt"
ARCA_SOURCE="$FONTE"

# caminhos extras, separados por espaço (ex: "/etc /srv")
ARCA_EXTRA_PATHS=""

# prioridade baixa de CPU e disco
ARCA_NICE=$NICE
# limite de upload em KiB/s (0 = sem limite). 4096 = 4 MiB/s
ARCA_LIMIT_UPLOAD=$LIMITE

# retenção
ARCA_KEEP_DAILY=7
ARCA_KEEP_WEEKLY=4
ARCA_KEEP_MONTHLY=12
ARCA_PRUNE_DAY=7          # 1=seg .. 7=dom — dia em que libera espaço de verdade

# desempenho do rclone
ARCA_CHUNK_SIZE=64M
ARCA_TRANSFERS=8
CFG
log "config em $CONF_DIR/config"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR não está no PATH — adicione no seu shell rc:"
     echo '   export PATH="$HOME/.local/bin:$PATH"' ;;
esac
echo

# ── 6. agendamento ───────────────────────────────────────────────────────────
if confirm "agendar o backup diário?" s; then
  HORA="$(ask "hora (madrugada é melhor)" "03:17")"
  "$BIN_DIR/arca" cron-install "$HORA"
fi
echo

# ── 7. primeiro backup ───────────────────────────────────────────────────────
bold "Pronto para o primeiro backup."
echo "   Ele é o demorado: sobe tudo. Os próximos mandam só o que mudou."
echo "   Roda em prioridade baixa, dá para trabalhar normalmente."
echo
if confirm "rodar o backup completo agora?" s; then
  "$BIN_DIR/arca" full
else
  echo "   quando quiser:  arca full"
fi
echo
bold "Instalado."
echo "   arca backup     · incremental (a cron roda sozinha)"
echo "   arca snapshots  · pontos no tempo"
echo "   arca restore    · trazer de volta"
echo "   arca --help     · o resto"
