#!/usr/bin/env python3
"""Check the vendored suite's discovery, inventory, links, and runtime entrypoints."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1] / 'config/pstack'
manifest = json.loads((root / 'sources.json').read_text())
skills = root / 'skills'
expected = set(manifest['skills'])
actual = {path.parent.name for path in skills.glob('*/SKILL.md')}
assert expected == actual, f'skill inventory mismatch: {expected ^ actual}'
assert set(manifest['previous_install']) <= actual, 'previously installed skills lost'
assert len(list(skills.rglob('SKILL.md'))) == len(actual), 'nested skills would be discovered twice'
assert (skills / 'pstack/LICENSE').is_file()
for name in sorted(actual):
    path = skills / name / 'SKILL.md'
    text = path.read_text()
    assert text.startswith('---\n'), path
    frontmatter, body = text.split('---', 2)[1:]
    assert f'\nname: {name}\n' in frontmatter, path
    assert re.search(r'^description: .+', frontmatter, re.M), path
    assert 'runtime.md)' in body, f'missing runtime adapter: {path}'
    assert not re.search(r'^(mode|icon|color|reminder|disable-model-invocation):', frontmatter, re.M), path
for path in skills.rglob('*.md'):
    for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
        if re.match(r'\w+://|#|mailto:', target) or any(char in target for char in '<>*` '):
            continue
        if target == 'url':  # Citation template in why's synthesizer contract.
            continue
        assert (path.parent / target.split('#')[0]).exists(), f'{path}: missing {target}'
print(f'{len(actual)} skills checked; all {len(manifest["previous_install"])} previous skills covered')
