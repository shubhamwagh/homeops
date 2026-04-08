# Proxy DHCP — works alongside your existing DHCP server
port=0
log-dhcp
interface={{ .Env.IFACE }}
dhcp-range={{ .Env.SUBNET_BASE }}.0,proxy

# TFTP
enable-tftp
tftp-root={{ .Env.TFTP_DIR }}

# Detect iPXE clients (option 175 is set by iPXE)
dhcp-match=set:ipxe,175

# First request (UEFI firmware, not yet iPXE) → serve iPXE binary
pxe-service=tag:!ipxe,x86PC,      "Network Boot (BIOS)",  undionly.kpxe
pxe-service=tag:!ipxe,X86-64_EFI, "Network Boot (UEFI)",  ipxe.efi
pxe-service=tag:!ipxe,ARM64_EFI,  "Network Boot (ARM64)", arm64.efi

# iPXE clients: no further action needed — iPXE will load autoexec.ipxe from TFTP root
