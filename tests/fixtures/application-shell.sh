#!/usr/bin/env bash
set +e
set -o history
probe=$1
control=$2
mkdir -p /var/lib/wayland-session-supervisor/shell-cwd
cd /var/lib/wayland-session-supervisor/shell-cwd || exit 1
export WSS_EXPORTED_VALUE=exported-across-reboot
WSS_LOCAL_VALUE=local-across-reboot
alias wss_alias='printf alias-preserved'
wss_function() { printf function-preserved; }
for n in $(seq 1 120); do printf 'terminal-scrollback-line-%03d\n' "$n"; done
history -s 'echo history-memory-only-alpha'
history -s 'echo history-memory-only-beta'
(sleep 100000) &
WSS_JOB_PID=$!
false
WSS_LAST_STATUS=$?
write_probe() {
  local tmp="$probe.tmp"
  printf '{"pid":%d,"exported":"%s","local":"%s","cwd":"%s","history":"%s","job_pid":%d,"job_alive":%s,"last_status":%d,"function":"%s","alias":"%s"}\n' \
    "$$" "$WSS_EXPORTED_VALUE" "$WSS_LOCAL_VALUE" "$PWD" \
    "$(history 2 | sha256sum | cut -d' ' -f1)" "$WSS_JOB_PID" \
    "$(kill -0 "$WSS_JOB_PID" 2>/dev/null && echo true || echo false)" \
    "$WSS_LAST_STATUS" "$(declare -f wss_function | sha256sum | cut -d' ' -f1)" \
    "$(alias wss_alias | sha256sum | cut -d' ' -f1)" > "$tmp"
  mv "$tmp" "$probe"
}
trap write_probe USR1
write_probe
while IFS= read -r command; do
  [[ $command == probe ]] && write_probe
  [[ $command == exit ]] && break
done < "$control"
