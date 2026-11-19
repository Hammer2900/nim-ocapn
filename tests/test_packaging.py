#!/usr/bin/env python3
"""Smoke-test the public source layout from an external consumer."""

from __future__ import annotations

import shutil
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="nim-ocapn-package-") as name:
        temp = Path(name)
        package = temp / "package"
        package_src = package / "src"
        package_src.mkdir(parents=True)
        shutil.copy2(ROOT / "nimocapn.nimble", package / "nimocapn.nimble")
        shutil.copytree(ROOT / "src", package_src, dirs_exist_ok=True)
        nimble_dir = temp / "nimble"
        install = subprocess.run(
            ["nimble", "install", f"file://{package}", f"--nimbleDir:{nimble_dir}"],
            cwd=temp, text=True, capture_output=True, check=False,
        )
        if install.returncode:
            raise RuntimeError(f"local package install failed:\n{install.stdout}\n{install.stderr}")
        installed = next((nimble_dir / "pkgs2").glob("nimocapn-*"), None)
        if installed is None:
            raise RuntimeError("Nimble did not produce an installed package")
        consumer = temp / "consumer.nim"
        consumer.write_text(
            "import std/[net, os]\n"
            "import nimocapn\n\n"
            "var config = defaultNodeConfig(Port(0))\n"
            "config.identityPath = getEnv(\"NIM_OCAPN_IDENTITY\")\n"
            "let node = newNode(config)\n"
            "doAssert node.publicIdentity().len > 0\n"
            "node.close()\n",
            encoding="utf-8",
        )
        identity = temp / "consumer.identity"
        binary = temp / "consumer"
        result = subprocess.run(
            ["nim", "c", "--hints:off", f"--path:{installed}",
             f"--out:{binary}", str(consumer)],
            cwd=temp, text=True, capture_output=True, check=False,
        )
        if result.returncode:
            raise RuntimeError(f"consumer build failed:\n{result.stdout}\n{result.stderr}")
        result = subprocess.run(
            [str(binary)], cwd=temp,
            env={**os.environ, "NIM_OCAPN_IDENTITY": str(identity)},
            text=True, capture_output=True, check=False,
        )
        if result.returncode:
            raise RuntimeError(f"consumer run failed:\n{result.stdout}\n{result.stderr}")
    print("packagingTest: PASS (isolated public-module consumer build)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"packagingTest: FAIL: {error}")
        raise SystemExit(1)
