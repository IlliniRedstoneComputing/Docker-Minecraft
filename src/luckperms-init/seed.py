#!/usr/bin/env python3
"""Apply the declarative LuckPerms model in permissions.yml via the REST API.

The model is authoritative for the groups it names: each managed group's node
set is replaced wholesale, so the file always describes reality. Groups absent
from the file are never touched, which leaves ad-hoc groups as an escape hatch.

The script is idempotent. It compares desired state against actual state and
only writes when they differ, then reports how many changes it made, so a
second run reports zero.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

import yaml

API = os.environ.get("LUCKPERMS_API_URL", "http://luckperms-standalone:8080").rstrip("/")
KEY = os.environ["LUCKPERMS_SECRET"]
MODEL_PATH = os.environ.get("PERMISSIONS_FILE", "/permissions.yml")

changes = 0


def request(method, path, body=None):
    """Return (status_code, parsed_body_or_text)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {KEY}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            if not raw:
                return resp.status, None
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw.decode(errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode(errors="replace")


def wait_for_api(attempts=60, delay=2):
    for _ in range(attempts):
        try:
            status, body = request("GET", "/health")
            if status == 200:
                print(f"api ready: {body}")
                return
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(delay)
    sys.exit("luckperms api never became reachable")


def build_context(raw):
    """Turn {'server': 'survival'} into [{'key': ..., 'value': ...}]."""
    if not raw:
        return []
    return [{"key": str(k), "value": str(v)} for k, v in sorted(raw.items())]


def build_nodes(group_name, spec):
    """Expand a group spec into the flat node list LuckPerms stores.

    Node type is encoded in the key, so no separate type field is sent:
      weight.100          -> group weight
      group.member        -> inheritance
      prefix.100.&c[A]    -> prefix at priority 100
    """
    nodes = []

    weight = spec.get("weight")
    if weight is not None:
        nodes.append({"key": f"weight.{int(weight)}", "value": True, "context": []})

    prefix = spec.get("prefix")
    if prefix is not None:
        priority = int(spec.get("prefix_priority", weight or 0))
        nodes.append({"key": f"prefix.{priority}.{prefix}", "value": True, "context": []})

    for parent in spec.get("inherits", []) or []:
        nodes.append({"key": f"group.{parent}", "value": True, "context": []})

    for entry in spec.get("permissions", []) or []:
        if isinstance(entry, str):
            nodes.append({"key": entry, "value": True, "context": []})
            continue
        if "key" not in entry:
            sys.exit(f"group '{group_name}': permission entry is missing 'key': {entry}")
        node = {
            "key": entry["key"],
            "value": bool(entry.get("value", True)),
            "context": build_context(entry.get("context")),
        }
        if "expiry" in entry:
            node["expiry"] = int(entry["expiry"])
        nodes.append(node)

    return nodes


def node_identity(node):
    """A comparable form, so ordering and absent optional fields do not matter."""
    return (
        node["key"],
        bool(node.get("value", True)),
        tuple(sorted((c["key"], c["value"]) for c in node.get("context") or [])),
        node.get("expiry"),
    )


def ensure_group(name, existing_names):
    global changes
    if name in existing_names:
        return
    status, body = request("POST", "/group", {"name": name})
    if status in (200, 201, 204):
        print(f"created group {name}")
        changes += 1
    elif status == 409:
        pass  # raced with something else; harmless
    else:
        sys.exit(f"failed to create group '{name}': HTTP {status} {body}")


def apply_group_nodes(name, desired):
    global changes
    status, actual = request("GET", f"/group/{name}/nodes")
    if status != 200:
        sys.exit(f"failed to read nodes for group '{name}': HTTP {status} {actual}")

    have = {node_identity(n) for n in (actual or [])}
    want = {node_identity(n) for n in desired}
    if have == want:
        print(f"group {name}: already correct ({len(want)} nodes)")
        return

    status, body = request("PUT", f"/group/{name}/nodes", desired)
    if status not in (200, 201, 204):
        sys.exit(f"failed to set nodes for group '{name}': HTTP {status} {body}")
    print(f"group {name}: set {len(desired)} nodes (was {len(have)})")
    changes += 1


def apply_track(name, groups):
    global changes
    status, actual = request("GET", f"/track/{name}")
    if status == 404:
        status, body = request("POST", "/track", {"name": name})
        if status not in (200, 201, 204):
            sys.exit(f"failed to create track '{name}': HTTP {status} {body}")
        print(f"created track {name}")
        changes += 1
        actual = {"groups": []}
    elif status != 200:
        sys.exit(f"failed to read track '{name}': HTTP {status} {actual}")

    if (actual or {}).get("groups") == groups:
        print(f"track {name}: already correct")
        return

    status, body = request("PATCH", f"/track/{name}", {"groups": groups})
    if status not in (200, 201, 204):
        sys.exit(f"failed to update track '{name}': HTTP {status} {body}")
    print(f"track {name}: set to {groups}")
    changes += 1


def main():
    with open(MODEL_PATH, encoding="utf-8") as handle:
        model = yaml.safe_load(handle) or {}

    wait_for_api()

    status, existing = request("GET", "/group")
    if status != 200:
        sys.exit(f"failed to list groups: HTTP {status} {existing}")
    existing_names = set(existing or [])

    for name, spec in (model.get("groups") or {}).items():
        ensure_group(name, existing_names)
        apply_group_nodes(name, build_nodes(name, spec or {}))

    for name, spec in (model.get("tracks") or {}).items():
        apply_track(name, list((spec or {}).get("groups") or []))

    if changes:
        status, body = request("POST", "/messaging/update")
        if status not in (200, 201, 202, 204):
            print(f"warning: messaging update returned HTTP {status} {body}", file=sys.stderr)
        else:
            print("pushed update to connected servers")

    print(f"changed={changes}")


if __name__ == "__main__":
    main()
