#!/usr/bin/env python3
"""Expose one pstack skill tree to local agents, preserving replaced installs."""
import argparse
import json
import os
from pathlib import Path
import tempfile

ROOTS = ('.agents/skills', '.claude/skills', '.pi/agent/skills', '.grok/skills')


def sync(source, home, apply=False):
    skills = sorted(path for path in source.iterdir() if (path / 'SKILL.md').is_file())
    if not skills:
        raise ValueError(f'no skills in {source}')
    backup = None
    changes = []
    seen = set()
    for root in ROOTS:
        parent = home / root
        if apply:
            parent.mkdir(parents=True, exist_ok=True)
        for skill in skills:
            target = parent / skill.name
            physical = target.parent.resolve() / target.name
            if physical in seen:
                continue
            seen.add(physical)
            if target.is_symlink() and target.resolve() == skill.resolve():
                continue
            changes.append(str(target))
            if not apply:
                continue
            if target.exists() or target.is_symlink():
                if backup is None:
                    backup_root = home / '.local/state/pstack/backups'
                    backup_root.mkdir(parents=True, exist_ok=True)
                    backup = Path(tempfile.mkdtemp(prefix='install-', dir=backup_root))
                saved = backup / root / skill.name
                saved.parent.mkdir(parents=True, exist_ok=True)
                target.rename(saved)
            # A unique temporary link makes replacement atomic for readers.
            with tempfile.TemporaryDirectory(prefix='.pstack-', dir=parent) as staging:
                link = Path(staging) / skill.name
                link.symlink_to(skill.resolve(), target_is_directory=True)
                os.replace(link, target)
    return {'skills': len(skills), 'changed': changes, 'backup': str(backup) if backup else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1] / 'config/pstack/skills')
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--apply', action='store_true', help='install links; otherwise report drift only')
    args = parser.parse_args()
    result = sync(args.source.resolve(), args.home.expanduser().absolute(), args.apply)
    print(json.dumps(result, indent=2))
    return 0 if args.apply or not result['changed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
