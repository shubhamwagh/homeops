# AdGuard Home

DNS server with ad/tracker blocking for the home network. Provides the `*.home.didcot` DNS resolution via a wildcard rewrite pointing to the Cilium Gateway IP.

## Prerequisites

- Longhorn installed (for persistent config storage)
- Cilium installed (for LoadBalancer IP)

## Install

```sh
just adguard::install
```

After install, the setup wizard is available at `http://192.168.0.3:3000`.

**Post-install step (required):** In the AdGuard admin UI, add a DNS rewrite:

```
*.home.didcot → 192.168.0.9
```

This makes all `*.home.didcot` domains resolve to the Cilium Gateway.

## Recipes

| Recipe | Description |
|---|---|
| `just adguard::install` | Deploy AdGuard Home |
| `just adguard::uninstall` | Remove AdGuard Home |

## Network Details

| | Address |
|---|---|
| DNS port | `192.168.0.3:53` |
| Setup wizard | `http://192.168.0.3:3000` |
| Admin UI (after setup) | `https://adguard.home.didcot` |

## Router Configuration

Point your router's DNS server to `192.168.0.3` so all devices on the network resolve `*.home.didcot` correctly and benefit from ad blocking.
