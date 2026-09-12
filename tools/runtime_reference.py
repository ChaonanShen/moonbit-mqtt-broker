#!/usr/bin/env python3
"""Validate a successful local runtime-image reference without executing its text."""
import argparse
import json
import pathlib
import re
import subprocess

PROFILES = ('base', 'argon2', 'tls', 'full')


def parse_evidence(text):
    fields = {}
    required = {'source_commit', 'exit_code', 'completed_at'} | {
        f'runtime_{profile}{suffix}' for profile in PROFILES for suffix in ('', '_image')
    }
    for line in text.splitlines():
        key, separator, value = line.partition('=')
        if separator and key in required:
            if key in fields:
                raise ValueError('duplicate evidence field: ' + key)
            fields[key] = value
    if not required <= fields.keys():
        raise ValueError('incomplete runtime reference evidence')
    if fields['exit_code'] != '0' or not fields['completed_at']:
        raise ValueError('runtime reference did not finish successfully')
    if not re.fullmatch(r'[0-9a-f]{40}', fields['source_commit']):
        raise ValueError('runtime reference commit must be a full SHA')
    for profile in PROFILES:
        if fields[f'runtime_{profile}'] != 'PASS':
            raise ValueError('reference profile did not pass: ' + profile)
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', fields[f'runtime_{profile}_image']):
            raise ValueError('invalid reference image digest: ' + profile)
    return fields


def output(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def resolve(repo, reference, head):
    repo, reference = pathlib.Path(repo).resolve(), pathlib.Path(reference).resolve()
    reference.relative_to(repo / 'test-results' / 'distribution')
    fields = parse_evidence((reference / 'evidence.txt').read_text(encoding='utf-8'))
    recorded = fields['source_commit']
    current_tree = output(['git', '-C', str(repo), 'rev-parse', head + ':tests/runtime'])
    reference_tree = output(['git', '-C', str(repo), 'rev-parse', recorded + ':tests/runtime'])
    if current_tree != reference_tree:
        raise ValueError('runtime build context changed; cached reference is not applicable')
    images = {}
    for profile in PROFILES:
        digest = fields[f'runtime_{profile}_image']
        actual = output(['docker', 'image', 'inspect', '--format', '{{.Id}} {{.Os}} {{.Architecture}}', digest])
        if actual != digest + ' linux amd64':
            raise ValueError('reference image identity/platform mismatch: ' + profile)
        images[profile] = digest
    return {
        'reference_result': str(reference.relative_to(repo)),
        'reference_commit': recorded,
        'candidate_commit': head,
        'runtime_context_tree': current_tree,
        'images': images,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--reference', required=True)
    parser.add_argument('--head', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}', args.head):
        parser.error('--head must be a full commit SHA')
    try:
        print(json.dumps(resolve(args.repo, args.reference, args.head), indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Invalid runtime reference: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
