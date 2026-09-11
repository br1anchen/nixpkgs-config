#!/usr/bin/env bash
set -euo pipefail
helper=${1:?usage: run-helper.sh relative-script [arguments...]}
shift
case "$helper" in
  orch/orch.ts|watch-pr/watch-pr|check-plan.mjs) ;;
  *) echo "unsupported pstack helper: $helper" >&2; exit 2 ;;
esac
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../poteto-mode/scripts" && pwd -P)
cache=$(python3 - "$source_dir" <<'PY'
import hashlib, os, shutil, sys, tempfile
from pathlib import Path
source = Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(source.rglob('*')):
    if path.is_file() and 'node_modules' not in path.parts:
        digest.update(str(path.relative_to(source)).encode())
        digest.update(b'\0')
        digest.update(path.read_bytes())
root = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'pstack/helpers'
root.mkdir(parents=True, exist_ok=True)
target = root / digest.hexdigest()
if not target.exists():
    staging = Path(tempfile.mkdtemp(dir=root))
    try:
        shutil.copytree(source, staging, dirs_exist_ok=True, ignore=shutil.ignore_patterns('node_modules'))
        for path in [staging, *staging.rglob('*')]:
            path.chmod(path.stat().st_mode | 0o200)
        try:
            staging.rename(target)
        except OSError:
            if not target.is_dir():
                raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)
print(target)
PY
)
exec bun "$cache/$helper" "$@"
