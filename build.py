#!/usr/bin/env python3
"""Sign mod/ and zip it as an HMG-API package, on the Mac (the key never goes to the car).

    ./build.py keygen <key>   new author key: <key> (base64 PKCS#8) and <key>.pub (base64 X.509)
    ./build.py <key> <hmg-api checkout>
                              릴리즈 파일 (GitHub 릴리즈에 올리는 것, dist/ 바로 아래):
                                dist/<id>-v<version>-hmgapi-usb.zip  (HMGAPI/updates/<id>-v<version>.zip inside)
                                dist/<id>-v<version>-nemesis-usb.zip (NEMESIS.data + packages/ inside)
                                dist/SHA256SUMS                      (위 두 파일만의 체크섬)
                              중간 산출물 (릴리즈에 올리지 않음, dist/extra/):
                                dist/extra/<id>-v<version>.hmgapi.zip          서명된 모드 본체 (위 두 파일 안에 들어감)
                                dist/extra/<id>-v<version>-nemesis-package.zip NEMESIS 패키지 스토어 등록용
                              NEMESIS 파일은 checkout의 tools/mknemesismod.sh가 만듦 (unzip, zip 필요)

Same files and manifest as `hmgapi.engine.Signing sign`: SHA256withECDSA over
META-HMGAPI/manifest.json, the uuid derived from the public key, so keys made by
either tool work with both. Needs openssl.
"""
import base64, hashlib, json, os, shutil, subprocess, sys, tempfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "mod")
DIST = os.path.join(HERE, "dist")
# 릴리즈에 올리지 않는 중간 산출물 (서명된 모드 본체, 패키지 스토어용 파일)
EXTRA = os.path.join(DIST, "extra")
META = "META-HMGAPI"
# what NEMESIS's store shows as compatible: only what the mod was tested on. A glob of
# ro.build.product, and the unit's /system/onebin folder name. mod.json has no "system",
# so HMG-API itself doesn't refuse other cars.
# 이 포크의 대상: 쏘나타 하이브리드(DN8 HEV) 국내형 260902 펌웨어
#   ro.build.product = DN823HEV.KOR.0000.V039.001.260902, onebin 폴더 = dn823hev_kr
TESTED_OS = "DN823HEV.KOR.*.260902"
TESTED_MODELS = "dn823hev_kr"


def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout


def der_of(path):
    with open(path) as f:
        return base64.b64decode(f.read().strip())


def uuid_of(pub_der):
    d = bytearray(hashlib.sha256(pub_der).digest())
    d[6] = (d[6] & 15) | 128
    d[8] = (d[8] & 63) | 128
    h = d[:16].hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def keygen(key):
    for p in (key, key + ".pub"):
        if os.path.exists(p):
            sys.exit(f"{p} exists; not overwriting a key")
    pem = openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256")
    priv = openssl("pkcs8", "-topk8", "-nocrypt", "-outform", "DER", data=pem)
    pub = openssl("pkey", "-pubout", "-outform", "DER", data=pem)
    fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(base64.b64encode(priv).decode() + "\n")
    with open(key + ".pub", "w") as f:
        f.write(base64.b64encode(pub).decode() + "\n")
    print(f"wrote {key} and {key}.pub, uuid: {uuid_of(pub)}")


def files_of(root):
    out = []
    for dirpath, dirs, names in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        dirs[:] = [d for d in dirs if not (rel == "." and d == META)]
        for n in names:
            if n == ".DS_Store" or (rel == "." and n == ".disabled"):
                continue
            out.append(n if rel == "." else f"{rel}/{n}")
    return sorted(out)


def swap_in_zip(path, name, change):
    """Rewrite one member of a zip, keeping the others and every member's attributes."""
    with zipfile.ZipFile(path) as z:
        items = [(i, z.read(i)) for i in z.infolist()]
    with zipfile.ZipFile(path, "w") as z:
        for i, d in items:
            z.writestr(i, change(d) if i.filename == name else d)


def tested_on(descriptor):
    """The tool writes os and models as "any"; a mod with a "system" would need this changed."""
    for k, v in (("os", TESTED_OS), ("models", TESTED_MODELS)):
        any_ = f'{k}="any"'.encode()
        if descriptor.count(any_) != 1:
            sys.exit(f"NEMESIS.data has no {k}=\"any\" to replace")
        descriptor = descriptor.replace(any_, f'{k}="{v}"'.encode())
    return descriptor


def nemesis_usb(signed, mod, hmgapi):
    """HMG-API's own tool wraps the signed zip; it names the results <id>-<version>-nemesis[-package].zip."""
    tool = os.path.join(os.path.abspath(hmgapi), "tools", "mknemesismod.sh")
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(["sh", tool, os.path.abspath(signed), t], check=True, capture_output=True)
        out = os.path.join(DIST, f"{mod['id']}-v{mod['version']}-nemesis-usb.zip")
        store = os.path.join(EXTRA, f"{mod['id']}-v{mod['version']}-nemesis-package.zip")
        shutil.move(os.path.join(t, f"{mod['id']}-{mod['version']}-nemesis.zip"), out)
        shutil.move(os.path.join(t, f"{mod['id']}-{mod['version']}-nemesis-package.zip"), store)
    swap_in_zip(store, "NEMESIS.data", tested_on)
    packed = open(store, "rb").read()
    swap_in_zip(out, f"packages/hmgapi.{mod['id']}.zip", lambda _: packed)
    return out, store


def build(key, hmgapi):
    pub_path = key + ".pub"
    if not os.path.isfile(pub_path):
        sys.exit(f"no {pub_path}")
    pub = der_of(pub_path)
    mod = json.load(open(os.path.join(MOD, "mod.json")))
    files = {n: hashlib.sha256(open(os.path.join(MOD, n), "rb").read()).hexdigest() for n in files_of(MOD)}
    manifest = json.dumps({
        "format": 1, "id": mod["id"], "version": mod["version"],
        "uuid": uuid_of(pub), "key": base64.b64encode(pub).decode(), "files": files,
    }, indent=2).encode() + b"\n"

    with tempfile.TemporaryDirectory() as tmp:
        kpem = os.path.join(tmp, "k.pem")
        fd = os.open(kpem, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(openssl("pkey", "-inform", "DER", data=der_of(key)))
        sig = openssl("dgst", "-sha256", "-sign", kpem, data=manifest)
        # check against the public key the manifest carries, as the engine will
        ppem = os.path.join(tmp, "p.pem")
        sigf = os.path.join(tmp, "sig")
        open(ppem, "wb").write(openssl("pkey", "-pubin", "-inform", "DER", data=pub))
        open(sigf, "wb").write(sig)
        openssl("dgst", "-sha256", "-verify", ppem, "-signature", sigf, data=manifest)

    os.makedirs(EXTRA, exist_ok=True)
    out = os.path.join(EXTRA, f"{mod['id']}-v{mod['version']}.hmgapi.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{META}/manifest.json", manifest)
        z.writestr(f"{META}/signature", base64.b64encode(sig).decode() + "\n")
        for n in files:
            info = zipfile.ZipInfo.from_file(os.path.join(MOD, n), n)
            if n.endswith(".sh"):
                info.external_attr = 0o755 << 16
            z.writestr(info, open(os.path.join(MOD, n), "rb").read(), zipfile.ZIP_DEFLATED)
    usb = os.path.join(DIST, f"{mod['id']}-v{mod['version']}-hmgapi-usb.zip")
    with zipfile.ZipFile(usb, "w", zipfile.ZIP_STORED) as z:
        z.write(out, f"HMGAPI/updates/{mod['id']}-v{mod['version']}.zip")
    nemesis_out, store = nemesis_usb(out, mod, hmgapi)
    release_files = [usb, nemesis_out]
    write_checksums(release_files)
    print(f"signed {mod['id']} {mod['version']}: {len(files)} files, uuid {uuid_of(pub)}")
    print("릴리즈 파일:", *release_files, os.path.join(DIST, "SHA256SUMS"), sep="\n  ")
    print("중간 산출물 (릴리즈에 올리지 않음):", out, store, sep="\n  ")


def write_checksums(release_files):
    """dist/SHA256SUMS: 릴리즈에 올리는 파일만 (sha256sum -c 형식)."""
    lines = []
    for path in sorted(release_files):
        with open(path, "rb") as f:
            lines.append(f"{hashlib.sha256(f.read()).hexdigest()}  {os.path.basename(path)}\n")
    with open(os.path.join(DIST, "SHA256SUMS"), "w") as f:
        f.writelines(lines)


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "keygen":
        keygen(a[1])
    elif len(a) == 2:
        build(a[0], a[1])
    else:
        sys.exit(__doc__)
