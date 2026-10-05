"""Exercise real Git, Nix builds and GC roots; substitute only systemctl.

Run after cargo build: python3 tests/local-smoke.py target/debug/nixploy
This creates temporary Git/state directories and tiny outputs in the Nix store.
It never runs garbage collection or contacts an application repository.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


worker = str(Path(sys.argv[1]).resolve())
os.environ["GIT_CONFIG_GLOBAL"] = "/dev/null"
os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
tools = json.loads(run(
    "nix", "eval", "--impure", "--json", "--expr",
    'let f = builtins.getFlake ("path:" + toString ./.); '
    'p = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}; '
    'in { shell = p.runtimeShell; coreutils = toString p.coreutils; system = builtins.currentSystem; }',
))

with tempfile.TemporaryDirectory(prefix="nixploy-smoke-") as temporary:
    root = Path(temporary).resolve()
    repo = root / "repo"
    repo.mkdir()
    run("git", "init", "-b", "main", str(repo))
    run("git", "-C", str(repo), "config", "user.name", "fixture")
    run("git", "-C", str(repo), "config", "user.email", "fixture@example.invalid")
    flake = '''{
      outputs = { self }: {
        packages.SYSTEM."server+web" = builtins.derivation {
          name = "nixploy-smoke";
          system = "SYSTEM";
          builder = builtins.appendContext "SHELL" {
            "BASH" = { path = true; };
            "CORE" = { path = true; };
          };
          args = [ "-ec" "CORE/bin/mkdir -p $out/bin; CORE/bin/cp $src/server $out/bin/server; CORE/bin/chmod +x $out/bin/server; exit 0" ];
          src = self.outPath;
        };
      };
    }'''.replace("SYSTEM", tools["system"]).replace("SHELL", tools["shell"]).replace("BASH", str(Path(tools["shell"]).parent.parent)).replace("CORE", tools["coreutils"])
    (repo / "flake.nix").write_text(flake)
    (repo / "flake.lock").write_text(json.dumps({"nodes": {"root": {}}, "root": "root", "version": 7}))
    (repo / "server").write_text("#!/bin/sh\necho one\n")

    def commit():
        run("git", "-C", str(repo), "add", ".")
        run("git", "-C", str(repo), "commit", "-m", "fixture")
        return run("git", "-C", str(repo), "rev-parse", "HEAD")

    first_revision = commit()
    config = root / "config.json"
    state = root / "state"
    config.write_text(json.dumps({
        "app": "smoke", "repository": str(repo), "branch": "main",
        "package": "server+web", "executable": "server", "system": tools["system"],
        "stateDirectory": str(state), "generation": "fixture",
    }))
    bin_dir = root / "bin"
    bin_dir.mkdir()
    systemctl = bin_dir / "systemctl"
    systemctl.write_text('#!/bin/sh\necho "$*" >> "$NIXPLOY_TEST_CALLS"\n'
                         'if [ "$1" = restart ] && [ -e "$NIXPLOY_TEST_FAIL" ]; then exit 1; fi\n')
    systemctl.chmod(0o755)
    calls = root / "calls"
    failure = root / "fail"
    env = os.environ | {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                       "NIXPLOY_TEST_CALLS": str(calls), "NIXPLOY_TEST_FAIL": str(failure)}

    def deploy(success=True):
        result = subprocess.run([worker, str(config)], env=env, text=True, capture_output=True)
        if (result.returncode == 0) != success:
            raise AssertionError(result.stderr)

    deploy()
    active = json.loads((state / "state.json").read_text())["active"]
    assert active["revision"] == first_revision
    first_output = (state / "profile").resolve()
    assert str(state / "roots") in run("nix-store", "--query", "--roots", str(first_output))
    count = calls.read_text().count("restart")
    deploy()
    assert calls.read_text().count("restart") == count

    (repo / "server").write_text("#!/bin/sh\necho two\n")
    second_revision = commit()
    failure.touch()
    deploy(success=False)
    pending = json.loads((state / "state.json").read_text())
    assert pending["active"]["revision"] == first_revision
    assert pending["pending"]["revision"] == second_revision
    failure.unlink()
    deploy()
    second_output = (state / "profile").resolve()
    assert second_output != first_output
    assert len(list((state / "roots").iterdir())) == 1
    assert not list((state / "work").glob("build-result*"))
    assert str(state / "roots") not in run("nix-store", "--query", "--roots", str(first_output))
    assert str(state / "roots") in run("nix-store", "--query", "--roots", str(second_output))

    (repo / "flake.nix").write_text('throw "intentional failure"')
    commit()
    count = calls.read_text().count("restart")
    deploy(success=False)
    assert (state / "profile").resolve() == second_output
    assert calls.read_text().count("restart") == count
    # Missing committed locks must fail before activation too.
    (repo / "flake.nix").write_text(flake)
    (repo / "flake.lock").unlink()
    commit()
    deploy(success=False)
    assert calls.read_text().count("restart") == count

print("Real Git/Nix smoke test passed (systemctl substituted).")
