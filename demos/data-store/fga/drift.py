#!/usr/bin/env python3
"""Drift check between the catalog's two authorization evaluators.

The catalog database answers access questions for its own queries (the SQL
rule in api.resource and authz.viewer_*). OpenFGA answers them for every
other service. Both evaluate the same model over the same facts, so they must
agree. This tool proves it, or shows exactly where they don't.

    python3 -I fga/drift.py check            run every check; exit 1 on drift
    python3 -I fga/drift.py check --apply    ...and repair: rebuild the authz projections,
                                             reconcile the store's model and tuples
    python3 -I fga/drift.py sync             make the long-lived store match
                                             authz.fga_tuples (initial load)

Checks
  1. projections  authz.user_team / user_role / user_kind_grant equal a fresh
                  rebuild from links                        (SQL side)
  2. tuples       the long-lived OpenFGA store "catalog" holds the current model
                  and exactly the tuples in authz.fga_tuples (sync drift)
  3. model        on a scratch store loaded with authz.fga_tuples, OpenFGA
                  Check equals the SQL rule for every live user x resource x
                  compared relation, and ListObjects(can_view) equals the rows
                  api.resource returns                       (model drift)

It also prints the coverage map (which relations both sides answer) and
probes the known semantic differences, which are reported as warnings.

Needs: python3 (stdlib only), kubectl pointing at the cluster that runs the
catalog-data-store namespace (the psql client and OpenFGA from k8s.yaml).
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

NS = os.environ.get("CATALOG_NAMESPACE", "catalog-data-store")
# The psql client deployment from k8s.yaml: connects as the database owner
# with the credentials in Secret catalog-data-store-db.
PSQL = "deploy/psql"
ROLES_PSQL = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sql", "_roles.psql")
CLI_IMAGE = "docker.io/openfga/cli:v0.8.2"
STORE = "catalog"
HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_FILE = os.environ.get("FGA_MODEL", os.path.join(HERE, "model.fga"))   # override only to test the tool

# Relations on `resource` that both evaluators answer, and the SQL column of
# authz.access_matrix that answers it. Anything else on `resource` in the
# model is reported as not compared.
COMPARED = {
    "can_view": "can_view",
    "can_view_sensitive": "sees_sensitive",
    "can_edit": "can_edit",
    "can_transfer": "can_transfer",
}
# Relations that exist on one side only, on purpose.
ONE_SIDED = {
    "kind": "structural (tuple), not a permission",
    "owner": "structural (tuple), not a permission",
    "owner_member": "building block of the permissions below",
    "can_run_action": "OpenFGA only: actions are run by services outside the catalog",
}
# Kinds that are their own OpenFGA types, not `resource` objects.
NOT_RESOURCES = ("user", "identity_group", "team", "platform")


# ---------------------------------------------------------------- plumbing
def psql(sql):
    with open(ROLES_PSQL) as f:
        preamble = f.read()   # role names as psql variables (:api_role, ...)
    r = subprocess.run(
        ["kubectl", "-n", NS, "exec", "-i", PSQL, "--",
         "psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"],
        input=preamble + "\n" + sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("psql failed:\n" + r.stderr)
    return r.stdout.strip()


def sql_json(sql):
    out = psql(sql)
    return json.loads(out) if out else None


class Fga:
    def __init__(self, base):
        self.base = base

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            sys.exit("OpenFGA %s %s failed (%s): %s" % (method, path, e.code, e.read().decode()))

    def store_id(self, name, create=False):
        token = ""
        while True:
            page = self.call("GET", "/stores?page_size=100" + ("&continuation_token=" + token if token else ""))
            for s in page.get("stores", []):
                if s["name"] == name:
                    return s["id"]
            token = page.get("continuation_token", "")
            if not token:
                break
        return self.call("POST", "/stores", {"name": name})["id"] if create else None

    def write_model(self, store, model):
        return self.call("POST", "/stores/%s/authorization-models" % store, model)["authorization_model_id"]

    def latest_model(self, store):
        models = self.call("GET", "/stores/%s/authorization-models?page_size=1" % store).get("authorization_models", [])
        return models[0] if models else None

    def read_all(self, store):
        tuples, token = set(), ""
        while True:
            body = {"page_size": 100}
            if token:
                body["continuation_token"] = token
            page = self.call("POST", "/stores/%s/read" % store, body)
            for t in page.get("tuples", []):
                k = t["key"]
                tuples.add((k["object"], k["relation"], k["user"]))
            token = page.get("continuation_token", "")
            if not token:
                return tuples

    def write(self, store, model_id, writes=(), deletes=()):
        def keys(ts):
            return [{"object": o, "relation": r, "user": u} for (o, r, u) in ts]
        writes, deletes = sorted(writes), sorted(deletes)
        for i in range(0, len(deletes), 100):
            self.call("POST", "/stores/%s/write" % store,
                      {"authorization_model_id": model_id, "deletes": {"tuple_keys": keys(deletes[i:i + 100])}})
        for i in range(0, len(writes), 100):
            self.call("POST", "/stores/%s/write" % store,
                      {"authorization_model_id": model_id, "writes": {"tuple_keys": keys(writes[i:i + 100])}})

    def batch_check(self, store, model_id, checks):
        """checks: list of (user, relation, object) -> list of bool"""
        out = []
        for i in range(0, len(checks), 50):
            chunk = checks[i:i + 50]
            body = {"authorization_model_id": model_id, "checks": [
                {"tuple_key": {"user": u, "relation": r, "object": o}, "correlation_id": str(j)}
                for j, (u, r, o) in enumerate(chunk)]}
            res = self.call("POST", "/stores/%s/batch-check" % store, body)["result"]
            for j in range(len(chunk)):
                item = res[str(j)]
                if "error" in item:
                    sys.exit("OpenFGA check error for %s: %s" % (chunk[j], item["error"]))
                out.append(item.get("allowed", False))
        return out

    def list_objects(self, store, model_id, user, relation, type_="resource"):
        return set(self.call("POST", "/stores/%s/list-objects" % store, {
            "authorization_model_id": model_id, "type": type_, "relation": relation, "user": user})["objects"])


class PortForward:
    def __enter__(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        self.proc = subprocess.Popen(
            ["kubectl", "-n", NS, "port-forward", "svc/openfga", "%d:8080" % self.port],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        base = "http://127.0.0.1:%d" % self.port
        for _ in range(60):
            try:
                urllib.request.urlopen(base + "/healthz", timeout=1).read()
                return Fga(base)
            except Exception:
                time.sleep(0.5)
        self.proc.terminate()
        sys.exit("could not reach OpenFGA in namespace %s (is it deployed? ./demo.sh up)" % NS)

    def __exit__(self, *exc):
        self.proc.terminate()
        self.proc.wait()


def model_json():
    """model.fga (DSL) -> JSON, using the OpenFGA CLI in a throwaway pod."""
    name = "fga-cli-%d" % (int(time.time() * 1000) % 10**9)
    with open(MODEL_FILE) as f:
        dsl = f.read()
    r = subprocess.run(
        ["kubectl", "-n", NS, "run", name, "--rm", "-i", "--restart=Never", "--quiet",
         "--image=" + CLI_IMAGE, "--", "model", "transform", "--file", "/dev/stdin"],
        input=dsl, capture_output=True, text=True)
    out = r.stdout.strip()
    start = out.find("{")
    if r.returncode != 0 or start < 0:
        sys.exit("model transform failed:\n" + r.stderr + out)
    return json.loads(out[start:]), dsl


def resource_relations(dsl):
    rels, in_resource = [], False
    for line in dsl.splitlines():
        s = line.strip()
        if s.startswith("type "):
            in_resource = s == "type resource"
        elif in_resource and s.startswith("define "):
            rels.append(s.split()[1].rstrip(":"))
    return rels


def _strip(v):
    # The server echoes defaults ("module": "", "source_info": null,
    # "condition": "", empty lists) that the CLI leaves out. Empty objects stay: "this": {}
    # and "wildcard": {} carry meaning.
    # "relations": {} and "metadata": {} on a type without relations mean
    # the same as leaving them out.
    if isinstance(v, dict):
        return {k: _strip(x) for k, x in v.items()
                if x not in ("", None, []) and not (k in ("relations", "metadata") and x == {})}
    if isinstance(v, list):
        return [_strip(x) for x in v]
    return v


def normalise(model):
    return json.dumps(_strip({"schema_version": model.get("schema_version"),
                              "type_definitions": sorted(model.get("type_definitions", []), key=lambda t: t["type"])}),
                      sort_keys=True)


# ---------------------------------------------------------------- data
EXPECTED_SQL = "select coalesce(json_agg(json_build_array(object, relation, subject)), '[]') from authz.fga_tuples;"

USERS_SQL = "select coalesce(json_agg(ref order by ref), '[]') from catalog.resource where kind = 'user' and deleted_at is null;"

DECISIONS_SQL = """
select coalesce(json_agg(json_build_object(
         'user', m.user_ref, 'object', format('resource:%s/%s', r.kind, r.identifier),
         'can_view', m.can_view, 'sees_sensitive', m.sees_sensitive,
         'can_edit', m.can_edit, 'can_transfer', m.can_transfer)), '[]')
  from catalog.resource r
  cross join lateral authz.access_matrix(r.ref) m
 where r.deleted_at is null and r.kind not in ('user', 'identity_group', 'team', 'platform');
"""

VISIBLE_SQL = """
create temporary table drift_visible (usr text, obj text);
grant insert on drift_visible to :"api_role";
do $$
declare u text;
begin
  for u in select ref from catalog.resource where kind = 'user' and deleted_at is null loop
    perform set_config('catalog.viewer', u, true);
    execute format('set local role %I', current_setting('demo.api_role'));
    insert into drift_visible
    select u, format('resource:%s/%s', kind, identifier) from api.resource
     where kind not in ('user', 'identity_group', 'team', 'platform');
    execute 'reset role';
  end loop;
end $$;
select coalesce(json_object_agg(usr, objs), '{}') from (select usr, json_agg(obj) objs from drift_visible group by usr) x;
"""

PROJECTIONS_SQL = """
begin;
\\o /dev/null
create temporary table b_ut as table authz.user_team;
create temporary table b_ur as table authz.user_role;
create temporary table b_ukg as table authz.user_kind_grant;
select authz.refresh_memberships();
\\o
select json_build_object(
  'user_team', (select coalesce(json_agg(x), '[]') from (
      (select 'missing' as drift, * from authz.user_team except select 'missing', * from b_ut)
      union all (select 'stale', * from b_ut except select 'stale', * from authz.user_team)) x),
  'user_role', (select coalesce(json_agg(x), '[]') from (
      (select 'missing' as drift, * from authz.user_role except select 'missing', * from b_ur)
      union all (select 'stale', * from b_ur except select 'stale', * from authz.user_role)) x),
  'user_kind_grant', (select coalesce(json_agg(x), '[]') from (
      (select 'missing' as drift, * from authz.user_kind_grant except select 'missing', * from b_ukg)
      union all (select 'stale', * from b_ukg except select 'stale', * from authz.user_kind_grant)) x));
rollback;
"""

PROBE_SQL = """
select coalesce(json_agg(format('resource:%s/%s', r.kind, r.identifier)), '[]')
  from (select r.* from catalog.resource r join catalog.kind k on k.id = r.kind
         where r.deleted_at is null and k.visibility = 'org'
           and r.kind not in ('user', 'identity_group', 'team', 'platform')
         order by r.kind, r.identifier limit 1) r;
"""


# ---------------------------------------------------------------- checks
class Report:
    def __init__(self):
        self.drift = 0
        self.warnings = []

    def section(self, n, title, ok, detail=""):
        print("[%d/3] %-62s %s" % (n, title, "ok" if ok else "DRIFT"))
        if detail:
            print(detail)
        if not ok:
            self.drift += 1


def table(rows, header, limit=40):
    rows = [tuple(str(c) for c in r) for r in rows]
    widths = [max(len(h), *(len(r[i]) for r in rows)) if rows else len(h) for i, h in enumerate(header)]
    lines = ["      " + "  ".join(h.ljust(w) for h, w in zip(header, widths))]
    for r in rows[:limit]:
        lines.append("      " + "  ".join(c.ljust(w) for c, w in zip(r, widths)))
    if len(rows) > limit:
        lines.append("      ... and %d more" % (len(rows) - limit))
    return "\n".join(lines)


def check_projections(rep, apply):
    res = sql_json(PROJECTIONS_SQL)
    rows = [(t, r["drift"], ", ".join("%s=%s" % (k, v) for k, v in r.items() if k != "drift"))
            for t, rs in res.items() for r in rs]
    if rows and apply:
        psql("select authz.refresh_memberships();")
        print("      applied: rebuilt the authz projections (%d rows were wrong)" % len(rows))
        res = sql_json(PROJECTIONS_SQL)
        rows = [(t, r["drift"], str(r)) for t, rs in res.items() for r in rs]
    rep.section(1, "projections: authz tables equal a fresh rebuild", not rows,
                table(rows, ["table", "drift", "row"]) if rows else "")


def check_tuples(rep, fga, model, expected, apply):
    store = fga.store_id(STORE, create=apply)
    if store is None:
        rep.section(2, "tuples: store '%s' vs authz.fga_tuples" % STORE, False,
                    "      store '%s' does not exist. Run with --apply (or `drift.py sync`) to load it." % STORE)
        return
    latest = fga.latest_model(store)
    model_ok = latest is not None and normalise(latest) == normalise(model)
    if not model_ok and apply:
        fga.write_model(store, model)
        latest, model_ok = fga.latest_model(store), True
    actual = fga.read_all(store)
    missing, extra = expected - actual, actual - expected
    if (missing or extra) and apply:
        fga.write(store, latest["id"], writes=missing, deletes=extra)
        print("      applied: wrote %d, deleted %d tuples" % (len(missing), len(extra)))
        actual = fga.read_all(store)
        rest = (expected - actual) | (actual - expected)
        ok = not rest and model_ok
        rep.section(2, "tuples: store '%s' vs authz.fga_tuples (%d tuples)" % (STORE, len(expected)), ok,
                    "" if ok else table(sorted(rest), ["object", "relation", "subject"]))
        return
    rows = [("missing",) + t for t in sorted(missing)] + [("extra",) + t for t in sorted(extra)]
    detail = []
    if not model_ok:
        detail.append("      the store's latest model differs from " + os.path.relpath(MODEL_FILE))
    if rows:
        detail.append(table(rows, ["drift", "object", "relation", "subject"]))
    rep.section(2, "tuples: store '%s' vs authz.fga_tuples (%d tuples)" % (STORE, len(expected)),
                model_ok and not rows, "\n".join(detail))


def check_model(rep, fga, model, expected, dsl):
    users = sql_json(USERS_SQL)
    decisions = sql_json(DECISIONS_SQL)
    visible = {u: set(objs) for u, objs in sql_json(VISIBLE_SQL).items()}
    scratch = fga.store_id("drift-scratch-%d" % os.getpid(), create=True)
    try:
        model_id = fga.write_model(scratch, model)
        fga.write(scratch, model_id, writes=expected)

        checks, want = [], []
        for d in decisions:
            for rel, col in COMPARED.items():
                checks.append((d["user"], rel, d["object"]))
                want.append(d[col])
        got = fga.batch_check(scratch, model_id, checks)
        mism = [(u, r, o, "allow" if g else "deny", "allow" if w else "deny")
                for (u, r, o), g, w in zip(checks, got, want) if g != w]

        list_mism = []
        for u in users:
            fga_objs = fga.list_objects(scratch, model_id, u, "can_view")
            sql_objs = visible.get(u, set())
            for o in sorted(fga_objs - sql_objs):
                list_mism.append((u, o, "listed by OpenFGA only"))
            for o in sorted(sql_objs - fga_objs):
                list_mism.append((u, o, "returned by api.resource only"))

        n_res = len({d["object"] for d in decisions})
        title = "model: %d users x %d resources x %d relations = %d checks" % (len(users), n_res, len(COMPARED), len(checks))
        detail = []
        if mism:
            detail.append(table(mism, ["user", "relation", "object", "openfga", "sql"]))
        if list_mism:
            detail.append(table(list_mism, ["user", "object", "list-objects(can_view)"]))
        rep.section(3, title, not mism and not list_mism, "\n".join(detail))

        # Known semantic differences: probe, report as warnings.
        probe = sql_json(PROBE_SQL)
        if probe:
            nobody = "user:drift-probe-nobody"
            allowed = fga.batch_check(scratch, model_id, [(nobody, "can_view", probe[0])])[0]
            if allowed:
                rep.warnings.append(
                    "unknown principals: OpenFGA lets %s view %s (org kinds are granted to user:*),\n"
                    "        while the SQL rule shows nothing to a viewer that is not a live user resource.\n"
                    "        Accepted: callers of OpenFGA must pass only authenticated, existing users." % (nobody, probe[0]))
    finally:
        fga.call("DELETE", "/stores/%s" % scratch)

    # Coverage map: what both sides answer.
    rels = resource_relations(dsl)
    unmapped = [r for r in rels if r not in COMPARED and r not in ONE_SIDED]
    print("\ncoverage (relations on `resource` in fga/model.fga):")
    for r in rels:
        if r in COMPARED:
            print("  = %-20s both evaluators; compared against SQL %s" % (r, COMPARED[r]))
        elif r in ONE_SIDED:
            print("  - %-20s %s" % (r, ONE_SIDED[r]))
        else:
            print("  ? %-20s NOT COMPARED: add it to COMPARED (with its SQL answer) or ONE_SIDED" % r)
    for r in unmapped:
        rep.warnings.append("relation %s is in the model but neither compared nor declared one-sided" % r)


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("check", "sync") or any(a not in ("check", "sync", "--apply") for a in args):
        sys.exit(__doc__)
    sync = args[0] == "sync"
    apply = sync or "--apply" in args

    model, dsl = model_json()
    expected = {tuple(t) for t in sql_json(EXPECTED_SQL)}
    rep = Report()
    print("OpenFGA drift check · namespace %s · %d expected tuples\n" % (NS, len(expected)))
    with PortForward() as fga:
        if sync:
            check_tuples(rep, fga, model, expected, apply=True)
        else:
            check_projections(rep, apply)
            check_tuples(rep, fga, model, expected, apply)
            check_model(rep, fga, model, expected, dsl)

    if rep.warnings:
        print("\nknown differences and warnings (not failures):")
        for w in rep.warnings:
            print("  ! " + w)
    print("\n" + ("no drift" if rep.drift == 0 else "DRIFT in %d check(s)" % rep.drift))
    sys.exit(1 if rep.drift else 0)


if __name__ == "__main__":
    main()
