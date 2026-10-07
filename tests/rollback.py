# Shared fixture and initial successful deployment come from readiness.nix.

# Three failures during the grace period must not immediately fail startup.
machine.succeed("echo unhealthy > /var/lib/readiness/mode")
started = time.monotonic()
machine.fail("systemctl restart nixploy-app-demo.service")
elapsed = time.monotonic() - started
assert 5 <= elapsed < 12, elapsed
machine.succeed("systemctl stop nixploy-app-demo.service")
machine.succeed("journalctl -u nixploy-app-demo | grep 'failure threshold reached (3 probes)'")
machine.succeed("echo ready > /var/lib/readiness/mode; systemctl start nixploy-app-demo.service")

# The broken package fails readiness; the previous package still passes it.
machine.succeed("sed -i 's/BROKEN = False/BROKEN = True/' /srv/app/server")
machine.succeed("git -C /srv/app commit -am broken")
machine.fail("systemctl start nixploy-update-demo.service")
failed = state()["failed"]
assert failed is not None
assert state()["active"] == first
assert state()["pending"] is None
assert state()["recovery"] is None
assert machine.succeed("readlink /var/lib/nixploy/demo/profile").strip() == first["output"]
machine.succeed("systemctl is-active nixploy-app-demo.service")
machine.succeed("test $(find /var/lib/nixploy/demo/roots -type l | wc -l) -eq 2")

# Ordinary updates do not reattempt the rejected revision or restart the fallback.
pid = machine.succeed("systemctl show -p MainPID --value nixploy-app-demo")
machine.succeed("systemctl start nixploy-update-demo.service")
assert pid == machine.succeed("systemctl show -p MainPID --value nixploy-app-demo")
assert state()["failed"] == failed
machine.succeed("nix-store --gc")
machine.succeed(f"test -x {first['output']}/bin/server; test -x {failed['output']}/bin/server")

# Suppression and fallback selection survive reboot.
machine.shutdown()
machine.start()
machine.wait_for_unit("nixploy-app-demo.service")
machine.succeed("systemctl stop nixploy-update-demo.timer")
machine.succeed("systemctl start nixploy-update-demo.service")
assert state()["failed"] == failed
assert machine.succeed("readlink /var/lib/nixploy/demo/profile").strip() == first["output"]

# Explicit retry is queued through the CLI and uses the normal updater context.
machine.succeed("echo repair > /var/lib/readiness/mode")
machine.succeed("nixploy app retry demo")
machine.wait_until_succeeds("jq -e ' .failed == null and .pending == null' /var/lib/nixploy/demo/state.json")
assert state()["failed"] is None
assert state()["active"]["output"] == failed["output"]
assert state()["pending"] is None

# A later failed revision is suppressed, but another commit proceeds normally.
machine.succeed("echo '# another broken revision' >> /srv/app/server; git -C /srv/app commit -am broken-again")
machine.succeed("echo ready > /var/lib/readiness/mode")
machine.fail("systemctl start nixploy-update-demo.service")
# Both broken packages now fail. Recovery stays durable until the environment is repaired.
assert state()["recovery"] is not None
machine.succeed("echo repair > /var/lib/readiness/mode; mv /srv/app /srv/offline")
machine.fail("systemctl start nixploy-update-demo.service")  # Git is unavailable after recovery.
assert state()["recovery"] is None
machine.succeed("systemctl is-active nixploy-app-demo.service")
machine.succeed("mv /srv/offline /srv/app")
machine.succeed("sed -i 's/BROKEN = True/BROKEN = False/' /srv/app/server")
machine.succeed("git -C /srv/app commit -am fixed; echo ready > /var/lib/readiness/mode")
machine.succeed("systemctl start nixploy-update-demo.service")
head = machine.succeed("git -C /srv/app rev-parse HEAD").strip()
assert state()["active"]["revision"] == head
assert state()["pending"] is None
assert state()["recovery"] is None
