#!/bin/bash
# Render patroni.yml from the template + environment, then run Patroni.
set -euo pipefail
: "${PATRONI_NAME:?}" "${POSTGRES_SUPERUSER_PASSWORD:?}" "${POSTGRES_REPLICATION_PASSWORD:?}"
export PATRONI_BOOTSTRAP=${PATRONI_BOOTSTRAP:-initdb}
python3 - <<'PY'
import os, re
src = open("/etc/patroni/patroni.yml.tmpl").read()
out = re.sub(r"\$\{(\w+)\}", lambda m: os.environ[m.group(1)], src)
with open("/tmp/patroni.yml", "w") as f:
    f.write(out)
os.chmod("/tmp/patroni.yml", 0o600)
PY
exec patroni /tmp/patroni.yml
