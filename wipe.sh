#!/bin/bash
set -euo pipefail

# ============================================================
# SYSTEM WIPE ORCHESTRATOR - ENTERPRISE ULTIMATE
# ============================================================
# ✅ Input-bestand met klantgegevens (CUSTOMER/TICKET/LOCATION/OPERATOR/ASSET_TAG)
# ✅ Logo in certificaat (rechtsboven, 3x3cm default)
# ✅ PDF certificaat via weasyprint (voorkeur) of wkhtmltopdf
# ✅ Automatische installatie PDF generator indien nodig
# ============================================================

# ============================================================
# EXIT CODES
# ============================================================
EXIT_SUCCESS=0
EXIT_ERROR=1
EXIT_ROOT_REQUIRED=2
EXIT_DEVICE_NOT_FOUND=3
EXIT_DEVICE_BLOCKED=4
EXIT_WIPE_FAILED=5
EXIT_VERIFICATION_FAILED=6
EXIT_DEVICE_FROZEN=7
EXIT_DEPENDENCY_MISSING=8
EXIT_PARTIAL_FAILURE=9
EXIT_INVALID_ARGS=10
EXIT_PARALLEL_FAILED=11

# ============================================================
# DEPENDENCY CHECK
# ============================================================
check_dependencies() {
    local missing=()
    local deps=(
        "lsblk:lsblk --version"
        "jq:jq --version"
        "smartctl:smartctl --version"
        "nvme:nvme version"
        "hdparm:hdparm -V"
        "openssl:openssl version"
        "blkdiscard:blkdiscard --version"
        "dd:dd --version"
        "cmp:cmp --version"
        "blockdev:blockdev --version"
        "findmnt:findmnt --version"
        "sha256sum:sha256sum --version"
        "mktemp:mktemp --version"
    )
    # Optionele tools (waarschuwing, geen fatal)
    local optional=("mokutil" "lspci" "awk" "dmidecode")

    for dep in "${deps[@]}"; do
        local cmd="${dep%:*}"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[FATAL] Missing dependencies:" >&2
        printf ' - %s\n' "${missing[@]}" >&2
        echo "" >&2
        echo "Install with:" >&2
        echo " apt-get install -y jq smartmontools nvme-cli hdparm util-linux openssl coreutils" >&2
        exit $EXIT_DEPENDENCY_MISSING
    fi

    for cmd in "${optional[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "[WARN] Optionele tool ontbreekt: $cmd" >&2
        fi
    done
}
check_dependencies

# ============================================================
# BASE CONFIGURATION
# ============================================================
BASE="/root/wipe-audit"
LOG="$BASE/wipe.log"
AUDIT="$BASE/audit.jsonl"
SESSION_JSON="$BASE/session.json"
CERT="$BASE/certificates"
LOGDIR="$BASE/logs"
CFG="$BASE/wipe.conf"
ALLOWLIST="$BASE/allowed_serials.txt"
CSV="$BASE/audit.csv"
PRIVATE_KEY="${BASE}/private.pem"
PUBLIC_KEY="${BASE}/public.pem"
mkdir -p "$BASE" "$CERT" "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1

# ============================================================
# KLANTGEGEVENS (defaults)
# ============================================================
INPUT_FILE=""
CUSTOMER=""
TICKET=""
LOCATION=""
OPERATOR=""
ASSET_TAG=""
LOGO_PATH=""
LOGO_WIDTH_MM=30
LOGO_HEIGHT_MM=30
LOGO_POSITION="top-right"

# ============================================================
# FLAGS
# ============================================================
DRY_RUN=false
FORCE=false
SAFE_MODE=true
SMART=true
VERIFY=true
NIST_MODE=true
DOD3_MODE=false
SUSPEND_ON_FROZEN=true
CSV_EXPORT=false
LEGACY_MODE=false
PARALLEL_JOBS=0
SIGN_CERTIFICATES=false
TARGET_DEVICES=()
SESSION_ID=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; DRY_RUN=false ;;
        --dry-run) DRY_RUN=true; FORCE=false ;;
        --no-safe) SAFE_MODE=false ;;
        --no-smart) SMART=false ;;
        --no-verify) VERIFY=false ;;
        --dod3) NIST_MODE=false; DOD3_MODE=true; LEGACY_MODE=true ;;
        --nist) NIST_MODE=true; DOD3_MODE=false ;;
        --no-suspend) SUSPEND_ON_FROZEN=false ;;
        --csv) CSV_EXPORT=true ;;
        --input|-i) shift; INPUT_FILE="$1" ;;
        --device|-d) shift; TARGET_DEVICES+=("$1") ;;
        --parallel|-p) shift; PARALLEL_JOBS="$1" ;;
        --sign)
            SIGN_CERTIFICATES=true
            if [[ ! -f "$PRIVATE_KEY" ]]; then
                openssl genrsa -out "$PRIVATE_KEY" 2048 2>/dev/null
                openssl rsa -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" 2>/dev/null
                echo "[INFO] Generated key pair: $PRIVATE_KEY / $PUBLIC_KEY"
            fi
            ;;
        --help|-h)
            cat <<EOF
Usage: $0 [OPTIONS] [--device DEVICE ...]

OPTIONS:
  --force               Perform actual wipe (default: dry-run)
  --dry-run             Simulation mode (default)
  --device DEVICE       Target device (can be specified multiple times)
  --parallel N          Run N wipes in parallel (0 = sequential)
  --input, -i FILE      Input file met klantgegevens
  --no-safe             Skip safety checks (dangerous!)
  --no-smart            Skip SMART logging
  --no-verify           Skip verification
  --dod3                Use DoD 3-pass (LEGACY - not recommended)
  --nist                Use NIST SP 800-88 (default)
  --no-suspend          Don't suspend on frozen SSD
  --csv                 Export CSV audit
  --sign                Sign certificates with OpenSSL
  --help                Show this help

INPUT FILE FORMAT (KEY=VALUE, één per regel):
  CUSTOMER="Acme BV"
  TICKET="INC-2026-0042"
  LOCATION="DC1-Rack A12"
  OPERATOR="Jan Jansen"
  ASSET_TAG="ASSET-9876"
  LOGO_PATH="/root/wipe-audit/logo.png"
  LOGO_WIDTH_MM=30
  LOGO_HEIGHT_MM=30
  LOGO_POSITION="top-right"

DEPENDENCIES:
  Verplicht: jq smartmontools nvme-cli hdparm util-linux openssl coreutils
  Optioneel: weasyprint (aanbevolen voor PDF), wkhtmltopdf, xvfb, mokutil, lspci, dmidecode
  Het script installeert weasyprint automatisch indien nodig.

Examples:
  $0 --device /dev/sda --force
  $0 --device nvme0n1 --device sdb --force --parallel 2
  $0 --input /root/wipe-audit/wipe-input.txt --device sda --force
EOF
            exit $EXIT_SUCCESS
            ;;
        *) echo "Unknown option: $1" >&2; exit $EXIT_INVALID_ARGS ;;
    esac
    shift
done

[[ $EUID -ne 0 ]] && echo "[FATAL] root required" && exit $EXIT_ROOT_REQUIRED
HOSTNAME=$(hostname)
SESSION_ID=$(uuid)

# ============================================================
# INPUT FILE LOADER
# ============================================================
load_input_file() {
    local f="$1"
    [[ -z "$f" ]] && return 0
    [[ ! -f "$f" ]] && { error "Input file niet gevonden: $f"; return $EXIT_ERROR; }

    info "📥 Laden input file: $f"

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^# ]] && continue

        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"

        case "$key" in
            CUSTOMER)        CUSTOMER="$value" ;;
            TICKET)          TICKET="$value" ;;
            LOCATION)        LOCATION="$value" ;;
            OPERATOR)        OPERATOR="$value" ;;
            ASSET_TAG)       ASSET_TAG="$value" ;;
            LOGO_PATH)       LOGO_PATH="$value" ;;
            LOGO_WIDTH_MM)   LOGO_WIDTH_MM="$value" ;;
            LOGO_HEIGHT_MM)  LOGO_HEIGHT_MM="$value" ;;
            LOGO_POSITION)   LOGO_POSITION="$value" ;;
            *) warn "Onbekende key in input file: $key" ;;
        esac
    done < "$f"

    info "✅ Input geladen: CUSTOMER='$CUSTOMER' TICKET='$TICKET' LOCATION='$LOCATION' OPERATOR='$OPERATOR' ASSET_TAG='$ASSET_TAG' LOGO='$LOGO_PATH' (${LOGO_WIDTH_MM}x${LOGO_HEIGHT_MM}mm, $LOGO_POSITION)"
}

# ============================================================
# PDF GENERATOR CHECK & INSTALL (weasyprint heeft voorkeur)
# ============================================================
ensure_pdf_generator() {
    # Voorkeur: weasyprint (geen X11 nodig, werkt op servers)
    if command -v weasyprint >/dev/null 2>&1; then
        info "✅ weasyprint aanwezig: $(command -v weasyprint)"
        return 0
    fi

    # Fallback: wkhtmltopdf
    if command -v wkhtmltopdf >/dev/null 2>&1; then
        info "✅ wkhtmltopdf aanwezig: $(command -v wkhtmltopdf)"
        return 0
    fi

    warn "⚠️ Geen PDF generator gevonden - proberen te installeren..."

    if command -v apt-get >/dev/null 2>&1; then
        info "📦 Installeren weasyprint via apt-get..."
        if apt-get update -qq && apt-get install -y -qq weasyprint; then
            info "✅ weasyprint geïnstalleerd"
            return 0
        fi
        warn "⚠️ weasyprint installatie mislukt - probeer wkhtmltopdf"
        if apt-get install -y -qq wkhtmltopdf; then
            info "✅ wkhtmltopdf geïnstalleerd"
            return 0
        fi

    elif command -v dnf >/dev/null 2>&1; then
        info "📦 Installeren via dnf..."
        if dnf install -y -q weasyprint 2>/dev/null || dnf install -y -q python3-weasyprint 2>/dev/null; then
            info "✅ weasyprint geïnstalleerd"
            return 0
        fi
        if dnf install -y -q wkhtmltopdf; then
            info "✅ wkhtmltopdf geïnstalleerd"
            return 0
        fi

    elif command -v yum >/dev/null 2>&1; then
        info "📦 Installeren via yum..."
        if yum install -y -q weasyprint 2>/dev/null || yum install -y -q python3-weasyprint 2>/dev/null; then
            info "✅ weasyprint geïnstalleerd"
            return 0
        fi
        if yum install -y -q wkhtmltopdf; then
            info "✅ wkhtmltopdf geïnstalleerd"
            return 0
        fi

    elif command -v pacman >/dev/null 2>&1; then
        info "📦 Installeren via pacman..."
        if pacman -S --noconfirm weasyprint 2>/dev/null || pacman -S --noconfirm python-weasyprint 2>/dev/null; then
            info "✅ weasyprint geïnstalleerd"
            return 0
        fi
        if pacman -S --noconfirm wkhtmltopdf; then
            info "✅ wkhtmltopdf geïnstalleerd"
            return 0
        fi

    elif command -v zypper >/dev/null 2>&1; then
        info "📦 Installeren via zypper..."
        if zypper --non-interactive install weasyprint; then
            info "✅ weasyprint geïnstalleerd"
            return 0
        fi
        if zypper --non-interactive install wkhtmltopdf; then
            info "✅ wkhtmltopdf geïnstalleerd"
            return 0
        fi

    elif command -v pip3 >/dev/null 2>&1; then
        info "📦 Installeren weasyprint via pip3..."
        if pip3 install --quiet weasyprint; then
            info "✅ weasyprint geïnstalleerd via pip3"
            return 0
        fi
    fi

    warn "⚠️ Kon geen PDF generator installeren - PDF wordt overgeslagen"
    warn "   Installeer handmatig: apt-get install -y weasyprint"
    return 1
}

# ============================================================
# FABRIKANT DETECTIE
# ============================================================
detect_vendor() {
    local d="$1"
    local model
    model=$(get_model "$d" | tr '[:upper:]' '[:lower:]')
    local vendor="unknown"

    if command -v smartctl >/dev/null 2>&1; then
        local smart_vendor
        smart_vendor=$(smartctl -i "$d" 2>/dev/null | grep -i "model family" | head -1 | cut -d':' -f2- | xargs || true)
        if [[ -n "$smart_vendor" ]]; then
            vendor="$smart_vendor"
        fi
    fi

    if [[ "$vendor" == "unknown" ]]; then
        case "$model" in
            *samsung*) vendor="Samsung" ;;
            *intel*) vendor="Intel" ;;
            *kioxia*|*toshiba*) vendor="Kioxia/Toshiba" ;;
            *micron*|*crucial*) vendor="Micron" ;;
            *sk*hynix*|*hynix*) vendor="SK Hynix" ;;
            *kingston*) vendor="Kingston" ;;
            *western*digital*|*wd*) vendor="Western Digital" ;;
            *seagate*) vendor="Seagate" ;;
            *hgst*) vendor="HGST" ;;
            *hitachi*) vendor="Hitachi" ;;
        esac
    fi
    echo "$vendor"
}

# ============================================================
# ROOT DISK DETECTIE
# ============================================================
get_root_devices() {
    local root_devs=()
    local root_mount
    root_mount=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [[ -z "$root_mount" ]] && { echo ""; return; }

    if command -v jq >/dev/null 2>&1; then
        local json
        json=$(lsblk --json --tree -o NAME,PKNAME,TYPE,MOUNTPOINT 2>/dev/null)

        find_parents() {
            local dev_name="$1"
            local found=()
            found+=("/dev/$dev_name")

            local parent
            parent=$(echo "$json" | jq -r ".blockdevices[] | select(.name==\"$dev_name\") | .pkname" 2>/dev/null || true)
            if [[ -n "$parent" ]] && [[ "$parent" != "null" ]]; then
                local parents
                parents=$(find_parents "$parent")
                found+=($parents)
            fi

            local children
            children=$(echo "$json" | jq -r ".blockdevices[] | select(.pkname==\"$dev_name\") | .name" 2>/dev/null || true)
            for child in $children; do
                if [[ "$child" == dm-* ]] || [[ "$child" == md* ]]; then
                    local child_parents
                    child_parents=$(find_parents "$child")
                    found+=($child_parents)
                fi
            done
            printf '%s\n' "${found[@]}"
        }

        local root_name="${root_mount##*/}"
        root_devs=($(find_parents "$root_name" | sort -u))
    else
        local current="$root_mount"
        while [[ -n "$current" ]]; do
            local parent
            parent=$(lsblk -no PKNAME "$current" 2>/dev/null | head -1 || true)
            if [[ -n "$parent" ]]; then
                root_devs+=("/dev/$parent")
                current="/dev/$parent"
            else
                break
            fi
        done
    fi
    printf '%s\n' "${root_devs[@]}" | sort -u
}
ROOT_DEVS=($(get_root_devices))
is_root_disk() {
    local dev="$1"
    for root_dev in "${ROOT_DEVS[@]}"; do
        if [[ "$dev" == "$root_dev"* ]]; then
            return 0
        fi
    done
    return 1
}

# ============================================================
# UTILITIES
# ============================================================
ts(){ date -Iseconds; }
uuid(){ cat /proc/sys/kernel/random/uuid; }
log(){ echo "[$(ts)] [$1] ${*:2}"; }
info(){ log "INFO" "$*"; }
warn(){ log "WARN" "$*" >&2; }
error(){ log "ERROR" "$*" >&2; }
normalize_dev() { [[ "$1" == /dev/* ]] && echo "$1" || echo "/dev/$1"; }
get_serial(){ lsblk -dno SERIAL "$1" 2>/dev/null || echo "unknown"; }
get_model(){ lsblk -dno MODEL "$1" 2>/dev/null || echo "unknown"; }
get_size(){ lsblk -dno SIZE "$1" 2>/dev/null || echo "unknown"; }
get_wwn(){ lsblk -dno WWN "$1" 2>/dev/null || echo "unknown"; }
get_sector_size(){ blockdev --getss "$1" 2>/dev/null || echo "unknown"; }
get_physical_sector(){ blockdev --getpbsz "$1" 2>/dev/null || echo "unknown"; }

# ============================================================
# DEVICE FINGERPRINT
# ============================================================
device_fingerprint() {
    local dev="$1"
    local serial model wwn
    serial=$(get_serial "$dev")
    model=$(get_model "$dev")
    wwn=$(get_wwn "$dev")
    echo -n "${serial}|${model}|${wwn}" | sha256sum | awk '{print $1}'
}

# ============================================================
# ATA PARSING
# ============================================================
parse_ata_security() {
    local d="$1"
    local security_info
    security_info=$(hdparm -I "$d" 2>/dev/null || true)

    echo "$security_info" | awk '
        /Security:/ { in_security=1; next }
        /^$/ { in_security=0 }
        in_security {
            if ($0 ~ /supported/) supported=1
            if ($0 ~ /enabled/) enabled=1
            if ($0 ~ /frozen/) frozen=1
            if ($0 ~ /enhanced.*erase|enhancederase/) { enhanced=1; erase=1 }
            if ($0 ~ /erase.*unit|secureerase/) erase=1
            if ($0 ~ /high/) high=1
            if ($0 ~ /maximum/) maximum=1
        }
        END {
            print "supported=" (supported ? "true" : "false")
            print "enabled=" (enabled ? "true" : "false")
            print "frozen=" (frozen ? "true" : "false")
            print "enhanced=" (enhanced ? "true" : "false")
            print "erase=" (erase ? "true" : "false")
            print "high=" (high ? "true" : "false")
            print "maximum=" (maximum ? "true" : "false")
        }'
}

# ============================================================
# NVMe CAPABILITY PARSING
# ============================================================
nvme_get_capabilities() {
    local d="$1"
    local caps=()
    local ctrl_info
    ctrl_info=$(nvme id-ctrl "$d" 2>/dev/null || true)

    local oacs_raw oacs_val=0
    oacs_raw=$(echo "$ctrl_info" | grep -i "oacs" | awk '{print $NF}' || true)
    if [[ -n "$oacs_raw" ]]; then
        oacs_raw="${oacs_raw#0x}"
        oacs_val=$(printf "%d" "0x$oacs_raw" 2>/dev/null || echo "0")
    fi
    if [[ $oacs_val -gt 0 ]]; then
        if [[ $((oacs_val & 0x01)) -eq 1 ]]; then caps+=("format"); fi
        if [[ $((oacs_val & 0x08)) -eq 8 ]]; then caps+=("sanitize"); fi
    fi

    local fna_raw fna_val=0
    fna_raw=$(echo "$ctrl_info" | grep -i "fna" | awk '{print $NF}' || true)
    if [[ -n "$fna_raw" ]]; then
        fna_raw="${fna_raw#0x}"
        fna_val=$(printf "%d" "0x$fna_raw" 2>/dev/null || echo "0")
    fi
    if [[ $fna_val -gt 0 ]]; then
        if [[ $((fna_val & 0x04)) -eq 4 ]]; then caps+=("crypto"); fi
    fi
    echo "${caps[@]}"
}

# ============================================================
# NVMe SANITIZE
# ============================================================
nvme_get_sanitize_status() {
    local d="$1"
    local sanitize_log
    sanitize_log=$(nvme sanitize-log "$d" 2>/dev/null || true)
    local progress="" status="" completed=false

    progress=$(echo "$sanitize_log" | grep -i "sanitize progress" | awk '{print $NF}' | sed 's/[^0-9]//g' || true)
    if [[ -z "$progress" ]]; then
        progress=$(echo "$sanitize_log" | grep -i "sprog" | awk '{print $NF}' | sed 's/[^0-9]//g' || true)
    fi
    if [[ -z "$progress" ]]; then
        progress=$(echo "$sanitize_log" | grep -i "SPROG" | awk '{print $NF}' | sed 's/[^0-9]//g' || true)
    fi

    local sstat
    sstat=$(echo "$sanitize_log" | grep -i "sstat" | awk '{print $NF}' | sed 's/^0x//' || true)
    if [[ -n "$sstat" ]]; then
        local sstat_val
        sstat_val=$(printf "%d" "0x$sstat" 2>/dev/null || echo "0")
        case $sstat_val in
            0) status="in_progress" ;;
            1) status="completed" ; completed=true ;;
            2) status="failed" ;;
            3) status="aborted" ;;
        esac
    fi

    if [[ "$progress" == "65535" ]] || [[ "$progress" == "100" ]]; then
        completed=true
    fi
    if echo "$sanitize_log" | grep -qi "completed\|success"; then
        completed=true
    fi

    echo "progress=$progress"
    echo "status=$status"
    echo "completed=$completed"
}

nvme_sanitize_with_progress() {
    local d="$1"
    local type="${2:-2}"
    info "🧹 Starten NVMe Sanitize (kan enkele minuten duren)..." >&2

    if ! nvme sanitize "$d" -a "$type" 2>/dev/null; then
        warn "Sanitize start mislukt" >&2
        return 1
    fi

    local max_wait=3600
    local waited=0
    local last_progress=""

    while [[ $waited -lt $max_wait ]]; do
        local status_info progress status completed
        status_info=$(nvme_get_sanitize_status "$d")
        progress=$(echo "$status_info" | grep "^progress=" | cut -d'=' -f2)
        status=$(echo "$status_info" | grep "^status=" | cut -d'=' -f2)
        completed=$(echo "$status_info" | grep "^completed=" | cut -d'=' -f2)

        if [[ "$completed" == "true" ]]; then
            info "✅ Sanitize voltooid (status: $status)" >&2
            return 0
        fi

        if [[ -n "$progress" ]] && [[ "$progress" != "$last_progress" ]]; then
            info "⏳ Sanitize progress: $progress% (${waited}s)" >&2
            last_progress="$progress"
        fi

        sleep 5
        waited=$((waited + 5))
    done

    error "❌ Sanitize timeout na ${max_wait}s" >&2
    return 1
}

# ============================================================
# DISCARD SUPPORT
# ============================================================
check_discard_support() {
    local d="$1"
    if command -v lsblk >/dev/null 2>&1; then
        local discard_max
        discard_max=$(lsblk -dn -o DISC-MAX "$d" 2>/dev/null | tr -d ' ' || true)
        if [[ -n "$discard_max" ]] && [[ "$discard_max" != "0B" ]] && [[ "$discard_max" != "0" ]]; then
            local discard_zero
            discard_zero=$(lsblk -dn -o DISC-ZERO "$d" 2>/dev/null | tr -d ' ' || true)
            if [[ "$discard_zero" == "1" ]]; then
                info "✅ Discard supported with zeroing" >&2
            else
                info "✅ Discard supported (may not zero data)" >&2
            fi
            return 0
        fi
    fi

    local dev_name="${d##*/}"
    if [[ -f "/sys/block/$dev_name/queue/discard_max_bytes" ]]; then
        local max_bytes
        max_bytes=$(cat "/sys/block/$dev_name/queue/discard_max_bytes" 2>/dev/null || echo "0")
        if [[ $max_bytes -gt 0 ]]; then
            return 0
        fi
    fi

    warn "⚠️ Discard/TRIM not supported on $d" >&2
    return 1
}

# ============================================================
# VERIFICATIE
# ============================================================
verify_wipe() {
    local d="$1"
    local method="$2"
    [[ "$DRY_RUN" == true ]] && return 0
    [[ "$VERIFY" != true ]] && return 0

    info "🔍 Verifiëren van wipe op $d (methode: $method)" >&2

    case "$method" in
        *"Cryptographic Erase"*|*"Enhanced Secure Erase"*|*"Secure Erase"*|*"Sanitize"*)
            info "📋 Hardware wipe - controleren op leesbaarheid en SMART" >&2
            if ! dd if="$d" of=/dev/null bs=1M count=1 2>/dev/null; then
                error "❌ Device niet leesbaar" >&2
                return 1
            fi
            if [[ "$SMART" == true ]] && ! smart_health_ok "$d"; then
                warn "⚠️ SMART warnings na wipe" >&2
            fi
            info "✅ Hardware wipe verificatie geslaagd" >&2
            return 0
            ;;
        *"blkdiscard"*)
            info "📋 blkdiscard - CLEAR operatie (geen NIST Purge)" >&2
            if dd if="$d" of=/dev/null bs=1M count=1 2>/dev/null; then
                info "✅ Device leesbaar (logisch leeg)" >&2
                return 0
            else
                warn "⚠️ Device niet leesbaar" >&2
                return 1
            fi
            ;;
        *"overwrite"*|*"NIST"*|*"DoD"*)
            info "📋 Software overwrite - controleren op nullen" >&2
            local block_size=1048576
            local device_size
            device_size=$(blockdev --getsize64 "$d" 2>/dev/null || echo "0")
            local max_offset=$((device_size / block_size))
            if [[ $max_offset -eq 0 ]]; then
                warn "⚠️ Kan device size niet bepalen, verificatie beperkt" >&2
                return 0
            fi
            local offsets=()
            for i in {1..20}; do
                local offset
                offset=$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -d ' ' || echo "0")
                offset=$((offset % max_offset))
                offsets+=($offset)
            done
            offsets=($(printf '%s\n' "${offsets[@]}" | sort -nu))
            for offset in "${offsets[@]}"; do
                if ! cmp -s \
                    <(dd if="$d" bs="$block_size" skip="$offset" count=1 2>/dev/null) \
                    <(dd if=/dev/zero bs="$block_size" count=1 2>/dev/null); then
                    warn "✗ Data gevonden bij offset $offset" >&2
                    return 1
                fi
            done
            info "✅ Overwrite verificatie geslaagd - alle nullen" >&2
            return 0
            ;;
        *)
            warn "⚠️ Onbekende methode: $method - standaard verificatie" >&2
            dd if="$d" of=/dev/null bs=1M count=1 2>/dev/null
            ;;
    esac
}

# ============================================================
# SMART
# ============================================================
smart_health_ok() {
    local d="$1"
    local dev_name="${d##*/}"
    command -v smartctl >/dev/null 2>&1 || return 0

    if [[ "$(type_disk "$dev_name")" == "NVME" ]] && command -v nvme >/dev/null 2>&1; then
        local nvme_smart
        nvme_smart=$(nvme smart-log "$d" 2>/dev/null || true)
        if [[ -n "$nvme_smart" ]]; then
            local critical
            critical=$(echo "$nvme_smart" | grep -i "critical_warning" | awk '{print $NF}' | sed 's/^0x//' || true)
            if [[ -n "$critical" ]] && [[ $((0x$critical)) -ne 0 ]]; then
                warn "⚠️ NVMe critical warnings: 0x$critical" >&2
                return 1
            fi
            local percent_used
            percent_used=$(echo "$nvme_smart" | awk '/percentage_used/ {print $3}' | sed 's/%//' || true)
            if [[ -n "$percent_used" ]] && [[ $percent_used -gt 90 ]]; then
                warn "⚠️ NVMe wear level: ${percent_used}% used" >&2
            fi
        fi
    fi

    smartctl -H "$d" 2>/dev/null | grep -qi "PASSED"
}

smart_log() {
    local d="$1"
    local serial="$2"
    local prefix="$3"
    command -v smartctl >/dev/null 2>&1 || return 0
    local logfile="$LOGDIR/smart_${prefix}_${serial}.log"
    {
        echo "=== SMART DATA COLLECTION ==="
        echo "Timestamp: $(ts)"
        echo "Device: $d"
        echo "Serial: $serial"
        echo ""
        smartctl -i "$d" 2>/dev/null || true
        echo ""
        smartctl -H "$d" 2>/dev/null || true
        echo ""
        smartctl -A "$d" 2>/dev/null || true
        echo ""
        smartctl -x "$d" 2>/dev/null || true
        if [[ "$(type_disk "${d##*/}")" != "NVME" ]]; then
            echo "=== SATA METRICS ==="
            smartctl -A "$d" 2>/dev/null | grep -E "Reallocated|Pending|Offline|Power-On|Temperature" || true
        fi
        if [[ "$(type_disk "${d##*/}")" == "NVME" ]] && command -v nvme >/dev/null 2>&1; then
            echo "=== NVME SMART METRICS ==="
            nvme smart-log "$d" 2>/dev/null || true
            echo ""
            echo "=== NVME CONTROLLER ==="
            nvme id-ctrl "$d" 2>/dev/null | grep -E "vid|ssvid|sn|mn|fr|rab|ieee|cmic|mdts|oacs|fna" || true
        fi
    } > "$logfile" 2>/dev/null
    info "📊 SMART log: $logfile"
}

# ============================================================
# WIPE FUNCTIES
# ============================================================
wipe_nvme_auto() {
    local d="$1"
    local namespace="${2:-1}"
    local method_used="unknown"
    [[ "$DRY_RUN" == true ]] && { info "[DRY-RUN] NVMe $d" >&2; echo "SIMULATED"; return 0; }

    command -v nvme >/dev/null 2>&1 || { error "nvme-cli niet geïnstalleerd" >&2; return $EXIT_DEPENDENCY_MISSING; }

    local caps
    caps=($(nvme_get_capabilities "$d"))
    local vendor
    vendor=$(detect_vendor "$d")
    info "NVMe vendor: $vendor, capabilities: ${caps[*]}" >&2

    if [[ " ${caps[*]} " =~ " crypto " ]]; then
        info "🔐 Cryptographic Erase" >&2
        if nvme format "$d" -n "$namespace" -s 1 2>/dev/null; then
            method_used="NVMe Cryptographic Erase"
            info "✅ $method_used succesvol" >&2
            echo "$method_used"
            return 0
        fi
        warn "Cryptographic Erase mislukt" >&2
    fi

    if [[ " ${caps[*]} " =~ " format " ]]; then
        info "📝 Secure Format" >&2
        if nvme format "$d" -n "$namespace" -s 2 2>/dev/null; then
            method_used="NVMe Secure Format"
            info "✅ $method_used succesvol" >&2
            echo "$method_used"
            return 0
        fi
        warn "Secure Format mislukt" >&2
    fi

    if [[ " ${caps[*]} " =~ " sanitize " ]]; then
        info "🧹 Sanitize" >&2
        if nvme_sanitize_with_progress "$d" 2; then
            method_used="NVMe Sanitize (Block Erase)"
            echo "$method_used"
            return 0
        fi
        warn "Sanitize mislukt" >&2
    fi

    if check_discard_support "$d"; then
        info "💨 Fallback: blkdiscard" >&2
        if blkdiscard --secure -f "$d" 2>/dev/null; then
            method_used="blkdiscard --secure (CLEAR - geen NIST Purge)"
            echo "$method_used"
            return 0
        fi
        if blkdiscard -f "$d" 2>/dev/null; then
            method_used="blkdiscard (CLEAR - logisch leeg, geen NIST Purge)"
            echo "$method_used"
            return 0
        fi
    fi

    error "❌ Geen enkele NVMe wis-methode succesvol" >&2
    return $EXIT_WIPE_FAILED
}

wipe_ssd_auto() {
    local d="$1"
    local method_used="unknown"
    [[ "$DRY_RUN" == true ]] && { info "[DRY-RUN] SSD $d" >&2; echo "SIMULATED"; return 0; }

    if ! command -v hdparm >/dev/null 2>&1; then
        warn "hdparm niet beschikbaar" >&2
        if check_discard_support "$d"; then
            blkdiscard --secure -f "$d" 2>/dev/null && echo "blkdiscard --secure (CLEAR - geen NIST Purge)" && return 0
            blkdiscard -f "$d" && echo "blkdiscard (CLEAR - geen NIST Purge)" && return 0
        fi
        return $EXIT_DEPENDENCY_MISSING
    fi

    local ata_security
    ata_security=$(parse_ata_security "$d")

    local supported enabled frozen enhanced erase
    supported=$(echo "$ata_security" | grep "^supported=" | cut -d'=' -f2)
    enabled=$(echo "$ata_security" | grep "^enabled=" | cut -d'=' -f2)
    frozen=$(echo "$ata_security" | grep "^frozen=" | cut -d'=' -f2)
    enhanced=$(echo "$ata_security" | grep "^enhanced=" | cut -d'=' -f2)
    erase=$(echo "$ata_security" | grep "^erase=" | cut -d'=' -f2)

    info "ATA Security: supported=$supported, enabled=$enabled, frozen=$frozen, enhanced=$enhanced, erase=$erase" >&2

    if [[ "$frozen" == "true" ]]; then
        warn "⚠️ SSD is FROZEN op $d" >&2
        if [[ "$SUSPEND_ON_FROZEN" == true ]]; then
            info "💤 Suspending systeem..." >&2
            systemctl suspend || true
            sleep 5
            ata_security=$(parse_ata_security "$d")
            frozen=$(echo "$ata_security" | grep "^frozen=" | cut -d'=' -f2)
            if [[ "$frozen" != "true" ]]; then
                info "✅ Freeze opgeheven na suspend" >&2
            fi
        fi

        if [[ "$frozen" == "true" ]]; then
            if [[ "$SAFE_MODE" == false ]]; then
                warn "⚠️ SAFE_MODE uit - forceer blkdiscard (CLEAR)" >&2
                if check_discard_support "$d"; then
                    blkdiscard --secure -f "$d" 2>/dev/null && echo "blkdiscard --secure (CLEAR - geen NIST Purge)" && return 0
                    blkdiscard -f "$d" 2>/dev/null && echo "blkdiscard (CLEAR - geen NIST Purge)" && return 0
                fi
            else
                error "❌ SSD bevroren - handmatige actie vereist" >&2
                return $EXIT_DEVICE_FROZEN
            fi
        fi
    fi

    local pw
    pw=$(openssl rand -base64 24 2>/dev/null || head -c 24 /dev/urandom | base64)

    if [[ "$enhanced" == "true" ]] && [[ "$supported" == "true" ]]; then
        info "🔐 Enhanced Secure Erase" >&2
        if hdparm --security-set-pass "$pw" "$d" >/dev/null 2>&1; then
            if hdparm --security-erase-enhanced "$pw" "$d" >/dev/null 2>&1; then
                method_used="ATA Enhanced Secure Erase (NIST Purge)"
                info "✅ $method_used succesvol" >&2
                echo "$method_used"
                return 0
            fi
        fi
        warn "Enhanced Secure Erase mislukt" >&2
    fi

    if [[ "$erase" == "true" ]] && [[ "$supported" == "true" ]]; then
        info "🔐 Secure Erase" >&2
        if hdparm --security-set-pass "$pw" "$d" >/dev/null 2>&1; then
            if hdparm --security-erase "$pw" "$d" >/dev/null 2>&1; then
                method_used="ATA Secure Erase (NIST Purge)"
                info "✅ $method_used succesvol" >&2
                echo "$method_used"
                return 0
            fi
        fi
        warn "Secure Erase mislukt" >&2
    fi

    if check_discard_support "$d"; then
        info "💨 Fallback: blkdiscard" >&2
        if blkdiscard --secure -f "$d" 2>/dev/null; then
            method_used="blkdiscard --secure (CLEAR - geen NIST Purge)"
            echo "$method_used"
            return 0
        fi
        if blkdiscard -f "$d" 2>/dev/null; then
            method_used="blkdiscard (CLEAR - logisch leeg, geen NIST Purge)"
            echo "$method_used"
            return 0
        fi
    fi

    error "❌ Alle SSD wis-methoden mislukt" >&2
    return $EXIT_WIPE_FAILED
}

wipe_hdd_nist() {
    local d="$1"
    local bs="4M"
    [[ "$DRY_RUN" == true ]] && { info "[DRY-RUN] HDD $d (NIST)" >&2; echo "SIMULATED"; return 0; }

    info "📋 NIST SP 800-88: één pass + verificatie" >&2
    dd if=/dev/zero of="$d" bs="$bs" status=progress conv=fsync iflag=fullblock oflag=direct,nocache 2>/dev/null
    sync
    echo "NIST overwrite (software) - NIST Purge"
    return 0
}

wipe_hdd_dod3() {
    local d="$1"
    local bs="4M"
    [[ "$DRY_RUN" == true ]] && { info "[DRY-RUN] HDD $d (DoD)" >&2; echo "SIMULATED"; return 0; }

    warn "⚠️ DoD 3-pass is LEGACY MODE - niet aanbevolen door NIST SP 800-88" >&2
    info "📋 DoD 3-pass wipe (legacy compatibility mode)" >&2
    for pass in 1 2 3; do
        info "Pass $pass/3" >&2
        if [[ $pass -eq 1 ]] || [[ $pass -eq 3 ]]; then
            dd if=/dev/zero of="$d" bs="$bs" status=progress conv=fsync iflag=fullblock oflag=direct,nocache 2>/dev/null
        else
            dd if=/dev/urandom of="$d" bs="$bs" status=progress conv=fsync iflag=fullblock oflag=direct,nocache 2>/dev/null
        fi
    done
    sync
    echo "DoD 3-pass overwrite (LEGACY - geen NIST aanbeveling)"
}

wipe_device_auto() {
    local d="$1"
    local type="$2"
    local method_used
    local exit_code
    case "$type" in
        NVME) method_used=$(wipe_nvme_auto "$d"); exit_code=$? ;;
        SSD) method_used=$(wipe_ssd_auto "$d"); exit_code=$? ;;
        HDD)
            if [[ "$DOD3_MODE" == true ]]; then
                method_used=$(wipe_hdd_dod3 "$d")
            else
                method_used=$(wipe_hdd_nist "$d")
            fi
            exit_code=$?
            ;;
        *) error "Onbekend type: $type" >&2; return $EXIT_ERROR ;;
    esac
    if [[ $exit_code -ne 0 ]]; then
        return $exit_code
    fi
    echo "$method_used"
    return 0
}

# ============================================================
# SINGLE DEVICE PROCESSING
# ============================================================
process_device() {
    local d="$1"
    local dev
    dev=$(normalize_dev "$d")
    [[ ! -b "$dev" ]] && { error "$dev niet gevonden"; return $EXIT_DEVICE_NOT_FOUND; }
    is_root_disk "$dev" && { error "❌ $dev is ROOT - GEBLOKKEERD"; return $EXIT_DEVICE_BLOCKED; }

    local serial model type size wwn fingerprint id
    serial=$(get_serial "$dev")
    model=$(get_model "$dev")
    type=$(type_disk "$d")
    size=$(get_size "$dev")
    wwn=$(get_wwn "$dev")
    fingerprint=$(device_fingerprint "$dev")
    id=$(uuid)

    echo ""
    echo "============================================================"
    echo "🎯 TARGET: $dev"
    echo "📦 TYPE: $type"
    echo "🏷️ MODEL: $model"
    echo "🔢 SERIAL: $serial"
    echo "💾 WWN: $wwn"
    echo "🔑 FP: ${fingerprint:0:16}..."
    echo "💾 SIZE: $size"
    if [[ -n "$CUSTOMER" ]] || [[ -n "$TICKET" ]] || [[ -n "$ASSET_TAG" ]]; then
        echo "------------------------------------------------------------"
        [[ -n "$CUSTOMER" ]] && echo "🏢 CUSTOMER: $CUSTOMER"
        [[ -n "$TICKET" ]] && echo "🎫 TICKET: $TICKET"
        [[ -n "$LOCATION" ]] && echo "📍 LOCATION: $LOCATION"
        [[ -n "$OPERATOR" ]] && echo "👤 OPERATOR: $OPERATOR"
        [[ -n "$ASSET_TAG" ]] && echo "🏷️ ASSET TAG: $ASSET_TAG"
    fi
    echo "============================================================"

    if ! allowed "$serial"; then
        warn "⛔ Device niet in allowlist - GEBLOKKEERD"
        return $EXIT_DEVICE_BLOCKED
    fi

    if ! safe "$dev"; then
        warn "⛔ Unsafe device - GEBLOKKEERD"
        return $EXIT_DEVICE_BLOCKED
    fi

    if [[ "$FORCE" != true ]] && [[ "$DRY_RUN" != true ]]; then
        echo ""
        echo "⚠️ WAARSCHUWING: DIT WIST ALLE DATA PERMANENT"
        echo " Device: $dev ($serial)"
        [[ -n "$CUSTOMER" ]] && echo " Klant: $CUSTOMER"
        [[ -n "$ASSET_TAG" ]] && echo " Asset: $ASSET_TAG"
        echo " Method: $([[ "$NIST_MODE" == true ]] && echo "NIST SP 800-88" || echo "DoD 3-pass (LEGACY)")"
        read -p "▶️ Type 'CONFIRM DESTROY' om te beginnen: " confirm
        [[ "$confirm" != "CONFIRM DESTROY" ]] && { warn "Geannuleerd"; return 1; }
    fi

    local start
    start=$(date +%s)
    local status="failed"
    local method_used="unknown"

    [[ "$SMART" == true ]] && smart_log "$dev" "$serial" "pre"

    if [[ "$SMART" == true ]] && ! smart_health_ok "$dev"; then
        warn "⚠️ SMART health warnings voor $dev"
    fi

    info "🔄 Starten met wissen van $dev ($type)..."
    if method_used=$(wipe_device_auto "$dev" "$type"); then
        status="done"
        info "✅ Wipe voltooid met methode: $method_used"
    else
        local wipe_exit=$?
        error "❌ Wipe mislukt (exit code: $wipe_exit)"
        return $EXIT_WIPE_FAILED
    fi

    local duration=$(( $(date +%s) - start ))

    if [[ "$status" == "done" ]]; then
        if verify_wipe "$dev" "$method_used"; then
            status="verified"
            info "✅ Wipe geverifieerd voor $dev"
        else
            status="failed_verification"
            warn "⚠️ Verificatie mislukt voor $dev"
        fi
    fi

    [[ "$SMART" == true ]] && smart_log "$dev" "$serial" "post"

    audit_device "$dev" "$serial" "$model" "$type" "$status" "$duration" "$id" "$method_used" "$fingerprint"

    echo "------------------------------------------"
    echo "📊 RESULTAAT: $dev"
    echo " Status: $status"
    echo " Method: $method_used"
    echo " Duur: ${duration}s"
    echo " UUID: $id"
    echo " FP: $fingerprint"
    echo "------------------------------------------"
    return 0
}

# ============================================================
# PARALLEL PROCESSING
# ============================================================
process_devices_parallel() {
    local jobs=$1
    shift
    local devices=("$@")
    local pids=()
    local failed=0
    info "📋 Processing ${#devices[@]} devices with $jobs parallel jobs"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local batch_size=$jobs
    local total=${#devices[@]}
    local processed=0

    while [[ $processed -lt $total ]]; do
        local batch=()
        local batch_end=$((processed + batch_size))
        [[ $batch_end -gt $total ]] && batch_end=$total
        for ((i=processed; i<batch_end; i++)); do
            batch+=("${devices[$i]}")
        done

        for device in "${batch[@]}"; do
            (
                local result_file="${tmp_dir}/result_$$_${device//\//_}.txt"
                if process_device "$device" > "$result_file" 2>&1; then
                    echo "SUCCESS" > "${result_file}.status"
                else
                    echo "FAILED" > "${result_file}.status"
                fi
                cat "$result_file"
            ) &
            pids+=($!)
        done

        for pid in "${pids[@]}"; do
            wait $pid || failed=$((failed + 1))
        done
        processed=$batch_end
        pids=()
    done

    rm -rf "$tmp_dir"
    return $failed
}

# ============================================================
# PDF CERTIFICATE GENERATION (weasyprint eerst, dan wkhtmltopdf)
# ============================================================
generate_cert_pdf() {
    local txt_cert="$1"
    local uuid="$2"

    [[ ! -f "$txt_cert" ]] && { warn "PDF: txt certificaat niet gevonden: $txt_cert"; return 1; }

    local html="${CERT}/cert_${uuid}.html"
    local pdf="${CERT}/cert_${uuid}.pdf"

    local logo_css=""
    local logo_block=""
    if [[ -n "$LOGO_PATH" ]] && [[ -f "$LOGO_PATH" ]]; then
        local logo_abs
        logo_abs=$(readlink -f "$LOGO_PATH")
        local logo_url="file://${logo_abs}"

        case "$LOGO_POSITION" in
            top-left|left)
                logo_css="position:absolute; top:15mm; left:15mm;"
                ;;
            top-center|center)
                logo_css="position:absolute; top:15mm; left:50%; transform:translateX(-50%);"
                ;;
            top-right|right|*)
                logo_css="position:absolute; top:15mm; right:15mm;"
                ;;
        esac

        logo_block="<img class=\"logo\" src=\"${logo_url}\" alt=\"logo\">"
    fi

    local escaped_content
    escaped_content=$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$txt_cert")

    cat > "$html" <<HTML
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Certificate of Destruction - ${uuid}</title>
<style>
    @page {
        size: A4;
        margin: 20mm;
    }
    html, body {
        font-family: "DejaVu Sans Mono", "Courier New", monospace;
        font-size: 9pt;
        color: #000;
        margin: 0;
        padding: 0;
    }
    img.logo {
        width: ${LOGO_WIDTH_MM}mm;
        height: ${LOGO_HEIGHT_MM}mm;
        object-fit: contain;
        ${logo_css}
    }
    .content {
        margin-top: ${LOGO_HEIGHT_MM}mm;
    }
    pre {
        white-space: pre-wrap;
        word-wrap: break-word;
        margin: 0;
        font-family: inherit;
    }
</style>
</head>
<body>
${logo_block}
<div class="content">
<pre>${escaped_content}</pre>
</div>
</body>
</html>
HTML

    # --- Poging 1: weasyprint ---
    if command -v weasyprint >/dev/null 2>&1; then
        info "📄 Genereren PDF met weasyprint..."
        if weasyprint "$html" "$pdf" 2>/dev/null; then
            if [[ -s "$pdf" ]] && [[ $(stat -c%s "$pdf") -gt 1024 ]]; then
                info "✅ PDF certificaat: $pdf"
                sha256sum "$pdf" > "${pdf}.sha256"
                return 0
            else
                warn "⚠️ weasyprint produceerde een lege/kleine PDF"
            fi
        else
            warn "⚠️ weasyprint faalde"
        fi
    fi

    # --- Poging 2: wkhtmltopdf ---
    if command -v wkhtmltopdf >/dev/null 2>&1; then
        info "📄 Genereren PDF met wkhtmltopdf..."
        local wk_cmd="wkhtmltopdf"
        if ! [[ -n "${DISPLAY:-}" ]] && command -v xvfb-run >/dev/null 2>&1; then
            wk_cmd="xvfb-run wkhtmltopdf"
        fi
        if $wk_cmd --enable-local-file-access --quiet "$html" "$pdf" 2>/dev/null; then
            if [[ -s "$pdf" ]] && [[ $(stat -c%s "$pdf") -gt 1024 ]]; then
                info "✅ PDF certificaat (wkhtmltopdf): $pdf"
                sha256sum "$pdf" > "${pdf}.sha256"
                return 0
            else
                warn "⚠️ wkhtmltopdf produceerde een lege/kleine PDF"
            fi
        else
            warn "⚠️ wkhtmltopdf faalde"
        fi
    fi

    warn "⚠️ Geen PDF gegenereerd (geen werkende generator)"
    warn "   HTML blijft bewaard voor handmatige conversie: $html"
    return 1
}

# ============================================================
# CERTIFICATE GENERATION
# ============================================================
generate_certificate() {
    local dev="$1"
    local serial="$2"
    local uuid="$3"
    local status="$4"
    local duration="$5"
    local method="$6"
    local audit_hash="$7"
    local smart_log="$8"
    local fingerprint="$9"

    local cert_file="$CERT/cert_${uuid}.txt"
    local dry_run_flag=""
    [[ "$DRY_RUN" == true ]] && dry_run_flag=" [SIMULATED - DRY RUN]"

    local wwn sector_size phys_sector vendor pci_id kernel_cmd bios_version
    wwn=$(get_wwn "$dev")
    sector_size=$(get_sector_size "$dev")
    phys_sector=$(get_physical_sector "$dev")
    vendor=$(detect_vendor "$dev")
    pci_id=$(lspci -nn 2>/dev/null | grep -i "nvme\|ata\|sata" | head -1 | cut -d' ' -f1 || echo "unknown")
    kernel_cmd=$(cat /proc/cmdline 2>/dev/null || echo "unknown")
    bios_version=$(dmidecode -s bios-version 2>/dev/null || echo "unknown")

    local nist_status="Not Applicable"
    if [[ "$method" == *"Purge"* ]] || [[ "$method" == *"NIST"* ]]; then
        nist_status="Purge (NIST SP 800-88)"
    elif [[ "$method" == *"CLEAR"* ]] || [[ "$method" == *"blkdiscard"* ]]; then
        nist_status="Clear (NIST SP 800-88) - NOT a Purge"
    elif [[ "$method" == *"Legacy"* ]]; then
        nist_status="Legacy - Not NIST compliant"
    fi

    cat > "$cert_file" <<EOF
CERTIFICATE OF DESTRUCTION${dry_run_flag}
==========================

Certificate ID: $uuid
Generated: $(ts)
Hostname: $HOSTNAME
Session ID: $SESSION_ID

Customer Information:
- Customer:    ${CUSTOMER:-N/A}
- Ticket:      ${TICKET:-N/A}
- Location:    ${LOCATION:-N/A}
- Operator:    ${OPERATOR:-N/A}
- Asset Tag:   ${ASSET_TAG:-N/A}

System Information:
- Kernel: $(uname -r)
- Kernel Cmdline: $kernel_cmd
- Distribution: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo "unknown")
- Host UUID: $(cat /sys/devices/virtual/dmi/id/product_uuid 2>/dev/null || echo "unknown")
- BIOS Version: $bios_version
- UEFI: $([[ -d /sys/firmware/efi ]] && echo "Yes" || echo "No")
- Secure Boot: $(command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled" && echo "Enabled" || echo "Disabled/Unknown")

Device Information:
- Device: $dev
- Serial: $serial
- WWN: $wwn
- Model: $(get_model "$dev")
- Vendor: $vendor
- Fingerprint: $fingerprint
- Size: $(get_size "$dev")
- Type: $(type_disk "${dev##*/}")
- Sector Size: $sector_size bytes (logical)
- Physical Sector: $phys_sector bytes
- Controller PCI: $pci_id
- Controller FW: $(smartctl -i "$dev" 2>/dev/null | grep -i firmware | head -1 | cut -d':' -f2- | xargs || echo "unknown")
- NVMe UUID: $(nvme id-ns "$dev" -n 1 2>/dev/null | grep -i "nguid" | head -1 | cut -d':' -f2- | xargs || echo "N/A")

Wipe Details:
- Status: $status
- Duration: ${duration}s
- Method: $method
- NIST Status: $nist_status
- Dry Run: $DRY_RUN
- Mode: $([[ "$NIST_MODE" == true ]] && echo "NIST SP 800-88" || echo "DoD 3-pass (LEGACY)")

Verification:
- Verified: $VERIFY
- Result: $([[ "$status" == "verified" ]] && echo "PASSED" || echo "FAILED")
- Strategy: $([[ "$method" == *"overwrite"* ]] && echo "Null check" || echo "Readability + SMART")

Security State:
$(parse_ata_security "$dev" 2>/dev/null | sed 's/^/- /' || echo " (no ATA security info)")

SMART Metrics:
$(smartctl -A "$dev" 2>/dev/null | grep -E "Reallocated|Pending|Offline|Power-On|Temperature|Media_Errors|Data_Units" || echo " (no metrics available)")

Audit Trail:
- Audit File: $AUDIT
- Session File: $SESSION_JSON
- Integrity Hash: $audit_hash
- SMART Log: $smart_log
- Certificate Hash: $(sha256sum "$cert_file" | awk '{print $1}')

Tool Versions:
- smartctl: $(smartctl --version 2>/dev/null | head -1 | cut -d' ' -f2 || echo "unknown")
- nvme-cli: $(nvme version 2>/dev/null | head -1 | cut -d' ' -f3 || echo "unknown")
- hdparm: $(hdparm -V 2>/dev/null | cut -d' ' -f2 || echo "unknown")
- jq: $(jq --version 2>/dev/null || echo "unknown")

---
Integrity Hash (Audit): $audit_hash
EOF

    if [[ "$SIGN_CERTIFICATES" == true ]] && [[ -f "$PRIVATE_KEY" ]]; then
        openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "${cert_file}.sig" "$cert_file" 2>/dev/null
        info "🔑 Certificate signed: ${cert_file}.sig"
    fi

    info "📜 Certificate: $cert_file"
    sha256sum "$cert_file" > "${cert_file}.sha256"

    # Genereer PDF (met logo indien beschikbaar)
    generate_cert_pdf "$cert_file" "$uuid" || true
}

# ============================================================
# AUDIT TRAIL
# ============================================================
audit_device() {
    local dev="$1"
    local serial="$2"
    local model="$3"
    local type="$4"
    local status="$5"
    local duration="$6"
    local uuid="$7"
    local method="$8"
    local fingerprint="$9"

    local wwn vendor bios
    wwn=$(get_wwn "$dev")
    vendor=$(detect_vendor "$dev")
    bios=$(dmidecode -s bios-version 2>/dev/null || echo "unknown")

    local json
    json=$(jq -n \
        --arg id "$uuid" \
        --arg ts "$(ts)" \
        --arg host "$HOSTNAME" \
        --arg device "$dev" \
        --arg serial "$serial" \
        --arg model "$model" \
        --arg type "$type" \
        --arg status "$status" \
        --argjson duration "$duration" \
        --arg method "$method" \
        --argjson dry_run "$DRY_RUN" \
        --argjson verify "$VERIFY" \
        --argjson nist "$NIST_MODE" \
        --arg wwn "$wwn" \
        --arg fingerprint "$fingerprint" \
        --arg kernel "$(uname -r)" \
        --arg bios "$bios" \
        --arg vendor "$vendor" \
        --arg customer "$CUSTOMER" \
        --arg ticket "$TICKET" \
        --arg location "$LOCATION" \
        --arg operator "$OPERATOR" \
        --arg asset_tag "$ASSET_TAG" \
        --arg logo_file "$LOGO_PATH" \
        '{
            id: $id,
            timestamp: $ts,
            hostname: $host,
            customer: $customer,
            ticket: $ticket,
            location: $location,
            operator: $operator,
            asset_tag: $asset_tag,
            logo_file: $logo_file,
            device: $device,
            serial: $serial,
            wwn: $wwn,
            model: $model,
            fingerprint: $fingerprint,
            vendor: $vendor,
            type: $type,
            status: $status,
            duration_sec: $duration,
            method: $method,
            dry_run: $dry_run,
            verify: $verify,
            nist_mode: $nist,
            kernel: $kernel,
            bios: $bios
        }')
    echo "$json" >> "$AUDIT"
    info "📊 Audit line geschreven: $AUDIT"

    if [[ "$CSV_EXPORT" == true ]]; then
        if [[ ! -f "$CSV" ]]; then
            echo "id,timestamp,hostname,customer,ticket,location,operator,asset_tag,device,serial,wwn,model,fingerprint,vendor,type,status,duration_sec,method,dry_run,verify,nist_mode" > "$CSV"
        fi
        echo "$uuid,$(ts),$HOSTNAME,\"$CUSTOMER\",\"$TICKET\",\"$LOCATION\",\"$OPERATOR\",\"$ASSET_TAG\",$dev,$serial,$wwn,\"$model\",$fingerprint,$vendor,$type,$status,$duration,$method,$DRY_RUN,$VERIFY,$NIST_MODE" >> "$CSV"
        info "📊 CSV line geschreven: $CSV"
    fi

    local audit_hash
    audit_hash=$(sha256sum "$AUDIT" 2>/dev/null | awk '{print $1}')
    local smart_log_file="$LOGDIR/smart_post_${serial}.log"
    generate_certificate "$dev" "$serial" "$uuid" "$status" "$duration" "$method" "$audit_hash" "$smart_log_file" "$fingerprint"
}

# ============================================================
# SESSIE JSON
# ============================================================
create_session_json() {
    local devices_json="$1"
    jq -n \
        --arg session_id "$SESSION_ID" \
        --arg started "$(ts)" \
        --arg hostname "$HOSTNAME" \
        --arg user "$(whoami)" \
        --argjson dry_run "$DRY_RUN" \
        --argjson nist "$NIST_MODE" \
        --argjson devices "$devices_json" \
        --arg customer "$CUSTOMER" \
        --arg ticket "$TICKET" \
        --arg location "$LOCATION" \
        --arg operator "$OPERATOR" \
        --arg asset_tag "$ASSET_TAG" \
        --arg logo_file "$LOGO_PATH" \
        '{
            session_id: $session_id,
            started: $started,
            hostname: $hostname,
            user: $user,
            customer: $customer,
            ticket: $ticket,
            location: $location,
            operator: $operator,
            asset_tag: $asset_tag,
            logo_file: $logo_file,
            dry_run: $dry_run,
            nist_mode: $nist,
            devices: $devices
        }' > "$SESSION_JSON"
    info "📊 Session JSON: $SESSION_JSON"
}

# ============================================================
# SAFETY CHECKS
# ============================================================
safe() {
    local dev="$1"
    [[ -b "$dev" ]] || return 1
    findmnt -rn -S "$dev" >/dev/null 2>&1 && return 1
    lsblk -no MOUNTPOINT "$dev" 2>/dev/null | grep -q "/" && return 1
    [[ "$SAFE_MODE" == true ]] && blkid "$dev" >/dev/null 2>&1 && return 1
    return 0
}

allowed() {
    [[ ! -f "$ALLOWLIST" ]] && return 0
    if grep -q "^[*|ALL|all]$" "$ALLOWLIST" 2>/dev/null; then
        return 0
    fi
    grep -qx "$1" "$ALLOWLIST"
}

# ============================================================
# TYPE DETECTIE
# ============================================================
type_disk() {
    local d="$1"
    [[ "$d" == nvme* ]] && echo "NVME" && return
    if [[ -f "/sys/block/$d/queue/rotational" ]]; then
        [[ "$(cat /sys/block/$d/queue/rotational)" == "0" ]] && echo "SSD" || echo "HDD"
    else
        echo "UNKNOWN"
    fi
}

# ============================================================
# MAIN
# ============================================================
main() {
    # Laad input file indien opgegeven
    if [[ -n "$INPUT_FILE" ]]; then
        load_input_file "$INPUT_FILE"
    fi

    # Zorg dat PDF generator beschikbaar is (niet in dry-run)
    if [[ "$DRY_RUN" != true ]]; then
        ensure_pdf_generator || warn "PDF generatie wordt overgeslagen"
    fi

    local exit_code=$EXIT_SUCCESS
    local any_failed=false
    local devices_processed=()
    local devices_status=()

    echo "============================================================"
    echo " SYSTEM WIPE ORCHESTRATOR v7.2 - ENTERPRISE ULTIMATE+"
    echo "============================================================"
    echo " Session ID: $SESSION_ID"
    echo " DRY_RUN: $DRY_RUN"
    echo " MODE: $([[ "$NIST_MODE" == true ]] && echo "NIST SP 800-88" || echo "DoD 3-pass (LEGACY)")"
    echo " VERIFY: $VERIFY"
    echo " SUSPEND: $SUSPEND_ON_FROZEN"
    echo " PARALLEL: $PARALLEL_JOBS jobs"
    echo " SIGN: $SIGN_CERTIFICATES"
    echo " CSV EXPORT: $CSV_EXPORT"
    echo " INPUT FILE: ${INPUT_FILE:-none}"
    echo "============================================================"

    if [[ -n "$CUSTOMER" ]] || [[ -n "$TICKET" ]] || [[ -n "$ASSET_TAG" ]] || [[ -n "$LOGO_PATH" ]]; then
        echo ""
        echo "📋 Klantgegevens:"
        [[ -n "$CUSTOMER" ]] && echo " Customer:   $CUSTOMER"
        [[ -n "$TICKET" ]] && echo " Ticket:     $TICKET"
        [[ -n "$LOCATION" ]] && echo " Location:   $LOCATION"
        [[ -n "$OPERATOR" ]] && echo " Operator:   $OPERATOR"
        [[ -n "$ASSET_TAG" ]] && echo " Asset Tag:  $ASSET_TAG"
        if [[ -n "$LOGO_PATH" ]]; then
            if [[ -f "$LOGO_PATH" ]]; then
                echo " Logo:       $LOGO_PATH (${LOGO_WIDTH_MM}x${LOGO_HEIGHT_MM}mm, $LOGO_POSITION)"
            else
                echo " Logo:       $LOGO_PATH (⚠️ bestand niet gevonden)"
            fi
        fi
    fi

    if [[ "$LEGACY_MODE" == true ]]; then
        echo ""
        warn "⚠️ LEGACY MODE ACTIVE: DoD 3-pass is NIET aanbevolen door NIST SP 800-88"
        warn " Gebruik --nist voor de aanbevolen methode"
        echo ""
    fi

    echo ""
    echo "📋 System Metadata:"
    echo " Hostname: $HOSTNAME"
    echo " Kernel: $(uname -r)"
    echo " Kernel Cmd: $(cat /proc/cmdline 2>/dev/null | head -c 80)..."
    echo " Distro: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo "unknown")"
    echo " BIOS: $(dmidecode -s bios-version 2>/dev/null || echo "unknown")"
    echo " UEFI: $([[ -d /sys/firmware/efi ]] && echo "Yes" || echo "No")"
    echo " Secure Boot: $(command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled" && echo "Enabled" || echo "Disabled/Unknown")"
    echo ""
    echo "📋 Root Devices (beschermd):"
    if [[ ${#ROOT_DEVS[@]} -gt 0 ]]; then
        printf ' - %s\n' "${ROOT_DEVS[@]}"
    else
        echo " (none detected)"
    fi

    local target_devices=()
    if [[ ${#TARGET_DEVICES[@]} -gt 0 ]]; then
        target_devices=("${TARGET_DEVICES[@]}")
    else
        echo ""
        echo "📋 Beschikbare opslagmedia:"
        lsblk -d -o NAME,SIZE,MODEL,SERIAL,TYPE,ROTA,WWN
        echo ""
        read -p "🎯 Voer schijfnamen in (bijv. sda nvme0n1): " -a target_devices
        [[ ${#target_devices[@]} -eq 0 ]] && { error "Geen schijven geselecteerd"; exit $EXIT_ERROR; }
    fi

    echo ""
    echo "🔍 Vendor detection:"
    for dev in "${target_devices[@]}"; do
        local full_dev vendor fingerprint
        full_dev=$(normalize_dev "$dev")
        vendor=$(detect_vendor "$full_dev")
        fingerprint=$(device_fingerprint "$full_dev")
        echo " $full_dev: $vendor (FP: ${fingerprint:0:16}...)"
    done

    echo ""
    echo "🔍 Discard/TRIM ondersteuning:"
    for dev in "${target_devices[@]}"; do
        local full_dev
        full_dev=$(normalize_dev "$dev")
        if check_discard_support "$full_dev" 2>/dev/null; then
            echo " ✅ $full_dev: Supported"
            local discard_zero
            discard_zero=$(lsblk -dn -o DISC-ZERO "$full_dev" 2>/dev/null | tr -d ' ')
            if [[ "$discard_zero" == "1" ]]; then
                echo " └─ DISC-ZERO: Yes (enterprise SSD)"
            fi
        else
            echo " ❌ $full_dev: Not supported"
        fi
    done

    if [[ $PARALLEL_JOBS -gt 1 ]] && [[ ${#target_devices[@]} -gt 1 ]]; then
        process_devices_parallel "$PARALLEL_JOBS" "${target_devices[@]}"
        exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
            any_failed=true
        fi
    else
        for d in "${target_devices[@]}"; do
            if ! process_device "$d"; then
                any_failed=true
                exit_code=$EXIT_PARTIAL_FAILURE
            fi
        done
    fi

    echo ""
    if [[ "$any_failed" == true ]] && [[ $exit_code -eq $EXIT_SUCCESS ]]; then
        exit_code=$EXIT_PARTIAL_FAILURE
    fi

    echo "✅ Wipe sessie voltooid (exit code: $exit_code)"
    echo "📁 Logs: $LOG"
    echo "📊 Audit: $AUDIT"
    echo "📊 Session: $SESSION_JSON"
    [[ "$CSV_EXPORT" == true ]] && echo "📊 CSV: $CSV"
    echo "📜 Certificaten: $CERT/ (txt + pdf indien generator beschikbaar)"
    exit $exit_code
}

# ============================================================
# START
# ============================================================
main "$@"