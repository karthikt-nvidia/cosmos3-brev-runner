#!/usr/bin/env python3
"""Run the recommended Cosmos3 scene on Brev through the thin clone-and-bootstrap launchable (control plane only).

Status: recommended canonical runner, pending first GPU validation.

The thin launchable (setup script = launchable/setup.sh, text params REPO, REF, BOOTSTRAP and optionally
INPUT_IMAGE_URL, INPUT_IMAGE_SHA256, SCENE_NAME, SEED, DEADLINE_S) clones REPO at REF and runs
scripts/brev-bootstrap.sh, which renders the scene in scene/ at that commit.

usage:
  BREV_API_KEY=... run.py --launchable env-... --repo https://... --ref <40-char sha> \
                          --name NAME --type INSTANCE_TYPE --price USD_PER_HR --cap-min MIN \
                          [--param INPUT_IMAGE_URL=https://...] [--out DIR] [--dry-run]

Never uses brev shell / ssh / exec / copy / port-forward. Always deletes the workspace and verifies it is gone.
Exit codes: 0 RESULT=PASS, 1 RESULT=FAIL or no result, 2 preflight error, 3 hard cap hit or workspace not found.
"""
import argparse, base64, hashlib, json, os, re, shutil, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BOOTSTRAP = "scripts/brev-bootstrap.sh"
ALLOWED = {"INPUT_IMAGE_URL", "INPUT_IMAGE_SHA256", "SCENE_NAME", "SEED", "DEADLINE_S"}  # non-secret only
API = "https://api.brev.dev/devplaneapi.v1.EnvironmentService/"


def parse():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--launchable", required=True, help="thin launchable id (setup script = launchable/setup.sh)")
    p.add_argument("--repo", required=True, help="public git URL of this repo (or your fork)")
    p.add_argument("--ref", required=True, help="40-char commit sha containing the scene to render")
    p.add_argument("--bootstrap", default=BOOTSTRAP)
    p.add_argument("--name", required=True)
    p.add_argument("--type", required=True, dest="itype", help="e.g. g7e.2xlarge (RTX PRO 6000) or g2-standard-8:nvidia-l4:1")
    p.add_argument("--price", required=True, type=float)
    p.add_argument("--cap-min", required=True, type=int)
    p.add_argument("--param", action="append", default=[], help="non-secret override NAME=VALUE; allowed: " + ", ".join(sorted(ALLOWED)))
    p.add_argument("--out", default=os.path.join(HERE, "media", "current"))
    p.add_argument("--dry-run", action="store_true", help="deterministic preflight only; never calls Brev")
    return p.parse_args()


def preflight(a):
    errs, params = [], {"REPO": a.repo, "REF": a.ref, "BOOTSTRAP": a.bootstrap}
    if not re.fullmatch(r"env-[A-Za-z0-9]+", a.launchable): errs.append(f"bad --launchable {a.launchable!r}")
    if not re.fullmatch(r"https://\S+", a.repo): errs.append("--repo must be a public https URL")
    if not re.fullmatch(r"[0-9a-f]{40}", a.ref): errs.append("--ref must be a 40-char commit sha")
    if a.bootstrap.startswith("/") or ".." in a.bootstrap: errs.append("--bootstrap must be repo-relative")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,39}", a.name): errs.append(f"bad --name {a.name!r}")
    if not a.itype.strip(): errs.append("empty --type")
    if not a.price > 0: errs.append("--price must be > 0")
    if not a.cap_min > 0: errs.append("--cap-min must be > 0")
    for kv in a.param:
        k, _, v = kv.partition("=")
        if k not in ALLOWED: errs.append(f"--param {k} not allowed (non-secret scene params only: {', '.join(sorted(ALLOWED))})")
        elif not v: errs.append(f"--param {k} has no value")
        else: params[k] = v
    if "INPUT_IMAGE_URL" in params and not params["INPUT_IMAGE_URL"].startswith("https://"): errs.append("INPUT_IMAGE_URL must be https")
    if not os.environ.get("BREV_API_KEY"): errs.append("BREV_API_KEY is not set")
    if not shutil.which("brev"): errs.append("brev CLI not found on PATH")
    scene = os.path.join(HERE, "scene")
    try:
        json.load(open(os.path.join(scene, "prompt.json")))
    except Exception as e:
        errs.append(f"scene/prompt.json invalid: {e}")
    env = {}
    try:
        for l in open(os.path.join(scene, "scene.env")):
            if "=" in l and not l.startswith("#"): k, _, v = l.strip().partition("="); env[k] = v
        for k in ("SCENE_NAME", "INPUT_IMAGE_URL"):
            if not env.get(k): errs.append(f"scene/scene.env missing {k}")
    except OSError as e:
        errs.append(f"scene/scene.env unreadable: {e}")
    return errs, params, env


def main():
    a = parse()
    errs, params, env = preflight(a)
    psha = ""
    try: psha = hashlib.sha256(open(os.path.join(HERE, "scene", "prompt.json"), "rb").read()).hexdigest()
    except OSError: pass
    print("[preflight] status: recommended canonical runner, pending first GPU validation")
    print(f"[preflight] local scene: name={env.get('SCENE_NAME', '-')} prompt_sha256={psha[:16] or '-'} image={params.get('INPUT_IMAGE_URL', env.get('INPUT_IMAGE_URL', '-'))}")
    print("[preflight] note: the VM renders scene/ as committed at --ref; compare prompt_sha256 with the VM log's [c3] start line")
    print(f"[preflight] brev={shutil.which('brev') or 'MISSING'} BREV_API_KEY={'set' if os.environ.get('BREV_API_KEY') else 'MISSING'}")
    print(f"[preflight] name={a.name} type={a.itype} price=${a.price}/hr cap={a.cap_min} min (max cost ~${a.price * a.cap_min / 60:.2f})")
    shape = " ".join(f"--param {k}={v}" for k, v in params.items())
    print(f"[preflight] $ brev create {a.name} --launchable {a.launchable} --type {a.itype} {shape} --detached")
    if errs:
        for e in errs: print(f"[preflight] ERROR {e}")
        return 2
    print("[preflight] OK")
    if a.dry_run:
        print("[dry-run] not launching"); return 0
    return run(a, params)


DONE_RE = re.compile(r"^\[c3\] \S+ done$|^\[launchable\] .*RESULT=FAIL")


def run(a, params):
    key = os.environ["BREV_API_KEY"]; out = a.out; os.makedirs(out, exist_ok=True)

    def say(m):
        print(f"{time.strftime('%H:%M:%S')} {m}", flush=True)
        with open(os.path.join(out, "run.log"), "a") as f: f.write(m + "\n")

    def red(s): return s.replace(key, "[REDACTED]")

    def rpc(m, body):
        r = urllib.request.Request(API + m, data=json.dumps(body).encode(),
                                   headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        return json.load(urllib.request.urlopen(r, timeout=60))

    def brev(*args, timeout=300):
        return subprocess.run(["brev", *args], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)

    def ws_row():
        try:
            ls = json.loads(brev("ls", "--json").stdout)
            ws = ls.get("workspaces", []) if isinstance(ls, dict) else ls
            return next((x for x in ws if x.get("name") == a.name), None)
        except Exception:
            return "err"

    if isinstance(ws_row(), dict):
        say(f"[run] a workspace named {a.name} already exists; refusing to launch"); return 2

    cmd = ["create", a.name, "--launchable", a.launchable, "--type", a.itype]
    for k, v in params.items(): cmd += ["--param", f"{k}={v}"]
    cmd.append("--detached")
    t0 = time.time(); logtxt = ""; reason = "?"; w = "err"
    try:
        say("$ brev " + " ".join(cmd))
        r = brev(*cmd, timeout=600)
        for l in red(r.stdout + r.stderr).splitlines():
            if l.strip(): say("  " + l.strip()[:160])
        if r.returncode != 0: say(f"[run] create rc={r.returncode}")
        ws_id = None; last = None; last_log = 0
        while True:
            el = time.time() - t0
            w = ws_row()
            if isinstance(w, dict):
                ws_id = w["id"]; st = f'{w["status"]} build={w.get("build_status") or "-"} health={w.get("health_status") or "-"}'
                if st != last: say(f"[brev] t+{int(el // 60)}m{int(el % 60):02d}s {a.name} ({ws_id}) {st}  cost so far ~${el / 3600 * a.price:.2f}"); last = st
            elif w is None and el > 120 and ws_id is None:
                say("[run] workspace not found"); reason = "not-found"; break
            if ws_id and time.time() - last_log > 45:
                last_log = time.time()
                try:
                    items = next((v for v in rpc("ListEnvironmentLogs", {"environmentId": ws_id, "pageParams": {"pageSize": 50}}).values() if isinstance(v, list)), [])
                    parts = []
                    for it in items:
                        lid = it.get("id") or it.get("environmentLogId")
                        g = rpc("GetEnvironmentLog", {"environmentId": ws_id, "environmentLogId": lid})
                        lg = next((v for v in g.values() if isinstance(v, dict)), g); c = lg.get("content", "")
                        try: c = base64.b64decode(c).decode("utf-8", "replace")
                        except Exception: pass
                        parts.append(f"######## {lid}\n{red(c)}")
                    txt = "\n".join(parts)
                    if len(txt) > len(logtxt):
                        logtxt = txt; open(os.path.join(out, "brev_logs.txt"), "w").write(txt)
                        if any(DONE_RE.match(l) for l in txt.splitlines()):
                            reason = "setup-finished"; break  # the log streams while setup runs; stop only on a final line
                except Exception as e:
                    open(os.path.join(out, "poll_err.txt"), "a").write(f"{time.time()} {e}\n")
            if el > a.cap_min * 60:
                say(f"[run] HARD CAP {a.cap_min} min hit"); reason = "cap"; break
            time.sleep(20)
        lines = logtxt.splitlines()
        for l in lines:
            if l.startswith(("[c3]", "[launchable]")) and "| " not in l[:12]: say("  " + l[:230])
        for l in [l for l in lines if l.startswith(("[c3] err|", "[c3] probe|", "[c3] resp|"))][-30:]: say("  " + l[:230])
        i = 0
        while i < len(lines):
            m = re.match(r"^B64BEGIN (\S+) ([0-9a-f]{64})$", lines[i])
            if m:
                j = i + 1; buf = []
                while j < len(lines) and lines[j] != "B64END": buf.append(lines[j].strip()); j += 1
                blob = base64.b64decode("".join(buf)); got = hashlib.sha256(blob).hexdigest(); ok = got == m.group(2)
                if ok: open(os.path.join(out, os.path.basename(m.group(1))), "wb").write(blob)
                say(f"[run] returned {m.group(1)} bytes={len(blob)} sha256={got} {'MATCH' if ok else 'MISMATCH (expected ' + m.group(2) + ')'}")
                i = j
            i += 1
    finally:
        for _ in range(3):
            say(f"$ brev delete {a.name}")
            r = brev("delete", a.name); say("  " + red(r.stdout + r.stderr).strip().replace("\n", " | ")[:200])
            for _ in range(30):
                w = ws_row()
                if w is None: break
                time.sleep(10)
            if w is None: break
        t1 = time.time(); cost = (t1 - t0) / 3600 * a.price
        with open(os.path.join(out, "cost_ledger.txt"), "a") as f:
            f.write(f"{a.name} {a.itype} elapsed={int(t1 - t0)}s price=${a.price}/hr cost=${cost:.3f} reason={reason}\n")
        say(f"[run] {a.name} gone from brev ls: {w is None}. elapsed={int(t1 - t0)}s cost~${cost:.2f}")
        if w is not None: say(f"[run] WARNING: verify manually: brev ls --json | grep {a.name}")
    res = re.search(r"RESULT=(PASS|FAIL)[^\n]*", logtxt)
    say(f"[run] {res.group(0)[:200] if res else 'no RESULT line'}")
    if reason in ("cap", "not-found"): return 3
    return 0 if res and res.group(1) == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
