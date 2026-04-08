# =============================================================
# os/mod.just — bare-metal OS provisioning via PXE
#
# Prerequisites (install once):
#   macOS:  brew install dnsmasq xorriso wakeonlan
#   Linux:  sudo apt install -y dnsmasq xorriso wakeonlan
#
# Initial cluster flow:
#   just os::configure  → generates per-node autoinstall configs
#   just os::download   → fetches iPXE binaries + Ubuntu netboot files
#   just os::start      → starts dnsmasq (PXE/TFTP) + HTTP server
#   (boot nodes)
#   just os::stop       → stops services
#
# Adding a node later:
#   just os::add-node   → generates config for one new node, regenerates iPXE script
#   just os::start      → start PXE server if not already running
#   (boot node → F12 → Network Boot)
#   just os::watch      → monitor install progress
#   just k3s::add-node  → join node to the k3s cluster
# =============================================================
set shell := ["bash", "-euo", "pipefail", "-c"]

import 'vars.just'

OS_DIR    := justfile_directory() / "infrastructure" / "os"
NODES_DIR := OS_DIR / "nodes"
BOOT_DIR  := OS_DIR / "boot"
TFTP_DIR  := OS_DIR / "tftp"

# Interactive OS provisioning setup — generates per-node autoinstall configs
configure:
    #!/usr/bin/env bash
    set -euo pipefail

    gum style \
      --border double --border-foreground 212 \
      --padding "1 4" --margin "1 0" \
      --bold "OS Provisioning Configuration"

    # ── Server settings ───────────────────────────────────────
    gum style --bold --foreground 212 "\n▸ PXE Server (this machine)"

    # Auto-detect IP and default interface — platform-aware
    OS=$(uname -s)
    if [[ "$OS" == "Darwin" ]]; then
      detected_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
      default_iface="en0"
    else
      detected_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1 || echo "")
      default_iface=$(ip route 2>/dev/null | awk '/default/{print $5}' | head -1 || echo "eth0")
    fi
    SERVER_IP=$(gum input --prompt "IP on local network › " --value "${detected_ip}")
    [[ -z "$SERVER_IP" ]] && { gum style --foreground 196 "Server IP required"; exit 1; }

    IFACE=$(gum input --prompt "Network interface › " --value "${default_iface}")

    # ── Common node settings ──────────────────────────────────
    gum style --bold --foreground 212 "\n▸ Common Node Settings"
    USERNAME=$(gum input  --prompt "SSH username › "      --value "smw")
    SSH_KEY_PATH=$(gum input --prompt "SSH public key path › " --value "$HOME/.ssh/id_ed25519.pub")
    [[ ! -f "$SSH_KEY_PATH" ]] && { gum style --foreground 196 "SSH public key not found: $SSH_KEY_PATH"; exit 1; }
    SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH")

    PASSWORD=$(gum input --prompt "User password › " --password --placeholder "used for sudo, SSH key auth only")
    # SHA-512 password hash — openssl on Linux, passlib on macOS (openssl -6 unsupported)
    if [[ "$(uname -s)" == "Linux" ]]; then
      PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")
    else
      PYTHON3=$(command -v python3.12 2>/dev/null || command -v /usr/local/bin/python3 2>/dev/null || echo python3)
      "$PYTHON3" -m pip install passlib --quiet --user 2>/dev/null || true
      PASSWORD_HASH=$("$PYTHON3" -c "from passlib.hash import sha512_crypt; print(sha512_crypt.using(rounds=5000).hash('${PASSWORD}'))")
    fi

    GATEWAY=$(gum input --prompt "Gateway IP › "    --value "192.168.0.1")
    DNS=$(gum input     --prompt "DNS servers › "   --value "1.1.1.1,8.8.8.8")
    SUBNET=$(gum input  --prompt "Subnet prefix › " --value "24")
    LOCALE=$(gum input    --prompt "Locale › "           --value "en_GB.UTF-8")
    KB_LAYOUT=$(gum input --prompt "Keyboard layout › "  --value "gb")
    TIMEZONE=$(gum input  --prompt "Timezone › "         --value "Europe/London")

    # ── Nodes ─────────────────────────────────────────────────
    gum style --bold --foreground 212 "\n▸ Nodes"
    NODE_COUNT=$(gum input --prompt "Number of nodes › " --value "3")

    mkdir -p "{{NODES_DIR}}"

    for i in $(seq 1 "$NODE_COUNT"); do
      gum style --bold --foreground 212 "\n  Node $i"
      HOSTNAME=$(gum input --prompt "  Hostname › "    --value "homelab-hpg2-node${i}")
      NODE_IP=$(gum input  --prompt "  IP address › "  --placeholder "192.168.0.3${i}")
      NODE_MAC=$(gum input --prompt "  MAC address › " --placeholder "aa:bb:cc:dd:ee:ff")
      [[ -z "$NODE_MAC" ]] && { gum style --foreground 196 "MAC address required"; exit 1; }
      ARCH=$(gum choose --header "  Architecture" "amd64" "arm64")

      # Normalise MAC: lowercase, dashes (for directory + iPXE ${net0/mac:hexhyp})
      MAC_DIR=$(echo "$NODE_MAC" | tr '[:upper:]' '[:lower:]' | tr ':' '-')

      NODE_DIR="{{NODES_DIR}}/${MAC_DIR}"
      mkdir -p "$NODE_DIR"

      # Save arch for use by download recipe
      echo "$ARCH" > "${NODE_DIR}/arch"

      # Generate user-data from template
      export HOSTNAME USERNAME PASSWORD_HASH SSH_PUBLIC_KEY NODE_MAC NODE_IP \
             GATEWAY DNS LOCALE KB_LAYOUT TIMEZONE
      export SUBNET_PREFIX="$SUBNET"
      gomplate -f "{{OS_DIR}}/autoinstall/user-data.tpl" -o "${NODE_DIR}/user-data"

      cp "{{OS_DIR}}/autoinstall/meta-data" "${NODE_DIR}/meta-data"

      gum style --foreground 46 "  ✓ nodes/${MAC_DIR}/ (${ARCH})"
    done

    # Generate iPXE boot script with server IP
    mkdir -p "{{TFTP_DIR}}"
    export SERVER_IP HTTP_PORT="{{HTTP_PORT}}"
    gomplate -f "{{OS_DIR}}/boot/ipxe.script" -o "{{TFTP_DIR}}/boot.ipxe"
    # iPXE looks for autoexec.ipxe in TFTP root immediately after loading
    cp "{{TFTP_DIR}}/boot.ipxe" "{{TFTP_DIR}}/autoexec.ipxe"

    # Generate dnsmasq config from template
    SUBNET_BASE=$(echo "$SERVER_IP" | cut -d. -f1-3)
    export IFACE SUBNET_BASE TFTP_DIR="{{TFTP_DIR}}"
    gomplate -f "{{OS_DIR}}/dnsmasq.conf.tpl" -o "{{OS_DIR}}/dnsmasq.conf"

    gum style --foreground 46 "  ✓ dnsmasq.conf"
    gum style --foreground 46 --bold \
      "\nDone. Run 'just os::download' then 'just os::start'."

# Download iPXE binaries and Ubuntu 24.04 netboot files for all configured node architectures
download:
    #!/usr/bin/env bash
    set -euo pipefail

    [[ -d "{{NODES_DIR}}" ]] || { echo "Run 'just os::configure' first"; exit 1; }

    gum style --bold --foreground 212 "Downloading boot files..."

    mkdir -p "{{TFTP_DIR}}"

    # ── iPXE binaries (always download all — small files) ─────
    gum style --foreground 244 "  · iPXE x86 BIOS  (undionly.kpxe)"
    curl -sSL "{{IPXE_BIOS_URL}}" -o "{{TFTP_DIR}}/undionly.kpxe"

    gum style --foreground 244 "  · iPXE x86_64 UEFI (ipxe.efi)"
    curl -sSL "{{IPXE_EFI_URL}}" -o "{{TFTP_DIR}}/ipxe.efi"

    gum style --foreground 244 "  · iPXE ARM64 UEFI  (arm64.efi)"
    curl -sSL "{{IPXE_ARM64_URL}}" -o "{{TFTP_DIR}}/arm64.efi"

    gum style --foreground 46 "  ✓ iPXE binaries"

    # ── Collect unique architectures from configured nodes ────
    archs_needed=$(cat "{{NODES_DIR}}"/*/arch 2>/dev/null | sort -u)

    if [[ -z "$archs_needed" ]]; then
      echo "No nodes configured. Run 'just os::configure' first."
      exit 1
    fi

    # ── Download Ubuntu netboot files per architecture ────────
    while IFS= read -r arch; do
      mkdir -p "{{BOOT_DIR}}/ubuntu/${arch}"

      case "$arch" in
        amd64) ISO_URL="{{UBUNTU_ISO_AMD64}}" ;;
        arm64) ISO_URL="{{UBUNTU_ISO_ARM64}}" ;;
        *)     gum style --foreground 196 "Unknown arch: $arch"; exit 1 ;;
      esac

      ISO_PATH="/tmp/ubuntu-{{UBUNTU_VERSION}}-${arch}.iso"

      gum style --foreground 244 "  · Ubuntu 24.04 ${arch} ISO (this may take a while)"
      curl -fL --progress-bar "$ISO_URL" -o "$ISO_PATH"

      gum style --foreground 244 "  · Extracting vmlinuz + initrd (${arch})"
      EXTRACT_DIR=$(mktemp -d)
      xorriso -osirrox on -indev "$ISO_PATH" \
        -extract casper/vmlinuz "${EXTRACT_DIR}/vmlinuz" \
        -extract casper/initrd  "${EXTRACT_DIR}/initrd" \
        2>/dev/null
      cp "${EXTRACT_DIR}/vmlinuz" "{{BOOT_DIR}}/ubuntu/${arch}/vmlinuz"
      cp "${EXTRACT_DIR}/initrd"  "{{BOOT_DIR}}/ubuntu/${arch}/initrd"
      # Keep ISO so casper can mount it as the live filesystem during install
      mv "$ISO_PATH" "{{BOOT_DIR}}/ubuntu/${arch}/ubuntu-live.iso"
      rm -rf "$EXTRACT_DIR"

      gum style --foreground 46 "  ✓ Ubuntu 24.04 ${arch} netboot files"
    done <<< "$archs_needed"

    gum style --foreground 46 --bold "\nAll boot files ready. Run 'just os::start'."

# Start PXE server (dnsmasq + HTTP)
start:
    #!/usr/bin/env bash
    set -euo pipefail

    [[ -f "{{OS_DIR}}/dnsmasq.conf" ]] || { echo "Run 'just os::configure' first"; exit 1; }

    # HTTP server (serves nodes/ and boot/ directories)
    echo "Starting HTTP server on :{{HTTP_PORT}}..."
    python3 -m http.server {{HTTP_PORT}} --directory "{{OS_DIR}}" \
      > "{{OS_DIR}}/http.log" 2>&1 &
    echo $! > "{{OS_DIR}}/http.pid"
    gum style --foreground 46 "  ✓ HTTP server started (pid $(cat {{OS_DIR}}/http.pid))"

    # dnsmasq (requires sudo for port 67)
    # Resolve full path — sudo uses restricted PATH; dnsmasq is in sbin not bin
    DNSMASQ=""
    for p in /opt/homebrew/sbin/dnsmasq /usr/local/sbin/dnsmasq /usr/sbin/dnsmasq; do
      [[ -x "$p" ]] && { DNSMASQ="$p"; break; }
    done
    [[ -n "$DNSMASQ" ]] || { gum style --foreground 196 "dnsmasq not found — brew install dnsmasq"; exit 1; }

    # macOS blocks sudo from accessing files under /Users — copy TFTP dir to /tmp
    RUNTIME_TFTP="/tmp/homeops-tftp"
    rm -rf "$RUNTIME_TFTP"
    cp -r "{{TFTP_DIR}}" "$RUNTIME_TFTP"

    # Generate a runtime dnsmasq.conf pointing to /tmp TFTP path
    RUNTIME_CONF="/tmp/homeops-dnsmasq.conf"
    sed "s|tftp-root=.*|tftp-root=$RUNTIME_TFTP|" "{{OS_DIR}}/dnsmasq.conf" > "$RUNTIME_CONF"

    echo "Starting dnsmasq (requires sudo for DHCP port 67)..."
    sudo "$DNSMASQ" --conf-file="$RUNTIME_CONF" \
      --pid-file="{{OS_DIR}}/dnsmasq.pid" \
      --log-facility="{{OS_DIR}}/dnsmasq.log"
    gum style --foreground 46 "  ✓ dnsmasq started (TFTP from $RUNTIME_TFTP)"

    gum style --foreground 46 --bold "\nPXE server running. Boot your nodes now."

# Stop PXE server
stop:
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ -f "{{OS_DIR}}/http.pid" ]]; then
      kill "$(cat {{OS_DIR}}/http.pid)" 2>/dev/null || true
      rm "{{OS_DIR}}/http.pid"
      gum style --foreground 46 "  ✓ HTTP server stopped"
    fi

    if [[ -f "{{OS_DIR}}/dnsmasq.pid" ]]; then
      sudo kill "$(cat {{OS_DIR}}/dnsmasq.pid)" 2>/dev/null || true
      rm "{{OS_DIR}}/dnsmasq.pid"
      gum style --foreground 46 "  ✓ dnsmasq stopped"
    fi

# Show PXE server status
status:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "HTTP server:"
    if [[ -f "{{OS_DIR}}/http.pid" ]] && kill -0 "$(cat {{OS_DIR}}/http.pid)" 2>/dev/null; then
      gum style --foreground 46 "  ✓ running (pid $(cat {{OS_DIR}}/http.pid))"
    else
      gum style --foreground 196 "  ✗ not running"
    fi

    echo "dnsmasq:"
    if [[ -f "{{OS_DIR}}/dnsmasq.pid" ]] && sudo kill -0 "$(cat {{OS_DIR}}/dnsmasq.pid)" 2>/dev/null; then
      gum style --foreground 46 "  ✓ running (pid $(cat {{OS_DIR}}/dnsmasq.pid))"
    else
      gum style --foreground 196 "  ✗ not running"
    fi

    echo ""
    echo "Configured nodes:"
    if [[ -d "{{NODES_DIR}}" ]]; then
      for dir in "{{NODES_DIR}}"/*/; do
        [[ -d "$dir" ]] && echo "  · $(basename "$dir")"
      done
    else
      echo "  (none — run 'just os::configure')"
    fi

# Send Wake-on-LAN magic packets to all configured nodes
wake:
    #!/usr/bin/env bash
    set -euo pipefail

    [[ -d "{{NODES_DIR}}" ]] || { echo "No nodes configured. Run 'just os::configure' first."; exit 1; }

    for dir in "{{NODES_DIR}}"/*/; do
      [[ -d "$dir" ]] || continue
      mac_dir=$(basename "$dir")
      mac=$(echo "$mac_dir" | tr '-' ':')
      hostname=$(grep -oP 'hostname:\s*\K\S+' "${dir}/user-data" 2>/dev/null | head -1 || echo "$mac_dir")
      gum style --foreground 244 "  · Waking ${hostname} (${mac})"
      wakeonlan "$mac"
    done

    gum style --foreground 46 --bold "\nWake packets sent — nodes should power on in a few seconds."

# Watch install progress — tails PXE logs and polls nodes for SSH availability
watch:
    #!/usr/bin/env bash
    set -euo pipefail

    [[ -d "{{NODES_DIR}}" ]] || { echo "No nodes configured. Run 'just os::configure' first."; exit 1; }

    # Collect node IPs from user-data files into a temp file (ip:hostname)
    NODES_TMP=$(mktemp)
    DONE_TMP=$(mktemp)
    trap "rm -f $NODES_TMP $DONE_TMP; kill \$TAIL_PID 2>/dev/null; exit" INT TERM

    for dir in "{{NODES_DIR}}"/*/; do
      [[ -d "$dir" ]] || continue
      ip=$(grep -oP '^\s+-\s+\K[\d.]+(?=/)' "${dir}/user-data" 2>/dev/null | head -1 || true)
      hostname=$(grep -oP 'hostname:\s*\K\S+' "${dir}/user-data" 2>/dev/null | head -1 || true)
      if [[ -n "$ip" ]]; then
        echo "${ip}:${hostname:-unknown}" >> "$NODES_TMP"
        echo "Watching node: ${hostname:-unknown} ($ip)"
      fi
    done

    echo ""
    echo "── Live logs (Ctrl+C to stop) ────────────────────────────"
    echo ""

    # Tail both log files in background
    tail -F "{{OS_DIR}}/dnsmasq.log" "{{OS_DIR}}/http.log" 2>/dev/null &
    TAIL_PID=$!

    # Poll SSH every 15s and report when each node comes up
    while true; do
      all_done=true
      while IFS=: read -r ip hostname; do
        grep -qx "$ip" "$DONE_TMP" 2>/dev/null && continue
        if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
              -o PasswordAuthentication=no \
              "smw@${ip}" "echo ok" &>/dev/null; then
          gum style --foreground 46 "\n  ✓ ${hostname} (${ip}) is up"
          echo "$ip" >> "$DONE_TMP"
        else
          all_done=false
        fi
      done < "$NODES_TMP"
      [[ "$all_done" == "true" ]] && break
      sleep 15
    done
    rm -f "$NODES_TMP" "$DONE_TMP"

    kill $TAIL_PID 2>/dev/null || true
    gum style --foreground 46 --bold "\nAll nodes are up!"

# Add a single new node — prompts for per-node details, reuses common settings from existing nodes
add-node:
    #!/usr/bin/env bash
    set -euo pipefail

    gum style \
      --border double --border-foreground 212 \
      --padding "1 4" --margin "1 0" \
      --bold "Add Node"

    # ── Per-node details ──────────────────────────────────────
    gum style --bold --foreground 212 "\n▸ New Node"
    HOSTNAME=$(gum input --prompt "  Hostname › "    --value "homelab-hpg2-node")
    NODE_IP=$(gum input  --prompt "  IP address › "  --placeholder "192.168.0.3X")
    [[ -z "$NODE_IP" ]] && { gum style --foreground 196 "IP address required"; exit 1; }
    NODE_MAC=$(gum input --prompt "  MAC address › " --placeholder "aa:bb:cc:dd:ee:ff")
    [[ -z "$NODE_MAC" ]] && { gum style --foreground 196 "MAC address required"; exit 1; }
    ARCH=$(gum choose --header "  Architecture" "amd64" "arm64")

    # ── Common settings — read from existing node or prompt ───
    EXISTING_USER_DATA=""
    for ud in "{{NODES_DIR}}"/*/user-data; do
      [[ -f "$ud" ]] && { EXISTING_USER_DATA="$ud"; break; }
    done

    if [[ -n "$EXISTING_USER_DATA" ]]; then
      gum style --foreground 244 "\nReading common settings from existing node: ${EXISTING_USER_DATA}"

      USERNAME=$(grep -oP 'username:\s*\K\S+' "$EXISTING_USER_DATA" | head -1)
      PASSWORD_HASH=$(grep -oP 'password:\s*\K\S+' "$EXISTING_USER_DATA" | head -1)
      SSH_PUBLIC_KEY=$(grep -oP '^\s*-\s+\K.+' "$EXISTING_USER_DATA" | grep -v '^-' | head -1)
      # Extract gateway (via: <ip>)
      GATEWAY=$(grep -oP 'via:\s*\K[\d.]+' "$EXISTING_USER_DATA" | head -1)
      # Extract DNS list from nameservers: addresses: [a, b, ...]
      DNS=$(grep -oP 'addresses:\s*\[\K[^\]]+' "$EXISTING_USER_DATA" | head -1 | tr -d ' ')
      # Extract subnet prefix from addresses: - <ip>/<prefix>
      SUBNET=$(grep -oP 'addresses:\s*\n\s*-\s+[\d.]+/\K\d+' "$EXISTING_USER_DATA" | head -1)
      # Fallback: parse from the addresses line directly (non-multiline grep)
      if [[ -z "$SUBNET" ]]; then
        SUBNET=$(grep -oP '/\K\d+' "$EXISTING_USER_DATA" | head -1)
      fi

      LOCALE=$(grep -oP 'locale:\s*\K\S+' "$EXISTING_USER_DATA" | head -1)
      KB_LAYOUT=$(grep -oP 'layout:\s*\K\S+' "$EXISTING_USER_DATA" | head -1)
      TIMEZONE=$(grep -oP 'timezone:\s*\K\S+' "$EXISTING_USER_DATA" | head -1)

      gum style --foreground 244 "  username   : ${USERNAME}"
      gum style --foreground 244 "  gateway    : ${GATEWAY}"
      gum style --foreground 244 "  DNS        : ${DNS}"
      gum style --foreground 244 "  subnet     : /${SUBNET}"
      gum style --foreground 244 "  locale     : ${LOCALE}"
      gum style --foreground 244 "  keyboard   : ${KB_LAYOUT}"
      gum style --foreground 244 "  timezone   : ${TIMEZONE}"
    else
      # No existing nodes — prompt for common settings
      gum style --bold --foreground 212 "\n▸ Common Node Settings (no existing nodes found)"
      USERNAME=$(gum input --prompt "SSH username › " --value "smw")
      SSH_KEY_PATH=$(gum input --prompt "SSH public key path › " --value "$HOME/.ssh/id_ed25519.pub")
      [[ ! -f "$SSH_KEY_PATH" ]] && { gum style --foreground 196 "SSH public key not found: $SSH_KEY_PATH"; exit 1; }
      SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH")

      PASSWORD=$(gum input --prompt "User password › " --password --placeholder "used for sudo, SSH key auth only")
      if [[ "$(uname -s)" == "Linux" ]]; then
        PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")
      else
        python3 -m pip install passlib --quiet --user 2>/dev/null || true
        PASSWORD_HASH=$(python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.using(rounds=5000).hash('${PASSWORD}'))")
      fi

      GATEWAY=$(gum input --prompt "Gateway IP › "    --value "192.168.0.1")
      DNS=$(gum input     --prompt "DNS servers › "   --value "1.1.1.1,8.8.8.8")
      SUBNET=$(gum input  --prompt "Subnet prefix › " --value "24")
      LOCALE=$(gum input    --prompt "Locale › "          --value "en_GB.UTF-8")
      KB_LAYOUT=$(gum input --prompt "Keyboard layout › " --value "gb")
      TIMEZONE=$(gum input  --prompt "Timezone › "        --value "Europe/London")
    fi

    # ── Generate node config ──────────────────────────────────
    MAC_DIR=$(echo "$NODE_MAC" | tr '[:upper:]' '[:lower:]' | tr ':' '-')
    NODE_DIR="{{NODES_DIR}}/${MAC_DIR}"
    mkdir -p "$NODE_DIR"

    echo "$ARCH" > "${NODE_DIR}/arch"

    export HOSTNAME USERNAME PASSWORD_HASH SSH_PUBLIC_KEY NODE_MAC NODE_IP \
           GATEWAY DNS LOCALE KB_LAYOUT TIMEZONE
    export SUBNET_PREFIX="$SUBNET"
    gomplate -f "{{OS_DIR}}/autoinstall/user-data.tpl" -o "${NODE_DIR}/user-data"

    cp "{{OS_DIR}}/autoinstall/meta-data" "${NODE_DIR}/meta-data"

    gum style --foreground 46 "  ✓ nodes/${MAC_DIR}/ (${ARCH})"

    # ── Regenerate iPXE boot script using SERVER_IP from dnsmasq.conf ──
    DNSMASQ_CONF="{{OS_DIR}}/dnsmasq.conf"
    if [[ -f "$DNSMASQ_CONF" ]]; then
      SERVER_IP=$(grep -oP 'http://\K[\d.]+' "$DNSMASQ_CONF" | head -1)
      if [[ -n "$SERVER_IP" ]]; then
        export SERVER_IP HTTP_PORT="{{HTTP_PORT}}"
        gomplate -f "{{OS_DIR}}/boot/ipxe.script" -o "{{TFTP_DIR}}/boot.ipxe"
        cp "{{TFTP_DIR}}/boot.ipxe" "{{TFTP_DIR}}/autoexec.ipxe"
        gum style --foreground 46 "  ✓ tftp/boot.ipxe regenerated (server: ${SERVER_IP})"
      else
        gum style --foreground 196 "  ⚠ Could not extract SERVER_IP from dnsmasq.conf — boot.ipxe not updated"
      fi
    else
      gum style --foreground 196 "  ⚠ dnsmasq.conf not found — run 'just os::configure' to create it, or boot.ipxe will be stale"
    fi

    gum style --foreground 46 --bold "\nNode config ready."
    gum style --foreground 212 \
      "\nNext steps:" \
      "  1. Start PXE server if not running:  just os::start" \
      "  2. Boot the node, press F12 → Network Boot (PXE)" \
      "  3. Watch install progress:            just os::watch" \
      "  4. Join node to k3s cluster:          just k3s::add-node"
