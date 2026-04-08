#cloud-config
autoinstall:
  version: 1
  locale: {{ .Env.LOCALE }}
  keyboard:
    layout: {{ .Env.KB_LAYOUT }}
  timezone: {{ .Env.TIMEZONE }}
  identity:
    hostname: {{ .Env.HOSTNAME }}
    username: {{ .Env.USERNAME }}
    password: {{ .Env.PASSWORD_HASH }}
  ssh:
    install-server: true
    authorized-keys:
      - {{ .Env.SSH_PUBLIC_KEY }}
    allow-pw: false
  network:
    network:
      version: 2
      ethernets:
        id0:
          match:
            macaddress: "{{ .Env.NODE_MAC }}"
          addresses:
            - {{ .Env.NODE_IP }}/{{ .Env.SUBNET_PREFIX }}
          routes:
            - to: default
              via: {{ .Env.GATEWAY }}
          nameservers:
            addresses: [{{ .Env.DNS }}]
  storage:
    layout:
      name: lvm
  packages:
    - curl
    - git
    - vim
  late-commands:
    - echo '{{ .Env.USERNAME }} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/{{ .Env.USERNAME }}
    - chmod 440 /target/etc/sudoers.d/{{ .Env.USERNAME }}
