"""Borrow and hand back the screen N times through the real daemon with display
pixel, and count pixel-link failures.

Each round switches the screen from INFO into CUSTOM and uploads once CUSTOM has
settled — the sequence every pixel-link death on record has followed. With a
one-second settle, 20 rounds here and two end-to-end runs (34 switches in all)
went clean before the next one failed; mixed display never makes this switch at
all, so this only exercises display pixel.

  swiftc -O tests/kb.swift -o /tmp/kb
  launchctl bootout gui/$(id -u)/com.skyler.dp104status
  python3 tests/stress_borrow.py /tmp/kb ./dp104status [rounds]

Needs a working pixel link (check with ./dp104status pixel-test), and may well
kill it: it then stays dead until USB re-enumerates — unplug the keyboard's
cable for a few seconds, or restart the hub or dock it hangs off.
"""
import json, os, subprocess, sys, tempfile, time, signal

KB, BIN = sys.argv[1], os.path.abspath(sys.argv[2])
ROUNDS = int(sys.argv[3]) if len(sys.argv) > 3 else 20
HOME_ = tempfile.mkdtemp(prefix="dp104stress-")
LOG = f"{HOME_}/daemon.log"
env = dict(os.environ, DP104STATUS_HOME=HOME_)


def mode():
    m = subprocess.run([KB, "mode"], capture_output=True, text=True).stdout.strip()
    return int(m) if m.isdigit() else None


def ev(name):
    subprocess.run([BIN, "hook", "claude"], text=True, env=env,
                   input=json.dumps({"hook_event_name": name, "session_id": "S1", "agent_id": "main"}))


def wait_mode(want, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        if mode() == want:
            return True
        time.sleep(0.25)
    return False


def failures():
    return open(LOG).read().count("not answering") if os.path.exists(LOG) else 0


json.dump({"display": "pixel"}, open(f"{HOME_}/config.json", "w"))
subprocess.run([KB, "setmode", "3"], capture_output=True)
daemon = subprocess.Popen([BIN, "daemon"], stdout=open(LOG, "w"), stderr=subprocess.STDOUT, env=env)
time.sleep(3)

clean = 0
for i in range(1, ROUNDS + 1):
    ev("UserPromptSubmit")
    entered = wait_mode(2)
    time.sleep(4.5)                       # settle (3s) + the upload
    ev("SessionEnd")
    back = wait_mode(3)
    ok = entered and back and failures() == 0
    clean += ok
    print(f"  round {i:2}: {'ok' if ok else 'FAILED'}"
          + ("" if ok else f"  (entered CUSTOM={entered}, handed back={back}, link failures={failures()})"),
          flush=True)
    if failures():
        print("  pixel link died — stopping here")
        break
    time.sleep(0.5)

daemon.send_signal(signal.SIGTERM)
daemon.wait(timeout=10)
print(f"\n{clean}/{ROUNDS} rounds clean, {failures()} pixel-link failures")
