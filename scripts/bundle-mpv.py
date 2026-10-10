#!/usr/bin/env python3
"""Copy libmpv's Homebrew dylib closure into the app and rewrite local references."""
import os
import pathlib
import shutil
import re
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
frameworks = app / "Contents/Frameworks"
if frameworks.exists():
    shutil.rmtree(frameworks)
frameworks.mkdir(parents=True, exist_ok=True)
runtime = pathlib.Path(os.environ.get("BILINEXT_MPV_LIBRARY", "/Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib"))
if not runtime.exists():
    runtime = pathlib.Path("/opt/homebrew/lib/libmpv.2.dylib")
executable = app / "Contents/MacOS/BiliNext"
seen = {}


def dependencies(binary):
    output = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    return list(dict.fromkeys(line.strip().split(" (", 1)[0] for line in output.splitlines() if line.startswith("\t")))


def copy_dependency(source):
    if pathlib.Path(source).name == "libmpv.2.dylib":
        source = str(runtime)
    path = pathlib.Path(source).resolve()
    if path in seen:
        return seen[path]
    target = frameworks / path.name
    if any(other.name == target.name for other in seen.values()):
        raise RuntimeError(f"Conflicting library name: {target.name}")
    seen[path] = target
    shutil.copy2(path, target)
    target.chmod(0o755)
    subprocess.run(["install_name_tool", "-id", "@rpath/" + target.name, str(target)], check=True)
    rewrite(target)
    return target


def rewrite(binary):
    for dependency in dependencies(binary):
        if dependency.startswith("@rpath/"):
            local = runtime.parent / pathlib.Path(dependency).name
            if not local.exists():
                raise RuntimeError(f"Missing runtime library: {dependency}")
            target = copy_dependency(str(local))
            subprocess.run(["install_name_tool", "-change", dependency,
                            "@rpath/" + target.name, str(binary)], check=True)
        elif dependency.startswith(("/opt/homebrew/", "/usr/local/")):
            target = copy_dependency(dependency)
            subprocess.run(["install_name_tool", "-change", dependency,
                            "@rpath/" + target.name, str(binary)], check=True)


rewrite(executable)
subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable)], check=True)
for library in seen.values():
    metadata = subprocess.check_output(["vtool", "-show-build", str(library)], text=True)
    for version in re.findall(r"minos ([0-9.]+)", metadata):
        if int(version.split(".")[0]) > 26:
            raise RuntimeError(f"{library.name} requires macOS {version}; use a macOS 26 compatible BILINEXT_MPV_LIBRARY")
print(f"Bundled {len(seen)} playback libraries")
