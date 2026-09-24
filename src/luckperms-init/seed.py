#!/usr/bin/env python3
"""Apply the declarative LuckPerms model in permissions.yml via the REST API.

The model is authoritative for the groups it names: each managed group's node
set is REPLACED WHOLESALE, so the file always describes reality. Groups absent
from the file are never touched, which leaves ad-hoc groups as an escape hatch.

Operationally that means any change an admin makes in-game to a managed group
-- `/lp group admin permission set ...` -- is DESTROYED on the next
`docker compose up`. That is the intended design, not a bug. Edit
permissions.yml, not the live server, for anything that should survive a deploy.

The script is idempotent. It compares desired state against actual state and
only writes when they differ, then reports how many changes it made, so a
second run reports changed=0.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

API = os.environ.get("LUCKPERMS_API_URL", "http://luckperms-standalone:8080").rstrip("/")
KEY = os.environ.get("LUCKPERMS_SECRET")
MODEL_PATH = os.environ.get("PERMISSIONS_FILE", "/permissions.yml")

if not KEY:
    sys.exit("LUCKPERMS_SECRET is not set")

# Deliberately stricter than the API. Measured: the API rejects a space with
# 400 "Invalid name entry" and lowercases what it accepts (POST {"name":"Admin"}
# stores "admin"), but it happily accepts `#` -- and a group named `has#hash` is
# then unreachable, because everything from `#` on is a URL fragment, so
# DELETE /group/has#hash answers 404 and leaves the group sitting there.
# Requiring lowercase also keeps the `existing_names` comparison below honest.
NAME_RE = re.compile(r"^[a-z0-9._-]+$")

MODEL_KEYS = {"groups", "tracks"}
GROUP_KEYS = {"weight", "prefix", "prefix_priority", "inherits", "permissions"}
PERMISSION_KEYS = {"key", "value", "context", "expiry"}
TRACK_KEYS = {"groups"}

changes = 0


def check_keys(where, mapping, allowed):
    """Reject unrecognized keys instead of ignoring them.

    Ignoring an unknown key is unsafe here specifically because a write
    REPLACES a group's whole node set: a typo of `permisions:` for
    `permissions:` would otherwise mean "delete every permission this group
    has", push that deletion to every running server, and exit 0.
    """
    unknown = sorted(set(mapping) - allowed)
    if unknown:
        sys.exit(f"{where}: unknown key(s) {unknown}; allowed are {sorted(allowed)}")


def request(method, path, body=None):
    """Return (status_code, parsed_body_or_text).

    PATCH /track/X and POST /messaging/update answer with the bare string `ok`
    rather than JSON, so a non-JSON body is normal here, not exceptional.
    """
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


def seg(name):
    """Percent-encode one path segment.

    See NAME_RE: a `#` in a name silently retargets the request at a different
    path. NAME_RE rejects such names up front; this is the second line of
    defence, and it costs nothing.
    """
    return urllib.parse.quote(name, safe="")


def wait_for_api(attempts=60, delay=2):
    """Poll until the REST API answers 200, or give up.

    A 4xx is fatal immediately rather than retried. Retrying one burns the full
    two minutes and then reports "never became reachable", which points a
    misconfigured LUCKPERMS_SECRET -- a 401, and a very likely first-deploy
    failure -- squarely at the network instead.
    """
    for _ in range(attempts):
        try:
            status, body = request("GET", "/health")
            if status == 200:
                print(f"api ready: {body}")
                return
            if 400 <= status < 500:
                sys.exit(f"luckperms api rejected the health check: HTTP {status} {body}")
        except OSError:
            # urllib.error.URLError subclasses OSError, so this covers both the
            # connection-refused case during startup and a DNS failure.
            pass
        time.sleep(delay)
    sys.exit("luckperms api never became reachable")


def build_context(raw, where):
    """Turn {'server': 'survival'} into [{'key': ..., 'value': ...}].

    Lowercased to match what storage will hold. Measured: the API normalizes
    context keys AND values, so {"key":"Server","value":"Project-0"} reads back
    as {"key":"server","value":"project-0"}. Sending mixed case unchanged would
    make desired != actual on every single run, and this script would rewrite
    the same group forever while reporting success.
    """
    if not raw:
        return []
    if not isinstance(raw, dict):
        sys.exit(f"{where}: context must be a mapping, got {type(raw).__name__}")
    out = []
    for key, value in sorted(raw.items()):
        if isinstance(value, (list, dict, tuple)):
            # str() would cheerfully store "['nether', 'the_end']" -- a node
            # that matches no real context, applies to nobody, and is then
            # stably and silently wrong on every subsequent run.
            sys.exit(
                f"{where}: context '{key}' must be a single scalar value, "
                f"got {type(value).__name__}"
            )
        out.append({"key": str(key).lower(), "value": str(value).lower()})
    return out


def check_mchprs_prefixes(group_name, nodes):
    """Reject a stored mchprs.* node that is a strict prefix of another.

    MCHPRS reads this database directly, and per AGENTS.md its
    PermissionNode::matches indexes the stored node's path while walking the
    queried string, so a stored `mchprs.command` checked against a queried
    `mchprs.command.tp` panics the server with an index-out-of-bounds. Two
    adjacent lines of YAML can crash a Minecraft server, and this is the one
    mechanical chokepoint where that is catchable.

    Deliberately scoped to the mchprs namespace. The same shape is ordinary
    elsewhere -- `essentials.home` alongside `essentials.home.other` is fine --
    and only MCHPRS crashes on it.

    This catches the mistake that is visible from the model alone, both keys
    present. It CANNOT catch a lone stored `mchprs.command` whose queried form
    `mchprs.command.tp` exists only in MCHPRS's source, so AGENTS.md's rule --
    exact keys or explicit `*` wildcards -- still governs when writing a model.
    """
    keys = sorted({node["key"] for node in nodes if node["key"].startswith("mchprs.")})
    for shorter in keys:
        if shorter.endswith("*"):
            continue
        for longer in keys:
            if longer != shorter and longer.startswith(shorter + "."):
                sys.exit(
                    f"group '{group_name}': '{shorter}' is a strict prefix of "
                    f"'{longer}', which panics MCHPRS. Use '{shorter}.*' or "
                    f"drop one of the two."
                )


def build_nodes(group_name, spec):
    """Expand a group spec into the flat node list LuckPerms stores.

    Node type is encoded in the key, so no separate type field is sent:
      weight.100          -> group weight
      group.member        -> inheritance
      prefix.100.&c[A]    -> prefix at priority 100
    """
    if not isinstance(spec, dict):
        sys.exit(f"group '{group_name}': spec must be a mapping, got {type(spec).__name__}")
    check_keys(f"group '{group_name}'", spec, GROUP_KEYS)

    nodes = []

    weight = spec.get("weight")
    if weight is not None:
        nodes.append({"key": f"weight.{int(weight)}", "value": True, "context": []})

    prefix = spec.get("prefix")
    if prefix is not None:
        # Priority defaults to the group's own weight, so a heavier group's
        # prefix wins without having to say so twice; `weight or 0` also maps
        # an absent weight onto priority 0.
        priority = int(spec.get("prefix_priority", weight or 0))
        nodes.append({"key": f"prefix.{priority}.{prefix}", "value": True, "context": []})

    for parent in spec.get("inherits", []) or []:
        nodes.append({"key": f"group.{parent}", "value": True, "context": []})

    for entry in spec.get("permissions", []) or []:
        if isinstance(entry, str):
            nodes.append({"key": entry, "value": True, "context": []})
            continue
        if not isinstance(entry, dict):
            sys.exit(
                f"group '{group_name}': permission entry must be a string or a "
                f"mapping, got {type(entry).__name__}"
            )
        check_keys(f"group '{group_name}' permission entry", entry, PERMISSION_KEYS)
        if "key" not in entry:
            sys.exit(f"group '{group_name}': permission entry is missing 'key': {entry}")
        node = {
            "key": entry["key"],
            "value": bool(entry.get("value", True)),
            "context": build_context(
                entry.get("context"), f"group '{group_name}' permission '{entry['key']}'"
            ),
        }
        if "expiry" in entry:
            node["expiry"] = int(entry["expiry"])
        nodes.append(node)

    check_mchprs_prefixes(group_name, nodes)
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
    status, actual = request("GET", f"/group/{seg(name)}/nodes")
    if status != 200:
        sys.exit(f"failed to read nodes for group '{name}': HTTP {status} {actual}")

    have = {node_identity(n) for n in (actual or [])}
    want = {node_identity(n) for n in desired}
    if have == want:
        print(f"group {name}: already correct ({len(want)} nodes)")
        return

    status, body = request("PUT", f"/group/{seg(name)}/nodes", desired)
    if status not in (200, 201, 204):
        sys.exit(f"failed to set nodes for group '{name}': HTTP {status} {body}")
    changes += 1

    # Name what moved. Counts alone -- "set 1 nodes (was 1)" -- make a rewrite
    # loop impossible to diagnose from the log.
    for key in sorted({identity[0] for identity in want - have}):
        print(f"group {name}: + {key}")
    for key in sorted({identity[0] for identity in have - want}):
        print(f"group {name}: - {key}")
    print(f"group {name}: set {len(desired)} nodes (was {len(have)})")

    # The PUT answers with the resulting node list. Check it converged rather
    # than assuming it did. If the API normalizes anything we sent, desired
    # never equals actual, and this script rewrites the same group on every
    # deploy forever while exiting 0 -- exactly the failure mode that
    # build_context's lowercasing exists to prevent. Whatever that misses
    # should be loud rather than eternal.
    if isinstance(body, list):
        settled = {node_identity(n) for n in body}
        if settled != want:
            sys.exit(
                f"group '{name}' did not converge: the API stored something "
                f"other than what was sent. "
                f"missing={sorted(repr(i) for i in want - settled)} "
                f"unexpected={sorted(repr(i) for i in settled - want)}"
            )


def apply_track(name, groups):
    global changes
    status, actual = request("GET", f"/track/{seg(name)}")
    if status == 404:
        status, body = request("POST", "/track", {"name": name})
        if status not in (200, 201, 204):
            sys.exit(f"failed to create track '{name}': HTTP {status} {body}")
        print(f"created track {name}")
        changes += 1
        actual = {"groups": []}
    elif status != 200:
        sys.exit(f"failed to read track '{name}': HTTP {status} {actual}")

    if not isinstance(actual, dict):
        sys.exit(f"failed to read track '{name}': unexpected body {actual!r}")

    # A track is ORDERED, so this compares lists, not sets: a reordering is a
    # real change to the promotion ladder.
    if actual.get("groups") == groups:
        print(f"track {name}: already correct")
        return

    status, body = request("PATCH", f"/track/{seg(name)}", {"groups": groups})
    if status not in (200, 201, 204):
        sys.exit(f"failed to update track '{name}': HTTP {status} {body}")
    print(f"track {name}: set to {groups}")
    changes += 1


def push_messaging():
    """Tell connected servers to reload.

    Best effort on purpose: a failure here leaves stale caches until the next
    restart, not a wrong database, so it must not fail the deploy.
    """
    status, body = request("POST", "/messaging/update")
    if status not in (200, 201, 202, 204):
        print(f"warning: messaging update returned HTTP {status} {body}", file=sys.stderr)
    else:
        print("pushed update to connected servers")


def load_model():
    """Read and validate permissions.yml before anything touches the API."""
    try:
        with open(MODEL_PATH, encoding="utf-8") as handle:
            model = yaml.safe_load(handle)
    except OSError as exc:
        sys.exit(f"cannot read {MODEL_PATH}: {exc}")
    except yaml.YAMLError as exc:
        sys.exit(f"{MODEL_PATH} is not valid YAML: {exc}")

    # An empty or mis-keyed file must NOT read as "nothing to do". `changed=0`
    # is the exact string the idempotency test greps for, so a model that was
    # never really read would sail through that gate while applying nothing at
    # all -- silently, forever, on a bind mount that resolved to the wrong file
    # or a file truncated by a bad merge.
    if not isinstance(model, dict):
        sys.exit(f"{MODEL_PATH} must contain a mapping, got {type(model).__name__}")
    check_keys(MODEL_PATH, model, MODEL_KEYS)

    groups = model.get("groups")
    if not isinstance(groups, dict) or not groups:
        sys.exit(f"{MODEL_PATH} must define a non-empty 'groups' mapping")

    tracks = model.get("tracks") or {}
    if not isinstance(tracks, dict):
        sys.exit(f"{MODEL_PATH}: 'tracks' must be a mapping, got {type(tracks).__name__}")
    for name, spec in tracks.items():
        if not isinstance(spec, dict):
            sys.exit(f"track '{name}': spec must be a mapping, got {type(spec).__name__}")
        check_keys(f"track '{name}'", spec, TRACK_KEYS)

    for kind, names in (("group", groups), ("track", tracks)):
        for name in names:
            if not NAME_RE.match(str(name)):
                sys.exit(
                    f"{kind} name '{name}' must match {NAME_RE.pattern} -- the "
                    f"API lowercases names, and other characters are either "
                    f"rejected outright or break the request URL"
                )

    return groups, tracks


def main():
    groups, tracks = load_model()

    # Expand every group BEFORE the first write, so a model error cannot leave
    # the database half-applied.
    desired = {name: build_nodes(name, spec or {}) for name, spec in groups.items()}
    wanted_tracks = {name: list(spec.get("groups") or []) for name, spec in tracks.items()}

    wait_for_api()

    status, existing = request("GET", "/group")
    if status != 200:
        sys.exit(f"failed to list groups: HTTP {status} {existing}")
    existing_names = set(existing or [])

    complete = False
    try:
        for name, nodes in desired.items():
            ensure_group(name, existing_names)
            apply_group_nodes(name, nodes)
        for name, order in wanted_tracks.items():
            apply_track(name, order)
        complete = True
    finally:
        # Push whatever DID land, even when a later group failed. Otherwise a
        # persistent failure on one group strands every earlier group's writes
        # in the database, invisible to running servers, and it never
        # self-heals: the next run finds those groups already correct, leaves
        # `changes` at 0, and dies in the same place again.
        if changes:
            push_messaging()
        if complete:
            print(f"changed={changes}")
        else:
            # Deliberately NOT a `changed=` line. A failed run must not be able
            # to satisfy a log check looking for `changed=0`.
            print(f"INCOMPLETE -- failed after {changes} change(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
