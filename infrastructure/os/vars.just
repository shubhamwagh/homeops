# =============================================================
# OS provisioning constants — update here when Ubuntu releases
# a new version or iPXE URLs change.
# =============================================================

UBUNTU_VERSION   := "24.04.2"
UBUNTU_ISO_AMD64 := "https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso"
UBUNTU_ISO_ARM64 := "https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-arm64.iso"

IPXE_BIOS_URL  := "https://boot.ipxe.org/undionly.kpxe"
IPXE_EFI_URL   := "https://boot.ipxe.org/x86_64-efi/ipxe.efi"
IPXE_ARM64_URL := "https://boot.ipxe.org/arm64-efi/ipxe.efi"

HTTP_PORT := "9090"
