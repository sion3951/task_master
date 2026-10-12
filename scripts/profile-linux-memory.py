#!/usr/bin/env python3
"""Measure Linux RSS, PSS and private RAM during an isolated local app run."""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time


def measure(binary, mode):
    with tempfile.TemporaryDirectory(prefix="task-master-memory-") as root:
        env = os.environ.copy()
        for key, name in (("XDG_CONFIG_HOME", "config"),
                          ("XDG_CACHE_HOME", "cache"),
                          ("XDG_DATA_HOME", "data")):
            directory = Path(root) / name
            directory.mkdir()
            env[key] = str(directory)
        # systemctl talks to the real user manager even with temporary XDG
        # paths. Keep this desktop standalone and never refresh/restart the
        # user's installed persistence unit. Profile its binary separately.
        commands = Path(root) / "commands"
        commands.mkdir()
        systemctl = commands / "systemctl"
        systemctl.write_text("#!/bin/sh\nprintf '%s\\n' disabled\nexit 1\n")
        systemctl.chmod(0o700)
        env["PATH"] = str(commands) + os.pathsep + env.get("PATH", "")
        args = [str(Path(binary).resolve())]
        args += ["--smoke"] if mode == "desktop" else ["--persistence-service"]
        # Files avoid pipe backpressure while collecting measurements.
        with tempfile.TemporaryFile(mode="w+") as log:
            process = subprocess.Popen(args, env=env, stdout=log, stderr=log)
            started = time.monotonic()
            readings = []
            try:
                while process.poll() is None:
                    elapsed = time.monotonic() - started
                    if (mode == "service" and elapsed >= 4) or elapsed >= 15:
                        process.send_signal(signal.SIGTERM)
                        break
                    try:
                        rollup = Path(f"/proc/{process.pid}/smaps_rollup").read_text()
                        values = {}
                        for line in rollup.splitlines():
                            fields = line.split()
                            if len(fields) >= 2 and fields[1].isdigit():
                                values[fields[0].rstrip(":")] = int(fields[1])
                        readings.append({
                            "seconds": elapsed,
                            "rss_kib": values["Rss"],
                            "pss_kib": values["Pss"],
                            "private_kib": values["Private_Clean"] + values["Private_Dirty"],
                        })
                    except (FileNotFoundError, ProcessLookupError):
                        pass
                    time.sleep(0.1)
                process.wait(timeout=10)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            log.seek(0)
            output = log.read()
    steady = [reading for reading in readings if 2 <= reading["seconds"] < 3.8]
    if process.returncode != 0 or not steady:
        raise RuntimeError(f"{binary} {mode} failed ({process.returncode}):\n{output}")
    if mode == "desktop":
        samples = re.search(r"Smoke complete \| (\d+) samples", output)
        if not samples or int(samples.group(1)) == 0:
            raise RuntimeError(f"{binary} collected no samples; discard this measurement:\n{output}")
    return {
        "binary": binary,
        "mode": mode,
        "steady_mib": {
            key.removesuffix("_kib"): round(sum(r[key] for r in steady) / len(steady) / 1024, 2)
            for key in ("rss_kib", "pss_kib", "private_kib")
        },
        "peak_rss_mib": round(max(r["rss_kib"] for r in readings) / 1024, 2),
        "exit_code": process.returncode,
        "output": output,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binaries", nargs="+")
    parser.add_argument("--mode", choices=("desktop", "service", "both"), default="both")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    modes = ("desktop", "service") if args.mode == "both" else (args.mode,)
    results = [measure(binary, mode) for binary in args.binaries for mode in modes]
    report = json.dumps(results, indent=2)
    if args.output:
        args.output.write_text(report + "\n")
    print(report)


if __name__ == "__main__":
    main()
