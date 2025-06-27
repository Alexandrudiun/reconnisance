#!/usr/bin/env bash

# Enhanced Stealth Reconnaissance Script
# --------------------------------------
# Use this script only on systems you own or have explicit permission to test.
# It combines subdomain enumeration, stealthy port scanning, and vulnerability
# checks using common security tools. Adjust options and tools to your needs.

set -euo pipefail
trap 'echo "[!] Script interrupted"; exit 1' INT

usage() {
    echo "Usage: $0 -d DOMAIN [-o OUTPUT_DIR]"
    echo "  -d DOMAIN        Target domain"
    echo "  -o OUTPUT_DIR    Where results are stored (default: ./recon-<domain>)"
    echo "  --subfinder <opts>  Extra subfinder options"
    echo "  --amass <opts>      Extra amass options"
    echo "  --httpx <opts>      Extra httpx options"
    echo "  --nmap <opts>       Extra nmap options"
    echo "  --nuclei <opts>     Extra nuclei options"
    echo "  --nikto <opts>      Extra nikto options"
    exit 1
}

DOMAIN=""
OUTPUT_DIR=""
SUBFINDER_OPTS=""
AMASS_OPTS=""
HTTPX_OPTS=""
NMAP_OPTS=""
NUCLEI_OPTS=""
NIKTO_OPTS=""

check_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo >&2 "$1 not found"; exit 1; }
}

have_tool() {
    command -v "$1" >/dev/null 2>&1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            DOMAIN="$2"; shift 2;;
        -o)
            OUTPUT_DIR="$2"; shift 2;;
        --subfinder)
            SUBFINDER_OPTS="$2"; shift 2;;
        --amass)
            AMASS_OPTS="$2"; shift 2;;
        --httpx)
            HTTPX_OPTS="$2"; shift 2;;
        --nmap)
            NMAP_OPTS="$2"; shift 2;;
        --nuclei)
            NUCLEI_OPTS="$2"; shift 2;;
        --nikto)
            NIKTO_OPTS="$2"; shift 2;;
        -h|--help)
            usage;;
        *)
            usage;;
    esac
done

[[ -z "$DOMAIN" ]] && usage
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="./recon-$DOMAIN"
mkdir -p "$OUTPUT_DIR"

check_tool subfinder
check_tool nmap
check_tool nuclei

for optional in amass httpx nikto; do
    if ! have_tool "$optional"; then
        echo "[*] $optional not found; skipping $optional step" >&2
    fi
done

if [[ $EUID -ne 0 ]]; then
    echo "[*] Not running as root; using connect scan" >&2
    STEALTH_FLAG="-sT"
else
    STEALTH_FLAG="-sS"
fi

SUBDOMAIN_FILE="$OUTPUT_DIR/subdomains.txt"
PORTS_FILE="$OUTPUT_DIR/nmap.txt"
NUCLEI_DIR="$OUTPUT_DIR/nuclei"

# Subdomain enumeration
echo "[*] Enumerating subdomains for $DOMAIN..."
subfinder -d "$DOMAIN" -silent $SUBFINDER_OPTS | sort -u > "$SUBDOMAIN_FILE"
if have_tool amass; then
    amass enum -d "$DOMAIN" -o - $AMASS_OPTS | sort -u >> "$SUBDOMAIN_FILE"
    sort -u "$SUBDOMAIN_FILE" -o "$SUBDOMAIN_FILE"
fi

if [[ ! -s "$SUBDOMAIN_FILE" ]]; then
    echo "[!] No subdomains found. Exiting." >&2
    exit 1
fi

# Check for active web services
HTTPX_FILE="$SUBDOMAIN_FILE"
if have_tool httpx; then
    echo "[*] Identifying live web hosts with httpx..."
    HTTPX_FILE="$OUTPUT_DIR/httpx.txt"
    httpx -l "$SUBDOMAIN_FILE" $HTTPX_OPTS -o "$HTTPX_FILE"
fi

echo "[*] Running stealth port scan with nmap..."
nmap -iL "$HTTPX_FILE" $STEALTH_FLAG -T0 -Pn --max-retries 2 --top-ports 1000 $NMAP_OPTS -oN "$PORTS_FILE"

echo "[*] Running nuclei vulnerability scan..."
mkdir -p "$NUCLEI_DIR"

while read -r host; do
    nuclei -target "$host" $NUCLEI_OPTS -o "$NUCLEI_DIR/$(echo "$host" | tr ./ _).txt"
done < "$HTTPX_FILE"

if have_tool nikto; then
    echo "[*] Running nikto web vulnerability scan..."
    NIKTO_DIR="$OUTPUT_DIR/nikto"
    mkdir -p "$NIKTO_DIR"
    while read -r host; do
        nikto -host "$host" $NIKTO_OPTS -output "$NIKTO_DIR/$(echo "$host" | tr ./ _).txt"
    done < "$HTTPX_FILE"
fi

echo "[+] Recon complete. Results stored in $OUTPUT_DIR"
