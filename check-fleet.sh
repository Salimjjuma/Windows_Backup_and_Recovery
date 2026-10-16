#!/usr/bin/env bash
# =====================================================================
# check-fleet.sh
# Linux (Ubuntu) equivalent of check-fleet.ps1: checks every laptop's
# restic repository on Wasabi S3 — snapshot count, latest snapshot time,
# and repo size. Auto-installs missing dependencies (restic, AWS CLI).
#
# Usage:
#   ./check-fleet.sh LAPTOP-1 LAPTOP-2
#   ./check-fleet.sh --hostnames LAPTOP-1,LAPTOP-2
#   ./check-fleet.sh                       # discover via AWS CLI
#   ./check-fleet.sh --endpoint URL --bucket NAME [...]
#   ./check-fleet.sh --csv fleet.csv LAPTOP-1
#
# Requires in the environment (same as the Windows IT tooling):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, RESTIC_PASSWORD_FILE
# Optional overrides: WASABI_ENDPOINT, BUCKET.
# =====================================================================

set -uo pipefail

ENDPOINT="${WASABI_ENDPOINT:-https://s3.eu-south-1.wasabisys.com}"
BUCKET="${BUCKET:-mewabackup}"
CSV_OUT=""
DISCOVER=false
HOSTNAMES=()

usage() {
    cat <<'EOF'
Usage: check-fleet.sh [OPTIONS] [HOSTNAME...]

  HOSTNAME...                Laptop repo prefixes to check (positional).
  --hostnames H1,H2          Same, comma- and/or space-separated.
  --discover                 List repo prefixes via AWS CLI (default when
                             no hostnames are given).
  --endpoint URL             Wasabi endpoint (default: env WASABI_ENDPOINT
                             or https://s3.eu-south-1.wasabisys.com).
  --bucket NAME              Bucket (default: env BUCKET or mewabackup).
  --csv PATH                 Also write results as CSV to PATH.
  -h, --help                 Show this help.

Environment: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
RESTIC_PASSWORD_FILE (same as the Windows IT tooling).
EOF
}

# ---- Args ----
while (($# > 0)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --hostnames)
            [[ $# -lt 2 ]] && { echo "ERROR: --hostnames needs a value." >&2; exit 2; }
            # Split on commas and whitespace.
            # shellcheck disable=SC2206
            HOSTNAMES+=(${2//,/ })
            shift 2 ;;
        --hostnames=*) HOSTNAMES+=(${1#--hostnames=}); shift ;;
        --discover) DISCOVER=true; shift ;;
        --endpoint)
            [[ $# -lt 2 ]] && { echo "ERROR: --endpoint needs a value." >&2; exit 2; }
            ENDPOINT="$2"; shift 2 ;;
        --endpoint=*) ENDPOINT="${1#--endpoint=}"; shift ;;
        --bucket)
            [[ $# -lt 2 ]] && { echo "ERROR: --bucket needs a value." >&2; exit 2; }
            BUCKET="$2"; shift 2 ;;
        --bucket=*) BUCKET="${1#--bucket=}"; shift ;;
        --csv)
            [[ $# -lt 2 ]] && { echo "ERROR: --csv needs a value." >&2; exit 2; }
            CSV_OUT="$2"; shift 2 ;;
        --csv=*) CSV_OUT="${1#--csv=}"; shift ;;
        --) shift; while (($# > 0)); do HOSTNAMES+=("$1"); shift; done ;;
        -*) echo "ERROR: unknown option: $1 (see --help)." >&2; exit 2 ;;
        *) HOSTNAMES+=("$1"); shift ;;
    esac
done

# Trim + drop blanks, dedupe (keep order).
_cleaned=()
for h in "${HOSTNAMES[@]:-}"; do
    h="${h#"${h%%[![:space:]]*}"}"
    h="${h%"${h##*[![:space:]]}"}"
    [[ -n "$h" ]] && _cleaned+=("$h")
done
HOSTNAMES=()
for h in "${_cleaned[@]:-}"; do
    skip=false
    for seen in "${HOSTNAMES[@]:-}"; do [[ "$seen" == "$h" ]] && skip=true; done
    $skip || HOSTNAMES+=("$h")
done
if ((${#HOSTNAMES[@]} == 0)); then DISCOVER=true; fi

# ---- Preflight ----
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD_FILE; do
    if [[ -z "${!v:-}" ]]; then
        echo "WARNING: $v is not set in this session - restic calls will likely fail." >&2
    fi
done
if [[ -n "${RESTIC_PASSWORD_FILE:-}" && ! -f "$RESTIC_PASSWORD_FILE" ]]; then
    echo "WARNING: RESTIC_PASSWORD_FILE points at a missing file: $RESTIC_PASSWORD_FILE" >&2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required (JSON parsing) but was not found." >&2
    exit 2
fi

apt_install_if_missing() {
    local missing=()
    for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
    if ((${#missing[@]} == 0)); then return 0; fi
    echo "Installing prerequisites: ${missing[*]} (sudo apt-get)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}"
}

ensure_restic() {
    if command -v restic >/dev/null 2>&1; then return 0; fi
    echo "restic not found - installing latest release..."
    local machine arch
    machine="$(uname -m)"
    case "$machine" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "ERROR: unsupported architecture for restic auto-install: $machine" >&2; exit 2 ;;
    esac
    apt_install_if_missing curl bzip2
    local tmp url
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    url="$(curl -fsSL https://api.github.com/repos/restic/restic/releases/latest \
        | python3 -c "import json,sys; rel=json.load(sys.stdin); ms=[a['browser_download_url'] for a in rel.get('assets',[]) if 'linux_${arch}.bz2' in a.get('name','')]; print(ms[0] if ms else '')")"
    if [[ -z "$url" ]]; then
        echo "ERROR: could not find a Linux ($arch) restic release asset." >&2
        exit 2
    fi
    echo "Downloading restic ($arch)..."
    curl -fsSL -o "$tmp/restic.bz2" "$url"
    bunzip2 -f "$tmp/restic.bz2"
    chmod +x "$tmp/restic"
    sudo mv -f "$tmp/restic" /usr/local/bin/restic
    command -v restic >/dev/null 2>&1 || { echo "ERROR: restic install failed." >&2; exit 2; }
    echo "restic installed: $(restic version)"
}

ensure_aws() {
    if command -v aws >/dev/null 2>&1; then return 0; fi
    echo "AWS CLI not found - installing v2 (needed for --discover)..."
    local machine arch
    machine="$(uname -m)"
    case "$machine" in
        x86_64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) echo "ERROR: unsupported architecture for AWS CLI auto-install: $machine" >&2; exit 2 ;;
    esac
    apt_install_if_missing curl unzip
    local tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    curl -fsSL -o "$tmp/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
    unzip -q -o "$tmp/awscliv2.zip" -d "$tmp"
    if [[ -d /usr/local/aws-cli ]]; then
        sudo "$tmp/aws/install" --update
    else
        sudo "$tmp/aws/install"
    fi
    command -v aws >/dev/null 2>&1 || { echo "ERROR: AWS CLI install failed." >&2; exit 2; }
    echo "AWS CLI installed: $(aws --version 2>&1)"
}

format_bytes() {
    python3 -c "
import sys
n = int(sys.argv[1])
for unit in ['B','KB','MB','GB','TB']:
    if n < 1024 or unit == 'TB':
        print(f'{n:.1f} {unit}' if unit != 'B' else f'{n} B')
        break
    n /= 1024.0
" "$1"
}

ensure_restic

# ---- Discover laptop prefixes if none were passed ----
if $DISCOVER; then
    ensure_aws
    echo "Discovering repositories in s3://$BUCKET via AWS CLI..." >&2
    prefixes_json="$(aws s3api list-objects-v2 --bucket "$BUCKET" --delimiter "/" \
        --endpoint-url "$ENDPOINT" --query "CommonPrefixes[].Prefix" --output json 2>&1)" || {
        echo "ERROR: bucket listing failed: $prefixes_json" >&2
        exit 1
    }
    mapfile -t HOSTNAMES < <(printf '%s' "$prefixes_json" | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin) or []
except Exception as e:
    print(f'ERROR: could not parse bucket listing as JSON: {e}', file=sys.stderr)
    sys.exit(1)
for p in data:
    p = (p or '').strip().rstrip('/')
    if p:
        print(p)
")
    if ((${#HOSTNAMES[@]} == 0)); then
        echo "ERROR: no repository prefixes found under s3://$BUCKET." >&2
        exit 1
    fi
    echo "Found ${#HOSTNAMES[@]} repositorie(s): $(IFS=,; echo "${HOSTNAMES[*]}")" >&2
fi

# ---- Check each repo ----
SAVED_REPO="${RESTIC_REPOSITORY:-}"
results=()   # name|status|snapshots|latest|size
fail_count=0
i=0
for host in "${HOSTNAMES[@]}"; do
    i=$((i + 1))
    echo "[$i/${#HOSTNAMES[@]}] $host..." >&2
    export RESTIC_REPOSITORY="s3:$ENDPOINT/$BUCKET/$host"

    snap_json="$(restic snapshots --json 2>&1)" || {
        results+=("$host|FAIL snapshots|0||")
        fail_count=$((fail_count + 1))
        echo "WARNING: $host: could not list snapshots." >&2
        continue
    }
    parsed="$(printf '%s' "$snap_json" | python3 -c "
import json,sys
try:
    snaps = json.load(sys.stdin) or []
except Exception:
    print('PARSE_ERROR')
    sys.exit(0)
print(len(snaps))
times = sorted(s.get('time','') for s in snaps if isinstance(s, dict) and s.get('time'))
print(times[-1] if times else '')
" 2>&1)" || parsed="PARSE_ERROR"
    if [[ "$parsed" == "PARSE_ERROR" ]]; then
        results+=("$host|FAIL parse|0||")
        fail_count=$((fail_count + 1))
        echo "WARNING: $host: snapshot output was not valid JSON." >&2
        continue
    fi
    snap_count="$(printf '%s' "$parsed" | sed -n '1p')"
    latest="$(printf '%s' "$parsed" | sed -n '2p')"

    size="unknown"
    stats_json="$(restic stats --mode raw-data --json 2>&1)" && {
        total="$(printf '%s' "$stats_json" | python3 -c "
import json,sys
try:
    print(json.load(sys.stdin).get('total_size',''))
except Exception:
    print('')
" 2>&1)"
        [[ "$total" =~ ^[0-9]+$ ]] && size="$(format_bytes "$total")"
    }

    if [[ "$snap_count" == "0" ]]; then
        results+=("$host|FAIL empty|0|$latest|$size")
        fail_count=$((fail_count + 1))
    else
        results+=("$host|OK|$snap_count|$latest|$size")
    fi
done

if [[ -n "$SAVED_REPO" ]]; then export RESTIC_REPOSITORY="$SAVED_REPO"; else unset RESTIC_REPOSITORY; fi

# ---- Report ----
printf '\n%-28s %-14s %9s  %-26s %10s\n' "Name" "Status" "Snapshots" "Latest" "Size"
printf '%s\n' "--------------------------------------------------------------------------------------------"
for row in "${results[@]:-}"; do
    IFS='|' read -r name status snaps latest size <<<"$row"
    printf '%-28s %-14s %9s  %-26s %10s\n' "$name" "$status" "$snaps" "$latest" "$size"
done
printf '\nChecked %d laptop(s): %d OK, %d FAIL.\n' \
    "${#HOSTNAMES[@]}" "$((${#HOSTNAMES[@]} - fail_count))" "$fail_count"

if [[ -n "$CSV_OUT" ]]; then
    {
        echo "name,status,snapshots,latest,size"
        for row in "${results[@]:-}"; do
            IFS='|' read -r name status snaps latest size <<<"$row"
            printf '"%s","%s",%s,"%s","%s"\n' "$name" "$status" "$snaps" "$latest" "$size"
        done
    } >"$CSV_OUT"
    echo "CSV written to $CSV_OUT"
fi

[[ "$fail_count" -gt 0 ]] && exit 1
