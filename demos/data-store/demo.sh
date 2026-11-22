#!/usr/bin/env sh
# Run the catalog data-store demo in its own namespace on the current
# Kubernetes cluster (a local kind cluster is enough).
#
#   ./demo.sh up            deploy Postgres 18 and OpenFGA (k8s.yaml), (re)create
#                           the `catalog` database, load sql/*.sql, and load
#                           OpenFGA from authz.fga_tuples
#   ./demo.sh walkthrough   run the guided walkthrough (walkthrough.sql)
#   ./demo.sh test          run the invariant checks (test.sql, rolled back),
#                           then check-page, then drift
#   ./demo.sh drift [--apply]
#                           compare the two authorization evaluators: SQL rule
#                           vs OpenFGA (fga/drift.py); --apply repairs
#                           projections and the OpenFGA store
#   ./demo.sh check-page    check that index.html (the schema page) lists exactly
#                           the tables, views, columns, types and functions
#                           the database has, and that flows.html only names
#                           objects that exist, and that the model in the docs
#                           is fga/model.fga
#   ./demo.sh psql          interactive psql in the catalog database
#   ./demo.sh down          delete the catalog-data-store namespace
#
# Needs kubectl pointing at the cluster you want to use. Nothing outside the
# catalog-data-store namespace is created or changed.
set -eu
cd "$(dirname "$0")"
NS=catalog-data-store
POD=postgres-0
DB=catalog

pod_psql() {   # pod_psql <database> [psql args...]   (SQL on stdin)
  d=$1; shift
  kubectl -n "$NS" exec -i "$POD" -- env PGOPTIONS="-c client_min_messages=warning" psql -X -q -U postgres -d "$d" -v ON_ERROR_STOP=1 "$@"
}

# The live schema, one line per object, in the same shape check-page extracts
# from index.html. Partitions are left out; their parent stands for them.
LIVE_SQL="
select 'R ' || c.table_schema || '.' || c.table_name || ' ' ||
       case t.table_type when 'VIEW' then 'view' else 'table' end
  from information_schema.tables t
  join information_schema.tables c using (table_schema, table_name)
  join pg_class k on k.relname = t.table_name
  join pg_namespace n on n.oid = k.relnamespace and n.nspname = t.table_schema
 where t.table_schema in ('catalog', 'authz', 'api') and not k.relispartition
union all
select 'C ' || col.table_schema || '.' || col.table_name || '.' || col.column_name || ' ' ||
       case when col.data_type = 'ARRAY' then substr(col.udt_name, 2) || '[]'
            when col.data_type = 'USER-DEFINED' then col.udt_name
            else col.data_type end
  from information_schema.columns col
  join pg_class k on k.relname = col.table_name
  join pg_namespace n on n.oid = k.relnamespace and n.nspname = col.table_schema
 where col.table_schema in ('catalog', 'authz', 'api') and not k.relispartition
union all
select distinct 'F ' || n.nspname || '.' || p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('catalog', 'authz', 'api')
order by 1"

PAGE_PY='
import json, re, sys
html = sys.stdin.read()
m = re.search(r"<script type=\"application/json\" id=\"schema-data\">(.*?)</script>", html, re.S)
if not m:
    sys.exit("index.html: no schema-data block")
d = json.loads(m.group(1))
out = []
for t in d["tables"]:
    out.append("R %s %s" % (t["id"], t["kind"]))
    for c in t["columns"]:
        out.append("C %s.%s %s" % (t["id"], c["name"], c["type"]))
for f in d["functions"]:
    out.append("F " + f["id"])
origins = {"external", "config", "generated", "derived", "computed"}
for t in d["tables"]:
    for c in t["columns"]:
        if c.get("origin") not in origins or not c.get("by"):
            sys.exit("index.html: %s.%s needs an origin (one of %s) and a by" % (t["id"], c["name"], ", ".join(sorted(origins))))
ids = {t["id"] for t in d["tables"]} | {f["id"] for f in d["functions"]}
for t in d["tables"]:
    for r in t["writtenBy"] + t["readBy"]:
        if r not in ids:
            sys.exit("index.html: %s refers to unknown %s" % (t["id"], r))
for e in d["edges"]:
    for end in (e["from"], e["to"]):
        if end not in ids:
            sys.exit("index.html: edge refers to unknown " + end)
print("\n".join(sorted(out, key=lambda s: s.encode())))
'

# flows.html ("How it works") names tables, views and functions in its
# diagrams. Every one must exist on the schema page, and every edge and step
# must refer to nodes that exist.
FLOWS_PY='
import json, re, sys
def block(path, id):
    m = re.search(r"<script type=\"application/json\" id=\"%s\">(.*?)</script>" % id, open(path).read(), re.S)
    if not m:
        sys.exit("%s: no %s block" % (path, id))
    return json.loads(m.group(1))
schema, flows = block(sys.argv[1], "schema-data"), block(sys.argv[2], "flow-data")
ids = {t["id"] for t in schema["tables"]} | {f["id"] for f in schema["functions"]}
types = {"config", "external", "fn", "table", "derived", "view"}
steps = 0
for sc in flows["scenarios"]:
    nodes = {n["id"]: n for n in sc["nodes"]}
    for n in sc["nodes"]:
        if n["type"] not in types:
            sys.exit("flows.html: %s/%s has unknown type %s" % (sc["id"], n["id"], n["type"]))
        if n["type"] not in ("config", "external") and n.get("ref") not in ids:
            sys.exit("flows.html: %s/%s refers to %s, which is not on the schema page" % (sc["id"], n["id"], n.get("ref")))
    edges = {e["id"] for e in sc["edges"]}
    for e in sc["edges"]:
        if e["from"] not in nodes or e["to"] not in nodes:
            sys.exit("flows.html: %s edge %s refers to an unknown node" % (sc["id"], e["id"]))
    for i, st in enumerate(sc["steps"], 1):
        steps += 1
        bad = [x for x in st["on"] if x not in nodes] + [x for x in st["edges"] if x not in edges]
        if bad:
            sys.exit("flows.html: %s step %d refers to unknown %s" % (sc["id"], i, ", ".join(bad)))
print("flows page refers only to real objects (%d scenarios, %d steps)" % (len(flows["scenarios"]), steps))
'

# The OpenFGA model is shown in docs/service-catalog/reference.md. That copy
# must be byte-for-byte fga/model.fga, the file OpenFGA actually loads.
MODEL_DOC=../../docs/service-catalog/reference.md
MODEL_PY='
import re, sys
doc, model = open(sys.argv[1]).read(), open(sys.argv[2]).read()
blocks = [b for b in re.findall(r"```[a-z]*\n(.*?)```", doc, re.S) if b.startswith("model\n")]
if len(blocks) != 1:
    sys.exit("%s: expected exactly one OpenFGA model block, found %d" % (sys.argv[1], len(blocks)))
if blocks[0] != model:
    import difflib
    sys.stdout.writelines(difflib.unified_diff(model.splitlines(True), blocks[0].splitlines(True), "fga/model.fga", sys.argv[1]))
    sys.exit("the OpenFGA model in %s differs from fga/model.fga: copy the file into the doc" % sys.argv[1])
print("OpenFGA model in the docs matches fga/model.fga")
'

check_page() {
  command -v python3 >/dev/null || { echo 'check-page needs python3'; exit 1; }
  python3 -I -c "$MODEL_PY" "$MODEL_DOC" fga/model.fga
  tmp=$(mktemp -d)
  pod_psql "$DB" -At -c "$LIVE_SQL" | LC_ALL=C sort > "$tmp/live"
  python3 -I -c "$PAGE_PY" < index.html > "$tmp/page"
  python3 -I -c "$FLOWS_PY" index.html flows.html || { rm -rf "$tmp"; exit 1; }
  if diff -u --label database --label index.html "$tmp/live" "$tmp/page" > "$tmp/diff"; then
    echo "schema page matches the database ($(wc -l < "$tmp/live" | tr -d ' ') objects)"
    rm -rf "$tmp"
  else
    echo 'index.html is out of date with the schema. Lines starting with - exist'
    echo 'in the database but not on the page; + are on the page but not in the'
    echo 'database. Update the schema-data block in index.html (see README.md).'
    cat "$tmp/diff"; rm -rf "$tmp"; exit 1
  fi
}

case "${1:-}" in
  up)
    echo "cluster: $(kubectl config current-context)"
    kubectl apply -f k8s.yaml >/dev/null
    kubectl -n "$NS" rollout status statefulset/postgres --timeout=180s >/dev/null
    kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null
    pod_psql postgres -c "drop database if exists $DB with (force)"
    pod_psql postgres -c "drop role if exists catalog_api, catalog_ingest, catalog_consumer, catalog_auditor, catalog_owner"
    pod_psql postgres -c "create database $DB"
    for f in sql/*.sql; do
      printf 'loading %s\n' "$f"
      pod_psql "$DB" < "$f" >/dev/null
    done
    kubectl -n "$NS" rollout status deployment/openfga --timeout=180s >/dev/null
    python3 -I fga/drift.py sync | tail -1
    echo "ready: $NS/$POD (database $DB) and $NS/openfga"
    ;;
  walkthrough) pod_psql "$DB" < walkthrough.sql ;;
  test)        pod_psql "$DB" < test.sql && check_page && python3 -I fga/drift.py check ;;
  drift)       shift; python3 -I fga/drift.py check "$@" ;;
  check-page)  check_page ;;
  psql)        kubectl -n "$NS" exec -it "$POD" -- psql -U postgres -d "$DB" ;;
  down)        kubectl delete namespace "$NS" ;;
  *)           sed -n '2,23p' "$0"; exit 1 ;;
esac
