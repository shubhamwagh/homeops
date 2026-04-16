# Gateway

Kubernetes Gateway API implementation using Cilium. Terminates TLS for all `*.home.didcot` services using a wildcard cert from the homelab CA.

## Prerequisites

- Cilium installed (`just cilium::install`)
- cert-manager installed with homelab CA (`just cert-manager::install`)
- AdGuard configured with DNS rewrite: `*.home.didcot → 192.168.0.9`

## Install

```sh
just gateway::install
```

What happens:
1. Applies Gateway API CRDs (experimental channel, v1.2.1)
2. Re-upgrades Cilium to register the `GatewayClass` now that CRDs exist
3. Issues a wildcard certificate for `*.home.didcot` via cert-manager
4. Creates the `homelab` Gateway listening on port 443 (IP: `192.168.0.9`)
5. Applies HTTPRoutes for all core services
6. Patches CoreDNS to forward `home.didcot` queries to AdGuard (so pods inside the cluster can resolve `*.home.didcot`)

## Recipes

| Recipe | Description |
|---|---|
| `just gateway::install` | Install Gateway + wildcard cert + routes + CoreDNS patch |
| `just gateway::patch-coredns` | Patch CoreDNS to resolve `*.home.didcot` inside cluster |
| `just gateway::uninstall` | Remove all Gateway resources and CRDs |

## Exposed Services

| Hostname | Service |
|---|---|
| `https://adguard.home.didcot` | AdGuard Home |
| `https://longhorn.home.didcot` | Longhorn UI |
| `https://hubble.home.didcot` | Cilium Hubble UI |
| `https://vault.home.didcot` | HashiCorp Vault |
| `https://homepage.home.didcot` | Homepage dashboard |
| `https://skypilot.home.didcot` | SkyPilot |
| `https://keycloak.home.didcot` | Keycloak |

## Adding a New Route

Each app manages its own `HTTPRoute`. Create a file in your app's directory:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp
spec:
  parentRefs:
    - name: homelab
      namespace: kube-system
  hostnames:
    - "myapp.home.didcot"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp
          port: 80
```

Apply it:
```sh
kubectl apply -f infrastructure/system/myapp/httproute.yaml
```

## TLS

The Gateway uses a single wildcard cert `*.home.didcot` issued by `homelab-ca-issuer`. All services behind the Gateway share this cert — no per-service certificate management needed.
