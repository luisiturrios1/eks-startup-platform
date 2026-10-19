#!/usr/bin/env python3
"""Normalize chart image syntax and require digest-pinned, environment-owned ECR images."""
import argparse
import re
import sys

# Terraform invokes this executable directly; use the repository's pinned YAML parser.
from pathlib import Path
if sys.prefix == sys.base_prefix:
    import os
    python = Path(__file__).resolve().parents[1] / '.venv/bin/python'
    if python.exists():
        os.execv(str(python), [str(python), __file__, *sys.argv[1:]])
import yaml


def validate_images(value, registry):
    if isinstance(value, dict):
        for key, item in value.items():
            if key == 'image' and isinstance(item, str):
                pattern = re.escape(registry) + r'/[a-z0-9/_.-]+@sha256:[a-f0-9]{64}'
                if not re.fullmatch(pattern, item):
                    raise ValueError('Refusing foreign, public or unpinned image: ' + item)
            else:
                validate_images(item, registry)
    elif isinstance(value, list):
        for item in value:
            validate_images(item, registry)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--registry', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com', args.registry):
        parser.error('Expected the environment private ECR registry hostname')
    text = re.sub(r':[a-zA-Z0-9_][a-zA-Z0-9_.-]*@sha256:', '@sha256:',
                  sys.stdin.read().replace(':@sha256:', '@sha256:'))
    try:
        for document in yaml.safe_load_all(text):
            validate_images(document, args.registry)
    except (ValueError, yaml.YAMLError) as error:
        sys.exit(str(error))
    sys.stdout.write(text)


if __name__ == '__main__':
    main()
