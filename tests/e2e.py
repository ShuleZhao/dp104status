"""End-to-end test against the real keyboard. It flips the screen between modes
for about two minutes and puts it back on INFO with your texts at the end.

  swiftc -O tests/kb.swift -o /tmp/kb
  launchctl bootout gui/$(id -u)/com.skyler.dp104status   # the daemon under test needs the keyboard to itself
  python3 tests/e2e.py /tmp/kb ./dp104status

Every check reads the mode register or the text slots back from the keyboard,
so nothing depends on watching the screen. The daemon under test runs on its
own state directory (DP104STATUS_HOME), out of reach of live hooks.
"""
import json, os, subprocess, sys, tempfile, time, signal
KB, BIN = sys.argv[1], os.path.abspath(sys.argv[2])
HOME_ = tempfile.mkdtemp(prefix="dp104e2e-")
LOG = f"{HOME_}/daemon.log"
env = dict(os.environ, DP104STATUS_HOME=HOME_)
MODES = {0:"OFF",1:"TYPE",2:"CUSTOM",3:"INFO",4:"SPARK",5:"AUDIO",6:"SCROLL"}
results = []

def sh(*a): return subprocess.run(a, capture_output=True, text=True).stdout.strip()
def mode():
    m = sh(KB, "mode"); return int(m) if m.isdigit() else None
def setmode(n): sh(KB, "setmode", str(n))
def texts(): return sh(KB, "texts")
def ev(name, sess="T1", product="claude"):
    subprocess.run([BIN, "hook", product], input=json.dumps(
        {"hook_event_name": name, "session_id": sess, "agent_id": "main"}), text=True, env=env)
def wait_mode(want, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        if mode() == want: return True
        time.sleep(0.3)
    return False
def log(): return open(LOG).read() if os.path.exists(LOG) else ""
def check(label, ok, detail=""):
    results.append((label, ok))
    print(f"  {'✅' if ok else '❌'} {label}" + (f"   [{detail}]" if detail and not ok else ""), flush=True)

daemon = None
def start(display):
    global daemon
    os.makedirs(HOME_, exist_ok=True)
    for f in ("state.json", "takeover.json"):
        try: os.remove(f"{HOME_}/{f}")
        except FileNotFoundError: pass
    json.dump({"display": display}, open(f"{HOME_}/config.json", "w"))
    daemon = subprocess.Popen([BIN, "daemon"], stdout=open(LOG, "a"), stderr=subprocess.STDOUT, env=env)
    time.sleep(2)
def stop(sig=signal.SIGTERM):
    daemon.send_signal(sig); daemon.wait(timeout=10)

open(LOG, "w").close() if os.path.exists(HOME_) else None
os.makedirs(HOME_, exist_ok=True); open(LOG, "w").close()
orig_texts = texts()
setmode(3)

# Scenarios A–G need a working pixel link (they expect a borrow to land on CUSTOM).
# H holds whether the link works or not — and is most telling when it doesn't.
link_ok = "sendFrame   : OK" in subprocess.run([BIN, "pixel-test"], capture_output=True, text=True).stdout
if not link_ok:
    print("\n像素链路不通：A–G 需要它，先拔插键盘再重跑。这次只跑 H。")

def scenarios_a_to_g():
  global daemon
  print("\nA. 屏幕在 INFO：借用，然后原样归还")
  start("mixed")
  ev("UserPromptSubmit")
  check("agent 开始 → 切到 CUSTOM", wait_mode(2), f"mode={mode()}")
  check("借用记录已落盘", os.path.exists(f"{HOME_}/takeover.json"))
  ev("SessionEnd")
  check("全部空闲 → 还回 INFO", wait_mode(3), f"mode={mode()}")
  check("借用记录已清除", not os.path.exists(f"{HOME_}/takeover.json"))

  print("\nB. 借用期间你按了切换键")
  ev("UserPromptSubmit")
  check("借用 → CUSTOM", wait_mode(2))
  setmode(4); time.sleep(4.5)
  check("你切到 SPARK 后不被抢回", mode() == 4, f"mode={mode()}")
  check("日志记下了放手", "you switched the screen to SPARK" in log())
  ev("PostToolUse"); time.sleep(4)
  check("agent 仍在忙也不再借用（已放手）", mode() == 4, f"mode={mode()}")
  ev("SessionEnd"); time.sleep(1.5)
  ev("UserPromptSubmit")
  check("空闲过一次后，下一轮从 SPARK 借用", wait_mode(2))
  ev("SessionEnd")
  check("还回的是你新选的 SPARK", wait_mode(4), f"mode={mode()}")

  print("\nC. 屏幕在 CUSTOM：常驻，从不切走")
  setmode(2); time.sleep(4.5)
  check("切到 CUSTOM → 接管为仪表盘", "idle — dashboard" in log())
  ev("UserPromptSubmit"); time.sleep(3)
  check("agent 工作时模式不变（仍是 CUSTOM）", mode() == 2, f"mode={mode()}")
  ev("SessionEnd"); time.sleep(3)
  check("空闲后仍是 CUSTOM", mode() == 2, f"mode={mode()}")
  setmode(3); time.sleep(4.5)
  check("你切走到 INFO → 留给你", mode() == 3 and "you switched the screen to INFO" in log(), f"mode={mode()}")

  print("\nD. SIGTERM 时借着屏幕：先归还再退出")
  ev("UserPromptSubmit"); wait_mode(2)
  stop(signal.SIGTERM)
  check("退出后还回 INFO", wait_mode(3, 4), f"mode={mode()}")
  check("没有遗留借用记录", not os.path.exists(f"{HOME_}/takeover.json"))

  print("\nE. 崩溃（kill -9）后重启：先把屏幕还回去")
  start("mixed"); ev("UserPromptSubmit")
  check("借用 → CUSTOM", wait_mode(2))
  stop(signal.SIGKILL)
  check("崩溃后借用记录还在", os.path.exists(f"{HOME_}/takeover.json"))
  daemon = subprocess.Popen([BIN, "daemon"], stdout=open(LOG, "a"), stderr=subprocess.STDOUT, env=env)
  time.sleep(3)
  check("新进程启动即归还遗留借用", "handed back a screen left borrowed by a previous run" in log())
  ev("SessionEnd")
  check("最终回到 INFO", wait_mode(3), f"mode={mode()}")
  stop()

  print("\nF. display=text：借 SCROLL，还文字")
  start("text")
  ev("UserPromptSubmit")
  check("切到 SCROLL", wait_mode(6), f"mode={mode()}")
  t = texts()
  check("slot 0 是状态，其余清空", t == '["CLAUDE WORK", "", "", "", ""]', t)
  ev("SessionEnd")
  check("还回 INFO", wait_mode(3), f"mode={mode()}")
  check("你的文字原样回来", texts() == orig_texts, texts())
  stop()

  print("\nG. 整个过程没有一次误判拔线")
  check("日志里没有 'keyboard unplugged'", "keyboard unplugged" not in log())
  check("日志里没有 'not answering'", "not answering" not in log())

if link_ok:
    scenarios_a_to_g()

print("\nH. 屏幕在 CUSTOM 就绝不切走——像素链路不通时也一样")
start("mixed")
setmode(1)                                    # 跟当初出 bug 时一样，从 TYPE 开始
ev("UserPromptSubmit"); time.sleep(4)
setmode(2)                                    # 按到 CUSTOM
seen = []
end = time.time() + 9
while time.time() < end:
    seen.append(mode()); time.sleep(0.4)
check("按到 CUSTOM 后 9 秒内一直停在 CUSTOM", all(m == 2 for m in seen), f"观察到 {sorted(set(seen))}")
setmode(3)                                    # 再按一下：CUSTOM 之后是 INFO
seen = []
end = time.time() + 6
while time.time() < end:
    seen.append(mode()); time.sleep(0.4)
check("再按一下到达 INFO 并停留", all(m == 3 for m in seen), f"观察到 {sorted(set(seen))}")
ev("SessionEnd"); time.sleep(1.5)
stop()
check("H 期间没有误判拔线", "keyboard unplugged" not in log())

passed = sum(ok for _, ok in results)
print(f"\n{passed}/{len(results)} 通过")
