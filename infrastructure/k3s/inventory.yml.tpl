all:
  vars:
    ansible_ssh_private_key_file: {{ .Env.SSH_KEY }}
    ansible_port: {{ .Env.SSH_PORT }}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
    ansible_python_interpreter: /usr/bin/python3
  children:
    control_plane:
      hosts:
{{- range $ip := (strings.Split " " (strings.TrimSpace .Env.CP_NODES)) }}
        {{ $ip }}:
          ansible_user: {{ $.Env.SSH_USER }}
{{- end }}
    workers:
      hosts:
{{- if (strings.TrimSpace .Env.WRK_NODES) }}
{{- range $ip := (strings.Split " " (strings.TrimSpace .Env.WRK_NODES)) }}
        {{ $ip }}:
          ansible_user: {{ $.Env.SSH_USER }}
{{- end }}
{{- else }}
        {}
{{- end }}
