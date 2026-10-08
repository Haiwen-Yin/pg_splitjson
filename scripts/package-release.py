#!/usr/bin/env python3
"""Create the reviewable source archive for a tagged PG SplitJSON release.

The release input is deliberately explicit. This prevents local labs, build
products and historical OpenSpec material from silently entering a GitHub
source archive.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read_version() -> str:
    control = (ROOT / "pg_splitjson.control").read_text(encoding="utf-8")
    match = re.search(r"^default_version\s*=\s*'([^']+)'\s*$", control, re.MULTILINE)
    if not match:
        raise SystemExit("pg_splitjson.control has no default_version")
    return match.group(1)


def release_files() -> list[Path]:
    files = [
        Path(".gitattributes"),
        Path(".gitignore"),
        Path("CHANGELOG.md"),
        Path("CHANGELOG.zh-CN.md"),
        Path("LICENSE"),
        Path("Makefile"),
        Path("README.md"),
        Path("README.zh-CN.md"),
        Path("RELEASE_NOTE.md"),
        Path("RELEASE_NOTE.zh-CN.md"),
        Path("pg_splitjson.control"),
    ]
    files += sorted(Path("src").glob("*.c"))
    files += sorted(Path("sql").glob("pg_splitjson--*.sql"))
    files += sorted(Path("sql/parts").glob("*.sql"))
    files += sorted(Path("scripts").glob("*.py"))
    files += sorted(Path("scripts").glob("*.sh"))
    files += sorted(Path("tests").glob("*.sql"))
    files += sorted(Path("tests").glob("*.sh"))
    files += sorted(Path("tests/sql").glob("*.sql"))
    files += sorted(Path("tests/expected").glob("*.out"))
    public_docs = {
        "docs/README.md",
        "docs/README.zh-CN.md",
        "docs/api-reference.md",
        "docs/api-reference.zh-CN.md",
        "docs/design-rationale.md",
        "docs/design-rationale.zh-CN.md",
        "docs/introduction.md",
        "docs/introduction.zh-CN.md",
        "docs/roadmap.md",
        "docs/roadmap.zh-CN.md",
        "docs/storage-format.md",
        "docs/storage-format.zh-CN.md",
        "docs/validation.md",
        "docs/validation.zh-CN.md",
        "docs/production-runbook.md",
        "docs/production-runbook.zh-CN.md",
        "docs/support-matrix.md",
        "docs/support-matrix.zh-CN.md",
    }
    files += sorted(Path(name) for name in public_docs)
    missing = [path for path in files if not (ROOT / path).is_file()]
    if missing:
        raise SystemExit("missing release files: " + ", ".join(map(str, missing)))
    return sorted(set(files))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=read_version())
    args = parser.parse_args()
    version = args.version
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit(f"invalid release version: {version}")
    if version != read_version():
        raise SystemExit("--version must match pg_splitjson.control")

    output_dir = ROOT / "build_output" / version
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"pg_splitjson-{version}.zip"
    checksum = output_dir / f"pg_splitjson-{version}.zip.sha256"
    root_name = f"pg_splitjson-{version}"
    files = release_files()
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for relative in files:
            zf.write(ROOT / relative, f"{root_name}/{relative.as_posix()}")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum.write_text(f"{digest}  {archive.name}\n", encoding="ascii")
    print(f"created {archive} ({len(files)} files)")
    print(f"sha256 {digest}")


if __name__ == "__main__":
    main()
