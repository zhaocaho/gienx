#!/usr/bin/env python3
"""Fail if an ELF binary requires a glibc newer than the given maximum."""

import argparse
import re
import subprocess
import sys
from pathlib import Path


GLIBC_RE = re.compile(r"GLIBC_([0-9]+(?:\.[0-9]+){1,2})")


def parse_version(raw: str) -> tuple[int, ...]:
    return tuple(int(part) for part in raw.split("."))


def glibc_versions(binary: Path) -> list[str]:
    try:
        output = subprocess.check_output(
            ["objdump", "-T", str(binary)],
            text=True,
            stderr=subprocess.STDOUT,
        )
    except FileNotFoundError:
        raise SystemExit("objdump not found; install binutils") from None
    except subprocess.CalledProcessError as err:
        raise SystemExit(
            f"objdump -T failed for {binary}:\n{err.output}"
        ) from err

    found = {match.group(1) for match in GLIBC_RE.finditer(output)}
    return sorted(found, key=parse_version)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument(
        "--max",
        default="2.31",
        help="Highest allowed GLIBC symbol version (default: 2.31)",
    )
    args = parser.parse_args()
    binary = args.binary
    if not binary.is_file():
        print(f"not a file: {binary}", file=sys.stderr)
        return 1

    versions = glibc_versions(binary)
    if not versions:
        print(f"{binary}: no GLIBC_* symbols (static or unexpected)")
        return 0

    highest = versions[-1]
    print(f"{binary}: {', '.join(f'GLIBC_{v}' for v in versions)}")
    if parse_version(highest) > parse_version(args.max):
        print(
            f"error: {binary} requires GLIBC_{highest}, max allowed is GLIBC_{args.max}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
