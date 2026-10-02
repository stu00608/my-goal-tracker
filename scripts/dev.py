#!/usr/bin/env python3
"""Repo checks and native iOS commands; Python standard library only."""

import argparse
import ast
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "ios/GoalTracker.xcodeproj"
DERIVED = ROOT / ".build/ios"
ARTIFACTS = ROOT / ".artifacts"


def run(*args, capture=False):
    args = [str(arg) for arg in args]
    if not capture:
        print("+ " + shlex.join(args), flush=True)
    result = subprocess.run(args, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else None


def choose_device(devices, requested=None):
    phones = [device for runtime, group in devices.items() if ".iOS-" in runtime
              for device in group if device.get("isAvailable")
              and device["name"].startswith("iPhone")]
    if requested:
        phones = [device for device in phones if device["udid"] == requested]
    if not phones:
        raise ValueError("No matching available iPhone Simulator; install a runtime or check --device.")
    return sorted(phones, key=lambda device: (device["name"], device["udid"]))[0]


def test_summary(summary):
    passed = summary.get("passedTests")
    failed = summary.get("failedTests")
    skipped = summary.get("skippedTests", 0)
    if type(passed) is not int or passed < 1 or type(failed) is not int or failed != 0 or skipped != 0:
        raise ValueError("Result is incomplete, failed, empty, or skipped; this is not acceptance.")


def devices():
    return json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json",
                          capture=True))["devices"]


def doctor():
    if sys.platform != "darwin":
        raise ValueError("iOS commands require macOS with full Xcode; repo checks can run elsewhere.")
    developer = os.environ.get("DEVELOPER_DIR") or run("xcode-select", "-p", capture=True).strip()
    print("Developer directory:", developer, flush=True)
    if "CommandLineTools" in developer:
        raise ValueError("Only Command Line Tools selected. Install full Xcode and an iOS runtime.")
    run("xcodebuild", "-version")
    phone = choose_device(devices())
    print("Available Simulator:", phone["name"], phone["udid"])
    print("Toolchain ready; app project:", "present" if PROJECT.is_dir() else "not created")


def check():
    run("git", "diff", "--check")
    run("git", "diff", "--cached", "--check")
    files = run("git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", capture=True)
    for name in set(files.split("\0")) - {""}:
        path = ROOT / name
        if path.is_symlink():
            if not path.exists() or ROOT not in path.resolve().parents:
                raise ValueError("Broken or non-portable repo symlink: " + name)
            continue
        if not path.is_file():
            continue
        if path.suffix in {".md", ".py", ".yml", ".yaml"} or name in {".gitignore", ".editorconfig"}:
            content = path.read_text(encoding="utf-8")
            if content and not content.endswith("\n"):
                raise ValueError("Missing final newline: " + name)
            if any(line.rstrip() != line for line in content.splitlines()):
                raise ValueError("Trailing whitespace: " + name)
            if path.suffix == ".py":
                ast.parse(content, filename=name)
    run("sh", "-n", ROOT / ".githooks/pre-commit")
    run(sys.executable, ROOT / "scripts/check-dev.py")
    print("Repository checks passed. Native app acceptance is separate.")


def xcode(action, device=None):
    if not (PROJECT / "project.pbxproj").is_file():
        raise ValueError("App project not created: ios/GoalTracker.xcodeproj")
    ARTIFACTS.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    result_path = ARTIFACTS / (action + "-" + stamp + ".xcresult")
    args = ["xcodebuild", "-project", PROJECT, "-scheme", "GoalTracker", "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=" + device if device else "generic/platform=iOS Simulator",
            "-derivedDataPath", DERIVED, "-resultBundlePath", result_path,
            "CODE_SIGNING_ALLOWED=NO", action]
    log = ARTIFACTS / (action + "-" + stamp + ".log")
    print("+ " + shlex.join([str(arg) for arg in args]), flush=True)
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen([str(arg) for arg in args], cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            print(line, end="", flush=True)
            output.write(line)
        code = process.wait()
    if code:
        raise subprocess.CalledProcessError(code, args)
    if action == "test":
        summary = json.loads(run("xcrun", "xcresulttool", "get", "test-results", "summary",
                                 "--path", result_path, capture=True))
        result_path.with_suffix(".json").write_text(json.dumps(summary, indent=2) + "\n")
        test_summary(summary)
    print("Evidence:", result_path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["setup", "check", "doctor", "devices", "build", "test", "run", "screenshot"])
    parser.add_argument("--device", help="Exact Simulator UDID; does not erase or delete the device")
    args = parser.parse_args()
    if args.command == "setup":
        for key, value in [("core.hooksPath", ".githooks"), ("pull.ff", "only"), ("fetch.prune", "true")]:
            run("git", "config", "--local", key, value)
        print("Repo-local setup complete; no package installation or global Git changes.")
    elif args.command == "check":
        check()
    elif args.command == "doctor":
        doctor()
    elif args.command == "devices":
        print(json.dumps(devices(), indent=2))
    elif args.command == "build":
        xcode("build")
    else:
        if args.command == "screenshot" and not args.device:
            raise ValueError("screenshot requires --device to identify the session being inspected.")
        phone = choose_device(devices(), args.device)
        udid = phone["udid"]
        print("Using Simulator:", phone["name"], udid, flush=True)
        if args.command == "test":
            xcode("test", udid)
        elif args.command == "run":
            xcode("build", udid)
            if phone["state"] != "Booted":
                run("xcrun", "simctl", "boot", udid)
            run("xcrun", "simctl", "bootstatus", udid, "-b")
            app = DERIVED / "Build/Products/Debug-iphonesimulator/GoalTracker.app"
            with (app / "Info.plist").open("rb") as source:
                bundle_id = plistlib.load(source)["CFBundleIdentifier"]
            run("xcrun", "simctl", "install", udid, app)
            run("xcrun", "simctl", "launch", udid, bundle_id)
            print("Launch succeeded. Execute the changed flow before claiming acceptance.")
        elif args.command == "screenshot":
            ARTIFACTS.mkdir(exist_ok=True)
            path = ARTIFACTS / ("screen-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".png")
            run("xcrun", "simctl", "io", udid, "screenshot", path)
            print("Open and inspect:", path)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("ERROR:", error, file=sys.stderr)
        sys.exit(1)
