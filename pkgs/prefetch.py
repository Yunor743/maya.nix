#!/usr/bin/env python3
"""Project Maya prefetch for NixOS: download, verify and prepare the model files, then emit a run config.

    maya-prefetch --quant Maya-S24 --context 32768 --data-dir /var/lib/maya \
        --emit-config /var/lib/maya/config.json --engine /run/current-system/.../bin/strata

Steps (each skipped when already done):
  1. download the quant's shards from Hugging Face (resumable, verified against the published sha256)
  2. build the pack with upstream tools (iq_pack.py --compat-bf16: index, dense weights, tokenizer)
  3. fetch the vision files (the mmproj and its vocab) and the DFlash2 drafter when they are asked for
  4. write prepared.json and, with --emit-config, the engine run config for serve/server.py

The quant table, the pins and the hashes come from the upstream tree (maya.py is imported, not duplicated),
so what this script fetches is exactly what upstream's installer would fetch.  EXL3 quants are not handled
here (they need their own packer); point --gguf-dir at their folder instead.

No model weights are installed by nix: they live in --data-dir.  A fully prepared
data dir needs no network (the .done marks short-circuit every download).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

SHARE = Path(os.environ.get("MAYA_SHARE") or "")
if not SHARE.is_dir():
    sys.exit("maya-prefetch: MAYA_SHARE is not set (run it through the maya package's wrapper)")

sys.path.insert(0, str(SHARE))
import maya as M  # noqa: E402  upstream installer module: MODELS, DFLASH, PACK_FILES (importing runs nothing)

GGUF_PY = SHARE / "third_party" / "llama.cpp" / "gguf-py"
TOOLS = SHARE / "tools"
PROFILE = SHARE / "data" / "expert-profile-glm.bin"
HF_TOKEN_ENV = ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN")


def say(msg=""):
    print(msg, flush=True)


def fail(msg, hint=None):
    say(f"[maya-prefetch] ERROR: {msg}")
    if hint:
        say(f"  {hint}")
    sys.exit(1)


def ok(msg):
    say(f"[maya-prefetch] ok: {msg}")


def done(path: Path) -> bool:
    return path.with_name(path.name + ".done").exists()


def mark(path: Path):
    path.with_name(path.name + ".done").write_text(time.strftime("%Y-%m-%d %H:%M"), encoding="utf-8")


def token_headers() -> dict:
    tok = ""
    for env in HF_TOKEN_ENV:
        if os.environ.get(env):
            tok = os.environ[env]
    return {"Authorization": f"Bearer {tok}", "User-Agent": "maya-nix"} if tok else {"User-Agent": "maya-nix"}


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def sha_ok(path: Path, want) -> bool:
    """The file's hash against the published one (a list means every published version of that file)."""
    if not want:
        return True
    wanted = [want] if isinstance(want, str) else list(want)
    got = sha256_of(path)
    return got in wanted


def download(url: str, dst: Path, what: str, want=None, token=None) -> None:
    """Resumable download with a progress line, then the published sha256; a .done mark short-circuits.
    `file://` and plain paths are copied (tests, mirrors), like upstream's installer."""
    headers = token_headers()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if dst.exists() and done(dst):
        if not sha_ok(dst, want):
            fail(f"{what}: on disk but its sha256 is not the published one", "delete it and run again")
        ok(f"{what} already present")
        return
    if not url.startswith(("http://", "https://")):
        src = Path(url[7:] if url.startswith("file://") else url)
        if not src.exists():
            fail(f"not found: {src}")
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        if not sha_ok(dst, want):
            dst.unlink()
            fail(f"{what}: its sha256 is not the published one", "put the right file there and run again")
        mark(dst)
        ok(f"{what} copied")
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, method="HEAD", headers=headers)
            total = int(urllib.request.urlopen(req, timeout=60).headers.get("Content-Length", 0))
            break
        except OSError as e:
            if attempt == 4:
                fail(f"cannot reach {url.split('/')[2]} ({e})", "check the network and run again (everything else is kept)")
            time.sleep(5)
    if dst.exists() and total and dst.stat().st_size == total:
        if not sha_ok(dst, want):
            fail(f"{what}: already the right size but its sha256 is not the published one",
                 "delete it and run again")
        mark(dst)
        ok(f"{what} already present")
        return
    part = dst.with_name(dst.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    for attempt in range(30):
        try:
            req = urllib.request.Request(url, headers={**headers, "Range": f"bytes={have}-"})
            with urllib.request.urlopen(req, timeout=120) as r, open(part, "ab" if have else "wb") as f:
                if have and r.status != 206:
                    f.seek(0)
                    f.truncate()
                    have = 0
                last = 0.0
                while True:
                    b = r.read(8 << 20)
                    if not b:
                        break
                    f.write(b)
                    have += len(b)
                    if time.time() - last > 10:
                        last = time.time()
                        size = f"{have / 1e9:6.2f} / {total / 1e9:.2f} GB ({100 * have / total:.0f}%)" if total \
                            else f"{have / 1e6:7.1f} MB"
                        print(f"\r  {what}: {size}   ", end="", flush=True)
            print()
            if not total or have >= total:
                break
        except OSError as e:
            print()
            say(f"  download interrupted ({e}); retrying in 10 s ...")
            time.sleep(10)
    if total and part.stat().st_size != total:
        fail(f"could not finish downloading {dst.name}", "check the network and run again (the download resumes)")
    part.replace(dst)
    if not sha_ok(dst, want):
        fail(f"{dst.name}: the sha256 does not match the published one", "delete it and run again")
    mark(dst)
    ok(f"{what} downloaded")


def run_tool(script: str, *args, env=None) -> None:
    cmd = [sys.executable, str(TOOLS / script), *(str(a) for a in args)]
    say("  > " + " ".join(cmd[2:]))
    r = subprocess.run(cmd, env=env)
    if r.returncode != 0:
        fail(f"{script} failed (exit {r.returncode})")


def stamp_pack(pack: Path, shards: list):
    """The model files' sizes and times into the pack, like upstream (so a stale pack is still visible)."""
    files = [{"name": s.name, "size": s.stat().st_size, "mtime_ns": s.stat().st_mtime_ns} for s in shards]
    try:
        (pack / "sources.json").write_text(json.dumps({"files": files}, indent=1), encoding="utf-8")
    except OSError:
        pass


def main() -> int:
    quants = sorted(q for q, m in M.MODELS.items() if not m.get("format"))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--quant", default="Maya-S24", choices=quants)
    ap.add_argument("--context", type=int, default=32768,
                    choices=M.CONTEXTS + [524288, 1048576])
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--gguf-dir", help="a directory holding the quant's shard files already downloaded")
    ap.add_argument("--draft", default="mtp", choices=list(M.DRAFTS))
    ap.add_argument("--vision", choices=["on", "off"], default="on")
    ap.add_argument("--kv-streaming", choices=["on", "off"], default=M.KV_STREAMING)
    ap.add_argument("--prefill", default="auto")
    ap.add_argument("--parallel", type=int, help="several requests at once (up to 8)")
    ap.add_argument("--emit-config")
    ap.add_argument("--engine")
    ap.add_argument("--vision-exe")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--gpu")
    ap.add_argument("--api-key-file")
    ap.add_argument("--hf-token-file")
    ap.add_argument("--sampling-json")
    ap.add_argument("--mcp-json")
    ap.add_argument("--extra-arg", action="append", default=[])
    ap.add_argument("--dry-run", action="store_true", help="print what would be downloaded and built, then stop")
    a = ap.parse_args()

    spec = M.MODELS[a.quant]
    if not a.gguf_dir and spec.get("format"):
        fail(f"{a.quant} is an {spec['format']} quant: this prefetch only drives the GGUF ones",
             f"put its files in --gguf-dir (upstream's own packer, tools/{spec['format']}_pack.py, needs safetensors)")
    token = Path(a.hf_token_file).read_text(encoding="utf-8").strip() if a.hf_token_file else None

    data = Path(a.data_dir)
    models = data / "models"
    label = a.quant.lower()
    mdir = models / label

    # 1. the model files (the canonical names upstream publishes them under), the drafter, the vision files
    plan = []
    names = [spec["file"].format(i=i, n=spec["shards"]) for i in range(1, spec["shards"] + 1)]
    if a.gguf_dir:
        gdir = Path(a.gguf_dir)
        shards = [gdir / n for n in names]
        ok(f"using GGUF files from {gdir}")
    else:
        shards = [mdir / n for n in names]
        for s in shards:
            plan.append((M.hf_url(spec["repo"], spec["revision"], spec["folder"], s.name), s,
                         f"{a.quant} {s.name}", (spec.get("sha256") or {}).get(s.name)))

    dflash = None
    if a.draft == "dflash2":
        d = M.DFLASH
        dfile = data / "drafter" / d["file"]
        plan.append((M.hf_url(d["repo"], d["revision"], "", d["file"]), dfile, f"drafter {d['file']}",
                     d["sha256"]))
        dflash = dfile

    vision = None
    v = spec.get("vision") if a.vision != "off" else None
    if a.vision != "off" and v is None:
        say(f"[maya-prefetch] no vision files are published for {a.quant}: text only")
    if v is not None and not a.vision_exe:
        fail("--vision on needs --vision-exe (the packaged strata-vision binary)")
    vfiles = {}
    if v is not None:
        vdir = mdir / v["folder"]
        for key in ("mmproj", "vocab"):
            name = v[key]
            vfiles[key] = vdir / name
            plan.append((M.hf_url(v.get("repo") or spec["repo"], v.get("revision") or spec["revision"],
                                  v["folder"], name), vfiles[key], f"vision {name}",
                         (v.get("sha256") or {}).get(name)))

    if a.dry_run:
        say(f"[maya-prefetch] plan for {a.quant} (context {a.context}, draft {a.draft}, "
            f"vision {'on' if v else 'off'}):")
        for url, dst, what, want in plan:
            say(f"  {what}\n    {url}\n    into {dst}" + (f"\n    sha256 {want}" if want else ""))
        if not plan:
            say("  (nothing to download)")
        say(f"  then: the pack in {mdir}/pack with tools/iq_pack.py --compat-bf16")
        return 0

    for url, dst, what, want in plan:
        download(url, dst, what, want=want, token=token)

    for s in shards:
        if not s.exists():
            fail(f"missing {s}")
        if not sha_ok(s, (spec.get("sha256") or {}).get(s.name)):
            fail(f"{s.name}: its sha256 is not the published one", "delete it and run again")

    # 2. the pack (upstream's builder; it lives inside the model folder, so the dir must be writable)
    pack = mdir / "pack"
    missing_pack = [f for f in M.PACK_FILES if not (pack / f).exists()]
    if missing_pack:
        say("[maya-prefetch] building the pack (iq_pack.py --compat-bf16, a few minutes) ...")
        run_tool("iq_pack.py", "--gguf", shards[0], "--out", pack, "--compat-bf16",
                 env=dict(os.environ, STRATA_GGUF_PY=str(GGUF_PY)))
        missing_pack = [f for f in M.PACK_FILES if not (pack / f).exists()]
        if missing_pack:
            fail(f"the pack builder did not write {pack / missing_pack[0]}")
        stamp_pack(pack, shards)
        ok(f"pack built: {pack}")
    else:
        if not (pack / "sources.json").exists():
            stamp_pack(pack, shards)
        ok(f"pack already built: {pack}")

    # 3. what the downloads were for
    if dflash is not None and not dflash.exists():
        fail(f"missing {dflash}")
    if v is not None:
        vision = {"exe": a.vision_exe, "mmproj": str(vfiles["mmproj"]), "model": str(vfiles["vocab"]),
                  "gpu": True}

    # 4. the engine's arguments and the run config (the schema upstream's setup writes)
    args = ["--glm-pack", str(pack), "--max-context", str(a.context), "--prefill", a.prefill,
            "--kv-streaming", a.kv_streaming]
    if PROFILE.exists():
        args += ["--expert-profile", str(PROFILE)]
    if a.parallel:
        args += ["--parallel", str(a.parallel)]
    if dflash is not None:
        args += ["--dflash", str(dflash)]
    args += a.extra_arg

    prepared = {"args": args, "tokenizer": str(pack / "tokenizer"), "model_name": M.MODEL_NAME,
                "context": a.context, "draft": a.draft, "vision": bool(vision)}
    (data / f"prepared-{label}.json").write_text(json.dumps(prepared, indent=1), encoding="utf-8")
    ok(f"prepared: pack={pack} context={a.context} draft={a.draft} vision={'on' if vision else 'off'}")

    if a.emit_config:
        if not a.engine:
            fail("--emit-config needs --engine")
        cfg = {"exe": a.engine, "args": args, "cwd": str(data), "tokenizer": prepared["tokenizer"],
               "model_name": M.MODEL_NAME, "sampling": dict(M.SAMPLING), "reasoning_effort": M.EFFORT,
               "lib_dirs": [], "port": a.port, "log": str(data / f"engine-{label}.log")}
        if a.host:
            cfg["host"] = a.host
        if a.gpu:
            cfg["gpu"] = a.gpu
        if a.api_key_file:
            cfg["api_key"] = Path(a.api_key_file).read_text(encoding="utf-8").strip()
        if a.sampling_json:
            cfg["sampling"] = json.loads(Path(a.sampling_json).read_text(encoding="utf-8"))
        if a.mcp_json:
            cfg["mcp_servers"] = json.loads(Path(a.mcp_json).read_text(encoding="utf-8"))
        if vision:
            cfg["vision"] = vision
        out = Path(a.emit_config)
        out.write_text(json.dumps(cfg, indent=1), encoding="utf-8")
        if a.api_key_file:
            os.chmod(out, stat.S_IRUSR | stat.S_IWUSR)
        ok(f"config written: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
