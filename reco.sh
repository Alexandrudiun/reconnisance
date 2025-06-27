#!/usr/bin/env bash

# Advanced Web Reconnaissance Script
# ---------------------------------
# Use on infrastructure you own or have explicit permission to test.

set -euo pipefail
trap 'log ERROR "Script interrupted"; exit 1' INT
trap 'log ERROR "Error on line $LINENO"; exit 1' ERR

LOG_FILE="./reco-$(date +%F_%H%M%S).log"
touch "$LOG_FILE"

log() {
    local level="$1"; shift
    echo "$(date +'%F %T') [$level] $*" | tee -a "$LOG_FILE" >&2
}

usage() {
    cat <<USAGE
Usage: $0 -d DOMAIN [options]

Options:
  -o, --output DIR      Output directory (default: ./recon-DOMAIN)
  -p, --profile NAME    Profile to use [light|deep] (default: light)
      --subfinder OPTS  Extra subfinder options
      --amass OPTS      Extra amass options
      --httpx OPTS      Extra httpx options
      --nmap OPTS       Extra nmap options
      --nuclei OPTS     Extra nuclei options
      --nikto OPTS      Extra nikto options
  -h, --help            Show this help
USAGE
    exit 1
}

# Defaults
DOMAIN=""
OUTPUT_DIR=""
PROFILE="light"
SUBFINDER_OPTS=""
AMASS_OPTS=""
HTTPX_OPTS=""
NMAP_OPTS=""
NUCLEI_OPTS=""
NIKTO_OPTS=""
PARALLEL_JOBS=2
CONFIG_FILE="$HOME/.reconrc"

set_profile_defaults() {
    case "$PROFILE" in
        light)
            PARALLEL_JOBS=2
            SUBFINDER_OPTS="-silent"
            NMAP_OPTS="-T0 --top-ports 100"
            ;;
        deep)
            PARALLEL_JOBS=5
            SUBFINDER_OPTS="-all"
            NMAP_OPTS="-T2 -p-"
            ;;
    esac
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

check_tool() { command -v "$1" >/dev/null 2>&1 || { log ERROR "$1 not found"; exit 1; }; }
have_tool() { command -v "$1" >/dev/null 2>&1; }

parse_args() {
    local opts
    opts=$(getopt -o d:o:p:h --long domain:,output:,profile:,subfinder:,amass:,httpx:,nmap:,nuclei:,nikto:,help -n "$0" -- "$@") || usage
    eval set -- "$opts"
    while true; do
        case "$1" in
            -d|--domain) DOMAIN="$2"; shift 2;;
            -o|--output) OUTPUT_DIR="$2"; shift 2;;
            -p|--profile) PROFILE="$2"; shift 2;;
            --subfinder) SUBFINDER_OPTS="$2"; shift 2;;
            --amass) AMASS_OPTS="$2"; shift 2;;
            --httpx) HTTPX_OPTS="$2"; shift 2;;
            --nmap) NMAP_OPTS="$2"; shift 2;;
            --nuclei) NUCLEI_OPTS="$2"; shift 2;;
            --nikto) NIKTO_OPTS="$2"; shift 2;;
            -h|--help) usage;;
            --) shift; break;;
            *) usage;;
        esac
    done
}

setup() {
    [[ -z "$DOMAIN" ]] && usage
    load_config
    set_profile_defaults
    [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="./recon-$DOMAIN"
    mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/nuclei" "$OUTPUT_DIR/nikto"
    SUBDOMAIN_FILE="$OUTPUT_DIR/subdomains.txt"
    HTTPX_FILE="$OUTPUT_DIR/hosts.txt"
    log INFO "Results will be stored in $OUTPUT_DIR"
}

enumerate_subdomains() {
    log INFO "Enumerating subdomains..."
    subfinder -d "$DOMAIN" $SUBFINDER_OPTS | sort -u > "$SUBDOMAIN_FILE"
    if have_tool amass; then
        amass enum -d "$DOMAIN" $AMASS_OPTS | sort -u >> "$SUBDOMAIN_FILE"
        sort -u "$SUBDOMAIN_FILE" -o "$SUBDOMAIN_FILE"
    else
        log INFO "amass not found; skipping"
    fi
    [[ -s "$SUBDOMAIN_FILE" ]] || { log ERROR "No subdomains found"; exit 1; }
}

discover_hosts() {
    log INFO "Checking live hosts..."
    if have_tool httpx; then
        httpx -l "$SUBDOMAIN_FILE" $HTTPX_OPTS -o "$HTTPX_FILE"
    else
        cp "$SUBDOMAIN_FILE" "$HTTPX_FILE"
    fi
}

port_scan() {
    log INFO "Running nmap stealth scan..."
    local flag="-sS"
    [[ $EUID -ne 0 ]] && flag="-sT"
    nmap -iL "$HTTPX_FILE" $flag -Pn $NMAP_OPTS -oJ "$OUTPUT_DIR/nmap.json"
}

run_nuclei() {
    log INFO "Running nuclei in parallel..."
    export NUCLEI_OPTS OUTPUT_DIR
    xargs -a "$HTTPX_FILE" -n 1 -P "$PARALLEL_JOBS" -I{} \
        bash -c 'nuclei -target "$1" $NUCLEI_OPTS -json -o "$OUTPUT_DIR/nuclei/$(echo "$1" | tr ./ _).json"' _ {}
}

run_nikto() {
    if have_tool nikto; then
        log INFO "Running nikto..."
        export NIKTO_OPTS OUTPUT_DIR
        xargs -a "$HTTPX_FILE" -n 1 -P "$PARALLEL_JOBS" -I{} \
            bash -c 'nikto -host "$1" $NIKTO_OPTS -Format json -output "$OUTPUT_DIR/nikto/$(echo "$1" | tr ./ _).json"' _ {}
    else
        log INFO "nikto not found; skipping"
    fi
}

main() {
    parse_args "$@"
    setup

    check_tool subfinder
    check_tool nmap
    check_tool nuclei

    enumerate_subdomains
    discover_hosts
    port_scan
    run_nuclei
    run_nikto

    log INFO "Recon completed"
}

main "$@"
