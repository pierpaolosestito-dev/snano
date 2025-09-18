#!/usr/bin/env bash
# snano - editor con backup automatico centralizzato, TTL, pruning e restore
# Uso:
#   snano [--ttl ORE] [-k|--keep] <file>
#   snano --prune [--dry-run] [--force]
#   snano --list
#   snano --restore <backup_path> [--to <dest>] [--overwrite]
#   snano --restore-latest <original_path> [--to <dest>] [--overwrite]
#
# Config opzionale: ~/.config/snano/config
#   TTL_HOURS=24
#   EDITOR=nano
#   BACKUP_ROOT="$HOME/.local/share/snano/backups"

set -Eeuo pipefail

# --- Config/paths -----------------------------------------------------------
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/snano"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/snano"
CONFIG_FILE="$CONFIG_DIR/config"
INDEX_FILE="$STATE_DIR/index.tsv"
HOST="$(hostname 2>/dev/null || echo default)"

mkdir -p "$CONFIG_DIR" "$STATE_DIR"

# Default
TTL_HOURS_DEFAULT=24
EDITOR_CMD="${EDITOR:-nano}"
BACKUP_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/snano/backups"

# Carica config utente (se presente)
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  TTL_HOURS_DEFAULT="${TTL_HOURS:-${TTL_HOURS_DEFAULT}}"
  EDITOR_CMD="${EDITOR:-$EDITOR_CMD}"
  BACKUP_ROOT="${BACKUP_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/snano/backups}"
fi

# --- Utilità ----------------------------------------------------------------
timestamp() { date +"%Y%m%d-%H%M%S"; }
now_epoch() { date +%s; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    echo "-"
  fi
}

file_size() {
  # GNU stat
  if stat -c '%s' -- "$1" >/dev/null 2>&1; then
    stat -c '%s' -- "$1"
  # BSD/macOS
  elif stat -f '%z' -- "$1" >/dev/null 2>&1; then
    stat -f '%z' -- "$1"
  else
    wc -c < "$1" | tr -d ' '
  fi
}

println() { printf '%s\n' "$*"; }
err() { printf 'Errore: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<EOF
Uso:
  snano [--ttl ORE] [-k|--keep] <file>
  snano --prune [--dry-run] [--force]
  snano --list
  snano --restore <backup_path> [--to <dest>] [--overwrite]
  snano --restore-latest <original_path> [--to <dest>] [--overwrite]
Opzioni:
  --ttl ORE         TTL per questo backup (override del default). 0 = non scade.
  -k, --keep        Forza la conservazione del backup (ignora TTL).
  --prune           Elimina i backup scaduti (in base all'indice).
    --dry-run       Mostra cosa verrebbe eliminato, senza toccare nulla.
    --force         Elimina anche backup con TTL=0.
  --list            Elenca i backup registrati.
  --restore         Ripristina dal path di backup.
  --restore-latest  Ripristina l'ultimo backup registrato per un file originale.
  --to <dest>       Percorso di destinazione del ripristino (default: percorso originale).
  --overwrite       Sovrascrive il file di destinazione se esiste.
EOF
  exit 2
}

# Centralizzazione: genera path backup a partire dall'originale
# Esempio: /etc/hosts -> $BACKUP_ROOT/<HOST>/etc/hosts.bak-YYYYmmdd-HHMMSS
backup_path_for() {
  local opath="$1"
  local abs
  abs="$(readlink -f -- "$opath" 2>/dev/null || realpath -- "$opath" 2>/dev/null || python3 - <<PY
import os,sys
print(os.path.abspath(sys.argv[1]))
PY
"$opath")"
  local dir base ts
  dir="$(dirname "$abs")"
  base="$(basename "$abs")"
  ts="$(timestamp)"
  local target_dir="$BACKUP_ROOT/$HOST${dir}"
  mkdir -p -- "$target_dir"
  printf '%s/%s.bak-%s\n' "$target_dir" "$base" "$ts"
}

# --- Indice -----------------------------------------------------------------
# campi: created_epoch \t expires_epoch \t keep \t backup_path \t original_path \t size \t sha256
index_upsert() {
  local created="$1" expires="$2" keep="$3" bpath="$4" opath="$5" size="$6" sum="$7"
  local tmp
  tmp="$(mktemp "$STATE_DIR/index.tmp.XXXXXX")"
  touch "$INDEX_FILE"
  awk -v b="$bpath" -F'\t' 'BEGIN{OFS=FS} $4!=b {print $0}' "$INDEX_FILE" > "$tmp" || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$created" "$expires" "$keep" "$bpath" "$opath" "$size" "$sum" >> "$tmp"
  mv -f -- "$tmp" "$INDEX_FILE"
}

index_remove() {
  local bpath="$1" tmp
  tmp="$(mktemp "$STATE_DIR/index.tmp.XXXXXX")"
  touch "$INDEX_FILE"
  awk -v b="$bpath" -F'\t' 'BEGIN{OFS=FS} $4!=b {print $0}' "$INDEX_FILE" > "$tmp" || true
  mv -f -- "$tmp" "$INDEX_FILE"
}

index_find_latest_for_original() {
  local opath="$1"
  touch "$INDEX_FILE"
  awk -v o="$opath" -F'\t' '
    $5==o {print $1, $4}
  ' "$INDEX_FILE" | sort -nrk1,1 | head -n1 | awk '{print $2}'
}

cmd_list() {
  if [[ ! -s "$INDEX_FILE" ]]; then
    println "Nessun backup registrato."
    exit 0
  fi
  printf '%-20s  %-20s  %-4s  %s\n' "CREATO" "SCADENZA" "K" "BACKUP_PATH"
  while IFS=$'\t' read -r created expires keep bpath _ _ _; do
    [[ -z "$created" ]] && continue
    c_human="$(date -d "@$created" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$created" +'%Y-%m-%d %H:%M:%S')"
    if [[ -n "${expires:-}" && "$expires" -gt 0 ]]; then
      e_human="$(date -d "@$expires" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$expires" +'%Y-%m-%d %H:%M:%S')"
    else
      e_human="(no TTL)"
    fi
    printf '%-20s  %-20s  %-4s  %s\n' "$c_human" "$e_human" "$keep" "$bpath"
  done < "$INDEX_FILE"
}

cmd_prune() {
  local dry_run="${1:-0}" force="${2:-0}"
  touch "$INDEX_FILE"
  local now; now="$(now_epoch)"
  local kept=0 deleted=0 missing=0
  local tmp; tmp="$(mktemp "$STATE_DIR/index.tmp.XXXXXX")"

  while IFS=$'\t' read -r created expires keep bpath opath _ _; do
    [[ -z "${created:-}" ]] && continue
    if [[ "${keep:-0}" -eq 1 && "$force" -ne 1 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t-\t-\n' "$created" "$expires" "$keep" "$bpath" "$opath" >> "$tmp"
      ((kept++)); continue
    fi
    if [[ -z "${expires:-}" || "${expires:-0}" -le 0 ]] && [[ "$force" -ne 1 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t-\t-\n' "$created" "$expires" "$keep" "$bpath" "$opath" >> "$tmp"
      ((kept++)); continue
    fi
    if [[ "$(now_epoch)" -lt "$expires" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t-\t-\n' "$created" "$expires" "$keep" "$bpath" "$opath" >> "$tmp"
      ((kept++)); continue
    fi
    if [[ -e "$bpath" ]]; then
      if [[ "$dry_run" -eq 1 ]]; then
        println "[dry-run] Eliminerei: $bpath (origine: $opath)"
        printf '%s\t%s\t%s\t%s\t%s\t-\t-\n' "$created" "$expires" "$keep" "$bpath" "$opath" >> "$tmp"
        ((kept++))
      else
        rm -f -- "$bpath"
        println "Eliminato: $bpath"
        ((deleted++))
      fi
    else
      ((missing++))
    fi
  done < "$INDEX_FILE"

  if [[ "$dry_run" -eq 0 ]]; then mv -f -- "$tmp" "$INDEX_FILE"; else rm -f -- "$tmp"; fi
  println "Prune: tenuti=$kept, eliminati=$deleted, mancanti=$missing"
}

restore_from_backup() {
  local bpath="$1" dest="$2" overwrite="$3"
  [[ -e "$bpath" ]] || { err "Backup non trovato: $bpath"; exit 1; }

  if [[ -z "$dest" ]]; then
    # prova a reperire il percorso originale dall'indice
    dest="$(awk -v b="$bpath" -F'\t' '$4==b {print $5}' "$INDEX_FILE" 2>/dev/null | tail -n1 || true)"
    [[ -n "$dest" ]] || { err "--to <dest> obbligatorio (origine non trovata in indice)"; exit 2; }
  fi

  local dest_dir; dest_dir="$(dirname "$dest")"
  mkdir -p -- "$dest_dir"

  if [[ -e "$dest" && "${overwrite:-0}" -ne 1 ]]; then
    err "Il file di destinazione esiste: $dest (usa --overwrite per sovrascrivere)"
    exit 2
  fi

  # ripristina preservando permessi; se il ripristino fallisce, non toccare (usa temp+mv)
  local tmp; tmp="$(mktemp "${dest_dir}/.snano.restore.XXXXXX")"
  cp --preserve=mode,ownership,timestamps -- "$bpath" "$tmp"
  mv -f -- "$tmp" "$dest"
  println "Ripristinato: $dest (da $bpath)"
}

# --- Parsing argomenti ------------------------------------------------------
ttl_hours=""
keep_flag=0
mode="edit"
prune_dry=0
prune_force=0
file_arg=""
restore_backup_path=""
restore_latest_original=""
restore_dest=""
restore_overwrite=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ttl)        [[ $# -ge 2 ]] || { err "manca valore per --ttl"; usage; }
                  ttl_hours="$2"; shift 2
                  [[ "$ttl_hours" =~ ^[0-9]+$ ]] || { err "--ttl vuole un intero >=0"; exit 2; };;
    -k|--keep)    keep_flag=1; shift;;
    --prune)      mode="prune"; shift;;
    --dry-run)    prune_dry=1; shift;;
    --force)      prune_force=1; shift;;
    --list)       mode="list"; shift;;
    --restore)    mode="restore"; [[ $# -ge 2 ]] || usage; restore_backup_path="$2"; shift 2;;
    --restore-latest) mode="restore-latest"; [[ $# -ge 2 ]] || usage; restore_latest_original="$2"; shift 2;;
    --to)         [[ $# -ge 2 ]] || usage; restore_dest="$2"; shift 2;;
    --overwrite)  restore_overwrite=1; shift;;
    -h|--help)    usage;;
    -*)
      err "Opzione sconosciuta: $1"; usage;;
    *)
      file_arg="${file_arg:-$1}"; shift;;
  esac
done

case "$mode" in
  prune)  cmd_prune "$prune_dry" "$prune_force"; exit 0;;
  list)   cmd_list; exit 0;;
  restore)
    # espandi ~
    restore_backup_path=$(eval echo "$restore_backup_path")
    restore_dest=$(eval echo "${restore_dest:-}")
    restore_from_backup "$restore_backup_path" "$restore_dest" "$restore_overwrite"
    exit 0;;
  restore-latest)
    # espandi ~
    restore_latest_original=$(eval echo "$restore_latest_original")
    restore_dest=$(eval echo "${restore_dest:-}")
    latest="$(index_find_latest_for_original "$restore_latest_original" || true)"
    [[ -n "$latest" ]] || { err "Nessun backup registrato per: $restore_latest_original"; exit 1; }
    restore_from_backup "$latest" "$restore_dest" "$restore_overwrite"
    exit 0;;
esac

[[ -n "$file_arg" ]] || usage

# --- Flusso "edit" ----------------------------------------------------------
# Espandi "~"
file_arg=$(eval echo "$file_arg")

made_backup=0
backup_path=""

# Crea backup solo se il file esiste ed è non vuoto
if [[ -s "$file_arg" ]]; then
  backup_path="$(backup_path_for "$file_arg")"
  mkdir -p -- "$(dirname "$backup_path")"
  cp --preserve=mode,ownership,timestamps -- "$file_arg" "$backup_path"
  made_backup=1
  println "Backup creato: $backup_path"
fi

# Apri editor
"$EDITOR_CMD" -- "$file_arg"

# Se c'era backup, confronta
if [[ "$made_backup" -eq 1 ]]; then
  if cmp -s -- "$file_arg" "$backup_path"; then
    rm -f -- "$backup_path"
    println "Nessuna modifica: backup eliminato."
  else
    created="$(now_epoch)"
    if [[ "$keep_flag" -eq 1 ]]; then
      expires=0
    else
      ttl="${ttl_hours:-$TTL_HOURS_DEFAULT}"
      if [[ "$ttl" -eq 0 ]]; then
        expires=0
      else
        expires=$(( created + (ttl * 3600) ))
      fi
    fi
    size="$(file_size "$backup_path")"
    sum="$(sha256_of "$backup_path")"
    index_upsert "$created" "$expires" "$keep_flag" "$backup_path" "$file_arg" "$size" "$sum"

    if [[ "$keep_flag" -eq 1 ]]; then
      println "Modifiche rilevate: backup conservato (KEEP) in $backup_path"
    elif [[ "$expires" -gt 0 ]]; then
      println "Modifiche rilevate: backup conservato in $backup_path (scade tra ${ttl}h)"
    else
      println "Modifiche rilevate: backup conservato in $backup_path (senza scadenza)"
    fi
  fi
fi