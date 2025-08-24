#!/usr/bin/env bash
# ==========================
# Argo 2.0 – Gerenciador de Pacotes Linux
# ==========================

# Diretórios principais
ARGO_DIR="$HOME/argo"
REPO_DIR="$ARGO_DIR/repo"
BUILD_DIR="$ARGO_DIR/tmp"
VAR_DIR="$ARGO_DIR/var"
LOG_FILE="$VAR_DIR/argo.log"
MANIFEST_DIR="$VAR_DIR/manifests"

mkdir -p "$REPO_DIR" "$BUILD_DIR" "$VAR_DIR" "$MANIFEST_DIR"

# Configurações
USE_SHA256=true
VERBOSE=true
APPLY_PATCHES=true

INSTALLED_LIST="$VAR_DIR/installed.list"
ORPHAN_LIST="$VAR_DIR/orphan.list"
VERSIONS_LIST="$VAR_DIR/versions.list"

# ==========================
# Cores e spinner
# ==========================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

spinner() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\'
  while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}

# ==========================
# Logs
# ==========================
log_info() { echo -e "${GREEN}[INFO]${RESET} $1"; [[ $VERBOSE == true ]] && echo "[INFO] $1" >> "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; echo "[WARN] $1" >> "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $1"; echo "[ERROR] $1" >> "$LOG_FILE"; }

# ==========================
# Helper para verificar pacote instalado
# ==========================
is_installed() {
  local pkg="$1"
  grep -Fxq "$pkg" "$INSTALLED_LIST" 2>/dev/null
}

# ==========================
# Função Help
# ==========================
show_help() {
cat << EOF
${CYAN}Uso:${RESET} argo.sh <comando> [opções] <pacote>

${CYAN}Comandos:${RESET}
  build <pacote> [--version <versão>]       Compila o pacote sem instalar
  install <pacote> [--destdir <dir>]       Instala o pacote
  remove <pacote>                           Remove o pacote e órfãos
  upgrade <pacote> [--version <nova>]      Atualiza o pacote e recompila dependentes
  clean [<pacote>]                          Limpa tmp e DESTDIR
  info <pacote>                             Mostra informações detalhadas do pacote
  list                                      Lista pacotes instalados
  orphan                                    Lista pacotes órfãos
  hash <pacote> [--verify] [--output <arq>] Gera ou verifica SHA256
  update-db                                 Atualiza repositórios remotos

${CYAN}Opções gerais:${RESET}
  -h, --help       Mostra este help
  -v, --verbose    Habilita log detalhado
  --no-sha256      Desabilita SHA256
  --apply-patches / --no-patches
EOF
}

# ==========================
# Executa hooks
# ==========================
run_hook() {
  local hook="$1"
  local pkg="$2"
  local hook_file="$ARGO_DIR/base/$pkg/hooks/$hook.sh"
  if [[ -f "$hook_file" ]]; then
    log_info "Executando hook $hook para $pkg"
    bash "$hook_file"
  fi
}

# ==========================
# Download e Git sync
# ==========================
fetch_package() {
  local pkg="$1"
  local url="$2"
  mkdir -p "$REPO_DIR/$pkg"
  log_info "Buscando pacote $pkg"
  if [[ "$url" =~ ^https://|http:// ]]; then
    log_info "Baixando via curl: $url"
    curl -L -o "$REPO_DIR/$pkg/$pkg.tar.gz" "$url" &
    spinner $!
  else
    log_info "Clonando via git: $url"
    git clone "$url" "$REPO_DIR/$pkg" &
    spinner $!
  fi
}

# ==========================
# Extração automática
# ==========================
extract_package() {
  local pkg="$1"
  local src="$REPO_DIR/$pkg"
  local dst="$BUILD_DIR/$pkg"
  mkdir -p "$dst"
  if [[ -f "$src/$pkg.tar.gz" ]]; then
    tar -xzf "$src/$pkg.tar.gz" -C "$dst"
  elif [[ -f "$src/$pkg.zip" ]]; then
    unzip "$src/$pkg.zip" -d "$dst"
  else
    cp -a "$src/." "$dst/"
  fi
}

# ==========================
# Aplicação de patches
# ==========================
apply_patches() {
  local pkg="$1"
  local patch_dir="$ARGO_DIR/base/$pkg/patch"
  local dst="$BUILD_DIR/$pkg"
  if [[ $APPLY_PATCHES == true && -d "$patch_dir" ]]; then
    for p in "$patch_dir"/*; do
      log_info "Aplicando patch $p"
      patch -p1 -d "$dst" < "$p"
    done
  fi
}

# ==========================
# Resolver dependências
# ==========================
resolve_dependencies() {
  local pkg="$1"
  local deps_file="$ARGO_DIR/base/$pkg/deps.list"
  if [[ -f "$deps_file" ]]; then
    while read -r dep; do
      [[ -z "$dep" ]] && continue
      if ! is_installed "$dep"; then
        log_info "Compilando dependência $dep"
        build_package "$dep"
        install_package "$dep"
      fi
    done < "$deps_file"
  fi
}

# ==========================
# Build do pacote
# ==========================
build_package() {
  local pkg="$1"
  local tmp_build="$BUILD_DIR/$pkg"
  mkdir -p "$tmp_build"
  run_hook "pre_build" "$pkg"
  resolve_dependencies "$pkg"
  fetch_package "$pkg" "URL_OU_REPO_DO_PACOTE"
  extract_package "$pkg"
  apply_patches "$pkg"
  local build_script="$ARGO_DIR/base/$pkg/build"
  if [[ -f "$build_script" ]]; then
    log_info "Compilando $pkg"
    bash "$build_script" "$tmp_build" || { log_error "Build falhou para $pkg"; return 1; }
  fi
  run_hook "post_build" "$pkg"
  log_info "Build concluído para $pkg"
}

# ==========================
# Instalação do pacote
# ==========================
install_package() {
  local pkg="$1"
  local dest="${2:-/}"
  run_hook "pre_install" "$pkg"
  cp -a "$BUILD_DIR/$pkg/." "$dest/" || { log_error "Falha na instalação de $pkg"; return 1; }
  mkdir -p "$MANIFEST_DIR"
  find "$dest" -type f > "$MANIFEST_DIR/$pkg.list"
  echo "$pkg" >> "$INSTALLED_LIST"
  run_hook "post_install" "$pkg"
  log_info "$pkg instalado em $dest"
}

# ==========================
# Remoção reversa do pacote
# ==========================
remove_package() {
  local pkg="$1"
  run_hook "pre_remove" "$pkg"
  local manifest="$MANIFEST_DIR/$pkg.list"
  if [[ -f "$manifest" ]]; then
    tac "$manifest" | xargs -d '\n' rm -rf
  fi
  sed -i "/^$pkg$/d" "$INSTALLED_LIST"
  rm -f "$MANIFEST_DIR/$pkg.list"
  run_hook "post_remove" "$pkg"
  log_info "$pkg removido"
}

# ==========================
# Clean
# ==========================
clean_package() {
  local pkg="$1"
  run_hook "pre_clean" "$pkg"
  if [[ -n "$pkg" ]]; then
    rm -rf "$BUILD_DIR/$pkg"
  else
    rm -rf "$BUILD_DIR/*"
  fi
  run_hook "post_clean" "$pkg"
  log_info "Clean concluído para $pkg"
}

# ==========================
# SHA256
# ==========================
hash_package() {
  local pkg="$1"
  local verify="$2"
  local output="$3"
  local manifest="$MANIFEST_DIR/$pkg.list"
  if [[ ! -f "$manifest" ]]; then log_error "Manifesto não encontrado para $pkg"; return; fi
  while read -r file; do
    sha=$(sha256sum "$file" | awk '{print $1}')
    if [[ $verify == true ]]; then
      echo "$file : $sha"
    else
      echo "$sha  $file"
    fi
  done < "$manifest" | tee "$output"
}

# ==========================
# Upgrade do pacote
# ==========================
upgrade_package() {
  local pkg="$1"
  local new_version="$2"
  if ! is_installed "$pkg"; then
    log_error "$pkg não está instalado"
    return
  fi
  log_info "Iniciando upgrade de $pkg para versão $new_version"
  
  # Build da nova versão
  build_package "$pkg"
  
  # Instalação em DESTDIR temporário
  local tmp_dest="$BUILD_DIR/$pkg/destdir"
  mkdir -p "$tmp_dest"
  install_package "$pkg" "$tmp_dest"
  
  # Substituição final no sistema
  cp -a "$tmp_dest/." "/"
  echo "$pkg $new_version" >> "$VERSIONS_LIST"
  
  # Recompilação de dependentes
  if [[ -f "$INSTALLED_LIST" ]]; then
    while read -r dep_pkg; do
      local dep_file="$ARGO_DIR/base/$dep_pkg/deps.list"
      if [[ -f "$dep_file" && $(grep -c "^$pkg$" "$dep_file") -gt 0 ]]; then
        log_info "Recompilando dependente $dep_pkg"
        build_package "$dep_pkg"
        install_package "$dep_pkg"
      fi
    done < "$INSTALLED_LIST"
  fi
  log_info "Upgrade concluído para $pkg"
}

# ==========================
# Info detalhado sobre pacote
# ==========================
info_package() {
  local pkg="$1"
  echo -e "${CYAN}Pacote:${RESET} $pkg"
  if [[ -f "$VERSIONS_LIST" ]]; then
    grep "^$pkg" "$VERSIONS_LIST" | while read -r line; do
      echo -e "${CYAN}Versão:${RESET} $(echo $line | awk '{print $2}')"
    done
  fi
  local deps_file="$ARGO_DIR/base/$pkg/deps.list"
  if [[ -f "$deps_file" ]]; then
    echo -e "${CYAN}Dependências:${RESET} $(cat $deps_file | xargs)"
  fi
  local manifest="$MANIFEST_DIR/$pkg.list"
  if [[ -f "$manifest" ]]; then
    echo -e "${CYAN}Arquivos instalados:${RESET} $(wc -l < $manifest)"
  fi
}

# ==========================
# Listar pacotes instalados
# ==========================
list_packages() {
  echo -e "${CYAN}Pacotes instalados:${RESET}"
  cat "$INSTALLED_LIST" 2>/dev/null
}

# ==========================
# Listar pacotes órfãos
# ==========================
list_orphans() {
  echo -e "${CYAN}Pacotes órfãos:${RESET}"
  cat "$ORPHAN_LIST" 2>/dev/null
}

# ==========================
# Atualização de repositórios
# ==========================
update_repo_db() {
  [[ ! -f "$ARGO_DIR/repos.list" ]] && { log_error "repos.list não encontrado"; return 1; }
  while read -r line; do
    [[ "$line" =~ ^# ]] && continue
    repo_name=$(echo $line | awk '{print $1}')
    repo_url=$(echo $line | awk '{print $2}')
    repo_type=$(echo $line | awk '{print $3}')
    mkdir -p "$REPO_DIR/$repo_name"
    case "$repo_type" in
      git)
        if [[ -d "$REPO_DIR/$repo_name/.git" ]]; then
          git -C "$REPO_DIR/$repo_name" pull
        else
          git clone "$repo_url" "$REPO_DIR/$repo_name"
        fi
        ;;
      tar.gz|zip)
        curl -L -o "$REPO_DIR/$repo_name/$repo_name.$repo_type" "$repo_url"
        ;;
      *)
        log_warn "Tipo desconhecido para repositório $repo_name"
        ;;
    esac
  done < "$ARGO_DIR/repos.list"
  log_info "Banco de pacotes atualizado"
}

# ==========================
# CLI Parsing
# ==========================
COMMAND="$1"; shift

case "$COMMAND" in
  build)
    PKG="$1"; shift
    build_package "$PKG"
    ;;
    
  install)
    PKG="$1"; shift
    DESTDIR="/"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --destdir) DESTDIR="$2"; shift 2;;
        *) shift;;
      esac
    done
    install_package "$PKG" "$DESTDIR"
    ;;
    
  remove)
    PKG="$1"; shift
    remove_package "$PKG"
    ;;
    
  upgrade)
    PKG="$1"; shift
    NEW_VER="$1"; shift
    upgrade_package "$PKG" "$NEW_VER"
    ;;
    
  clean)
    PKG="$1"
    clean_package "$PKG"
    ;;
    
  hash)
    PKG="$1"; shift
    VERIFY=false
    OUTPUT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --verify) VERIFY=true; shift;;
        --output) OUTPUT="$2"; shift 2;;
        *) shift;;
      esac
    done
    hash_package "$PKG" "$VERIFY" "$OUTPUT"
    ;;
    
  update-db)
    update_repo_db
    ;;
    
  info)
    PKG="$1"; shift
    info_package "$PKG"
    ;;
    
  list)
    list_packages
    ;;
    
  orphan)
    list_orphans
    ;;
    
  -h|--help|help)
    show_help
    ;;
    
  *)
    log_error "Comando inválido: $COMMAND"
    show_help
    ;;
esac
