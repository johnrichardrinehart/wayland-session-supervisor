#!/usr/bin/env bash
set -euo pipefail

criu=/run/current-system/sw/bin/criu
plugin_dir=/run/current-system/sw/lib/criu

[[ -x $criu ]] || {
    echo "deployed CRIU is not executable: $criu" >&2
    exit 1
}
[[ -d $plugin_dir ]] || {
    echo "deployed CRIU plugin directory is absent: $plugin_dir" >&2
    exit 1
}

case ${1:-} in
    dump | restore)
        exec "$criu" "$@" --libdir "$plugin_dir" -v4
        ;;
    *)
        exec "$criu" "$@"
        ;;
esac
