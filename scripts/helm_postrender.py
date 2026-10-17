#!/usr/bin/env python3
"""Normalize charts' tag-only image interpolation and reject unmirrored images."""
import re,sys
text=sys.stdin.read().replace(':@sha256:', '@sha256:')
for match in re.finditer(r'^[ \t]*(?:-[ \t]*)?image:[ \t]*["\x27]?([^\s"\x27]+)',text,re.M):
    image=match.group(1)
    if not re.fullmatch(r'[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(?:\.cn)?/[^@]+@sha256:[a-f0-9]{64}',image):
        sys.exit('Refusing non-private or unpinned controller image: '+image)
sys.stdout.write(text)
