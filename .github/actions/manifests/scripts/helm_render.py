"""Templates a Flux HelmRelease the way helm-controller would, for the manifest report.

render(release, objs, tmp, key) -> (resources by key, notes). objs is the render the HelmRelease came
from (keyed like manifest-report.py), which is where its HelmRepository and any valuesFrom
ConfigMap live. Covers what a cluster repo typically uses: a chart from an https or OCI
HelmRepository, or chartRef to an OCIRepository; values merged from valuesFrom ConfigMaps (and
Secrets, when the render has them) under spec.values; the Flux default release name; and
postRenderers' kustomize patches and images. CRDs (the chart's crds/ dir) are left out, as are
lookup() results, since there is no cluster. Secret values are redacted, and chart-version
labels and checksum/* annotations dropped, so a chart bump shows only what really changes. helm
and yq must be on PATH; HELM_KUBE_VERSION (env) sets --kube-version.
"""

import base64
import json
import os
import shutil
import subprocess
from pathlib import Path


def run(args, **kwargs):
    return subprocess.run(
        args, capture_output=True, text=True, encoding="utf-8", check=True, **kwargs
    ).stdout


def yaml_docs(text):
    """Every YAML document in text as Python objects (yq converts; null docs dropped)."""
    out = run([shutil.which("yq") or "yq", "-o=json", "-I=0", "."], input=text)
    return [
        json.loads(line)
        for line in out.splitlines()
        if line.strip() not in ("", "null")
    ]


def merge(into, other):
    """Helm-style deep merge: maps merge key by key, anything else replaces."""
    for k, v in other.items():
        if isinstance(v, dict) and isinstance(into.get(k), dict):
            merge(into[k], v)
        else:
            into[k] = v
    return into


def lookup(objs, kind, ns, name):
    return objs.get(f"{kind}/{ns + '/' if ns else ''}{name}")


def values(release, objs, notes):
    spec, ns = release.get("spec", {}), release["metadata"].get("namespace")
    result = {}
    for ref in spec.get("valuesFrom", []):
        kind, name = ref.get("kind"), ref.get("name")
        key = ref.get("valuesKey", "values.yaml")
        src = lookup(objs, kind, ns, name)
        text = None
        if src and kind == "ConfigMap":
            text = src.get("data", {}).get(key)
        elif src and kind == "Secret":
            text = src.get("stringData", {}).get(key)
            if text is None and key in src.get("data", {}):
                text = base64.b64decode(src["data"][key]).decode("utf-8")
        if text is None:
            if not ref.get("optional"):
                notes.append(
                    f"values from {kind} `{name}` aren't in the repo, so not included"
                )
            continue
        if ref.get("targetPath"):
            notes.append(f"valuesFrom `{name}` targetPath isn't applied")
            continue
        for doc in yaml_docs(text):
            if isinstance(doc, dict):
                merge(result, doc)
    return merge(result, spec.get("values") or {})


def chart_args(release, objs, notes):
    """The chart reference and version flags for helm template, or None if unsupported."""
    spec, ns = release.get("spec", {}), release["metadata"].get("namespace")
    if "chartRef" in spec:
        ref = spec["chartRef"]
        src = lookup(objs, ref.get("kind"), ref.get("namespace", ns), ref.get("name"))
        if ref.get("kind") != "OCIRepository" or not src:
            notes.append(
                f"chartRef {ref.get('kind')} `{ref.get('name')}` isn't in this render"
            )
            return None
        url, oref = src["spec"]["url"], src["spec"].get("ref", {})
        if oref.get("digest"):
            return [f"{url}@{oref['digest']}"]
        version = oref.get("tag") or oref.get("semver")
        return [url] + (["--version", version] if version else [])
    chart = spec.get("chart", {}).get("spec", {})
    src_ref = chart.get("sourceRef", {})
    src = lookup(
        objs, src_ref.get("kind"), src_ref.get("namespace", ns), src_ref.get("name")
    )
    if src_ref.get("kind") != "HelmRepository" or not src:
        notes.append(
            f"chart source {src_ref.get('kind')} `{src_ref.get('name')}` isn't in this render"
        )
        return None
    if src["spec"].get("secretRef"):
        notes.append(f"HelmRepository `{src_ref.get('name')}` needs credentials")
        return None
    url = src["spec"]["url"].rstrip("/")
    version = ["--version", chart["version"]] if chart.get("version") else []
    if src["spec"].get("type") == "oci":
        return [f"{url}/{chart['chart']}"] + version
    return [chart["chart"], "--repo", url] + version


def chart_version(chart_dir):
    """The version in an unpacked chart's Chart.yaml (the resolved one, for a range)."""
    for doc in yaml_docs((chart_dir / "Chart.yaml").read_text(encoding="utf-8")):
        if isinstance(doc, dict) and doc.get("version"):
            return str(doc["version"])
    return None


def post_render(manifest, release, tmp):
    """Applies postRenderers' kustomize patches and images, as helm-controller does."""
    steps = [
        p["kustomize"]
        for p in release["spec"].get("postRenderers", [])
        if "kustomize" in p
    ]
    for step in steps:
        work = Path(tmp, "post-render")
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir()
        (work / "all.yaml").write_text(manifest, encoding="utf-8")
        kustomization = {"resources": ["all.yaml"]}
        for field in ("patches", "images"):
            if step.get(field):
                kustomization[field] = step[field]
        (work / "kustomization.yaml").write_text(
            json.dumps(kustomization), encoding="utf-8"
        )
        manifest = run([shutil.which("kubectl") or "kubectl", "kustomize", str(work)])
    return manifest


def render(release, objs, tmp, key):
    """(resources by key, notes) for one HelmRelease; resources is None if it can't render."""
    notes = []
    spec, meta = release.get("spec", {}), release["metadata"]
    args = chart_args(release, objs, notes)
    if args is None:
        return None, notes
    target_ns = spec.get("targetNamespace")
    ns = target_ns or meta.get("namespace") or "default"
    name = spec.get("releaseName") or (
        f"{target_ns}-{meta['name']}" if target_ns else meta["name"]
    )
    values_file = Path(tmp, "values.json")
    values_file.write_text(
        json.dumps(values(release, objs, notes), ensure_ascii=False), encoding="utf-8"
    )
    helm = shutil.which("helm") or "helm"
    # helm gets an empty home of its own: with repos already added (`helm repo add`), it checks
    # their cached indexes even for a --repo pull and fails on a missing one.
    env = dict(os.environ)
    for var in ("HELM_CONFIG_HOME", "HELM_CACHE_HOME", "HELM_DATA_HOME"):
        env[var] = str(Path(tmp, "helm-home", var.lower()))
    pulled = Path(tmp, "chart")
    version = None
    shutil.rmtree(pulled, ignore_errors=True)
    try:
        run([helm, "pull", *args, "--untar", "--untardir", str(pulled)], env=env)
        (chart_dir,) = [p for p in pulled.iterdir() if p.is_dir()]
        version = chart_version(chart_dir)
        cmd = [helm, "template", name, str(chart_dir), "--namespace", ns]
        cmd += ["--values", str(values_file)]
        if os.environ.get("HELM_KUBE_VERSION"):
            cmd += ["--kube-version", os.environ["HELM_KUBE_VERSION"]]
        manifest = post_render(run(cmd, env=env), release, tmp)
        docs = yaml_docs(manifest)
    except subprocess.CalledProcessError as e:
        err = (e.stderr or "").strip().splitlines()
        notes.append(f"helm {e.cmd[1]} failed: {err[-1] if err else e}")
        return None, notes
    out = {}
    for doc in docs:
        if isinstance(doc, dict) and "kind" in doc:
            doc.setdefault("metadata", {})
            drop_chart_labels(doc, version)
            drop_derived(doc)
            out[key(doc)] = doc
    return out, notes


def drop_chart_labels(node, version):
    """Removes the labels that carry the chart version: helm.sh/chart, and any label whose value
    is the version or ends in -<version> (chart: name-1.2.3; kube-prometheus-stack also sets
    app.kubernetes.io/version to it). On a chart bump they change on every object and bury the
    real changes; the version itself shows on the HelmRelease."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "labels" and isinstance(v, dict):
                for label, value in list(v.items()):
                    value = str(value)
                    if label == "helm.sh/chart" or (
                        version and (value == version or value.endswith(f"-{version}"))
                    ):
                        del v[label]
            else:
                drop_chart_labels(v, version)
    elif isinstance(node, list):
        for v in node:
            drop_chart_labels(v, version)


def drop_derived(doc):
    """Secret values become "(redacted)" and checksum/* annotations go. Without a cluster, helm
    template regenerates random values (a chart's generated admin password) on every run, so they
    and the checksums over them always differ; and a Secret's values don't belong in a PR
    comment. Key changes still show, and so do the ConfigMaps the checksums are over."""
    if doc.get("kind") == "Secret":
        for field in ("data", "stringData"):
            if isinstance(doc.get(field), dict):
                doc[field] = {k: "(redacted)" for k in doc[field]}
    stack = [doc]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            annotations = node.get("annotations")
            if isinstance(annotations, dict):
                for k in [k for k in annotations if k.startswith("checksum/")]:
                    del annotations[k]
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
