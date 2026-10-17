#!/usr/bin/env python3
"""Build a research dex JAR from explicitly supplied, externally verified tools."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile
import zipfile

p = argparse.ArgumentParser()
p.add_argument("--java", required=True)
p.add_argument("--javac", required=True)
p.add_argument("--android-jar", required=True)
p.add_argument("--r8-jar", required=True)
p.add_argument("--output", required=True)
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="apt-root-build-") as temp:
    base = pathlib.Path(temp)
    classes, dex = base / "classes", base / "dex"
    classes.mkdir(); dex.mkdir()
    subprocess.run([a.javac, "--release", "8", "-classpath", a.android_jar,
                    "-d", str(classes)] + [str(f) for f in sorted((root / "src").rglob("*.java"))], check=True)
    subprocess.run([a.java, "-cp", a.r8_jar, "com.android.tools.r8.D8", "--min-api", "26",
                    "--lib", a.android_jar, "--output", str(dex)]
                   + [str(f) for f in sorted(classes.rglob("*.class"))], check=True)
    out = pathlib.Path(a.output)
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as jar:
        for f in sorted(dex.glob("*.dex")): jar.write(f, f.name)
    print(json.dumps({"artifact": str(out), "sha256": hashlib.sha256(out.read_bytes()).hexdigest(),
                      "androidJarSHA256": hashlib.sha256(pathlib.Path(a.android_jar).read_bytes()).hexdigest(),
                      "r8SHA256": hashlib.sha256(pathlib.Path(a.r8_jar).read_bytes()).hexdigest()}))
