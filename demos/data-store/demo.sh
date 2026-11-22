#!/usr/bin/env sh
# Run the catalog data-store demo on the current Kubernetes cluster.
#
#   ./demo.sh up            provision the database (see Modes), deploy the psql
#                           client and OpenFGA (k8s.yaml), recreate the schema
#                           from sql/*.sql, and load OpenFGA from authz.fga_tuples
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
#   ./demo.sh pages         localenv only: build the demo pages image and serve
#                           them at https://catalog-data-store.dev.test
#   ./demo.sh psql          interactive psql in the demo database, as its owner
#   ./demo.sh down          remove the demo workloads (localenv: the database
#                           stays; standalone: the namespace is deleted)
#
# Modes (CATALOG_PG):
#   localenv (default)  the local kind environment: `localenv apps apply` on
#                       .localenv.yaml gives the database, its extra roles and
#                       Secret catalog-data-store-db on the shared PostgreSQL
#   standalone          clusters without localenv (CI): deploys standalone.yaml
#                       and creates the same database, roles and Secret itself
#
# Needs kubectl and python3. Nothing outside the demo namespace is changed,
# apart from what localenv provisions for it.
set -eu
cd "$(dirname "$0")"
MODE=${CATALOG_PG:-localenv}
APP=catalog-data-store
OWNER=catalog_data_store              # localenv: app name with dashes as underscores
ROLES="api ingest consumer auditor"   # extra roles <owner>_<role>, as in .localenv.yaml
case "$MODE" in
  localenv)   NS=$APP ;;              # localenv puts an app in a namespace of its name
  standalone) NS=${CATALOG_NAMESPACE:-$APP} ;;
  *)          echo "CATALOG_PG must be localenv or standalone" >&2; exit 1 ;;
esac
export CATALOG_NAMESPACE=$NS          # read by fga/drift.py

pod_psql() {   # SQL on stdin, as the database owner, via the psql client pod
  kubectl -n "$NS" exec -i deploy/psql -- env PGOPTIONS="-c client_min_messages=warning" \
    psql -X -q -v ON_ERROR_STOP=1 "$@"
}

run_sql() {    # run_sql <file>: the role-name preamble, then the file
  { cat sql/_roles.psql; echo; cat "$1"; } | pod_psql
}

# Standalone mode: create what localenv would (owner, database, marked NOLOGIN
# roles granted WITH INHERIT FALSE, SET TRUE, ADMIN FALSE, and the Secret).
# Passwords are generated into Secrets through 0600 files; they are never
# printed and never on a command line. The owner password is regenerated on
# every run, so this never needs to read a Secret back.
standalone_db() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  tmp=$(mktemp -d); chmod 700 "$tmp"
  if ! kubectl -n "$NS" get secret postgres-superuser >/dev/null 2>&1; then
    (umask 077; openssl rand -hex 24 | tr -d '\n' > "$tmp/password")
    kubectl -n "$NS" create secret generic postgres-superuser --from-file=password="$tmp/password" >/dev/null
  fi
  kubectl -n "$NS" apply -f standalone.yaml >/dev/null
  kubectl -n "$NS" rollout status statefulset/postgres --timeout=180s >/dev/null
  kubectl -n "$NS" wait --for=condition=Ready pod/postgres-0 --timeout=180s >/dev/null
  roles_csv=""
  for r in $ROLES; do roles_csv="${roles_csv:+$roles_csv,}${OWNER}_$r"; done
  (umask 077
   openssl rand -hex 24 | tr -d '\n' > "$tmp/password"
   printf '%s' postgres > "$tmp/host"; printf '%s' 5432 > "$tmp/port"
   printf '%s' "$OWNER" > "$tmp/database"; printf '%s' "$OWNER" > "$tmp/username"
   printf '%s' "$roles_csv" > "$tmp/roles"
   printf 'postgresql://%s:%s@postgres:5432/%s?sslmode=disable' "$OWNER" "$(cat "$tmp/password")" "$OWNER" > "$tmp/uri")
  kubectl -n "$NS" create secret generic "$APP-db" --dry-run=client -o yaml \
    --from-file="$tmp/host" --from-file="$tmp/port" --from-file="$tmp/database" --from-file="$tmp/username" \
    --from-file="$tmp/password" --from-file="$tmp/uri" --from-file="$tmp/roles" | kubectl apply -f - >/dev/null
  { printf '\\set pass %s\n' "$(cat "$tmp/password")"; cat <<SQL
\\set owner $OWNER
\\set roles $roles_csv
select format('create role %I login', :'owner') where not exists (select from pg_roles where rolname = :'owner') \\gexec
select format('alter role %I with login password %L', :'owner', :'pass') \\gexec
select format('create database %I owner %I', :'owner', :'owner') where not exists (select from pg_database where datname = :'owner') \\gexec
select format('revoke all on database %I from public', :'owner') \\gexec
select format('create role %I nologin', r) from unnest(string_to_array(:'roles', ',')) r
 where not exists (select from pg_roles where rolname = r) \\gexec
select format('comment on role %I is %L', r, format('localenv: database role %s of app $APP', substr(r, length(:'owner') + 2)))
  from unnest(string_to_array(:'roles', ',')) r \\gexec
select format('grant %I to %I with inherit false, set true, admin false', r, :'owner')
  from unnest(string_to_array(:'roles', ',')) r \\gexec
SQL
  } | kubectl -n "$NS" exec -i postgres-0 -- env PGOPTIONS="-c client_min_messages=warning" \
        psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres
  rm -rf "$tmp"
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
  pod_psql -At -c "$LIVE_SQL" | LC_ALL=C sort > "$tmp/live"
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
    echo "cluster: $(kubectl config current-context), mode: $MODE, namespace: $NS"
    if [ "$MODE" = localenv ]; then
      command -v localenv >/dev/null || {
        echo "localenv not found: install the local environment, or run with CATALOG_PG=standalone" >&2; exit 1; }
      localenv apps apply "$PWD" >/dev/null   # namespace, database, extra roles, Secret (idempotent)
    else
      standalone_db
    fi
    kubectl -n "$NS" apply -f k8s.yaml >/dev/null
    if [ "$MODE" = standalone ]; then
      kubectl -n "$NS" set env deployment/psql PGSSLMODE=disable >/dev/null   # in-cluster, no TLS
      kubectl -n "$NS" rollout restart deployment/psql >/dev/null             # pick up the new password
    fi
    kubectl -n "$NS" rollout status deployment/psql --timeout=180s >/dev/null
    # The owner can't drop its own database (it can only connect to that one),
    # so start over by dropping the demo's schemas.
    echo "drop schema if exists api, authz, catalog cascade;" | pod_psql
    for f in sql/[0-9]*.sql; do
      printf 'loading %s\n' "$f"
      run_sql "$f" >/dev/null
    done
    kubectl -n "$NS" rollout status deployment/openfga --timeout=180s >/dev/null
    python3 -I fga/drift.py sync | tail -1
    echo "ready: database $OWNER (via $NS/psql) and $NS/openfga"
    ;;
  walkthrough) run_sql walkthrough.sql ;;
  test)        run_sql test.sql && check_page && python3 -I fga/drift.py check ;;
  drift)       shift; python3 -I fga/drift.py check "$@" ;;
  check-page)  check_page ;;
  pages)
    [ "$MODE" = localenv ] || { echo "pages needs the local environment (localenv)" >&2; exit 1; }
    localenv apps apply "$PWD" >/dev/null    # includes the HTTPS route (expose in .localenv.yaml)
    localenv apps image "$PWD" >/dev/null    # Dockerfile, context demos/: the static pages
    localenv apps deploy "$PWD" >/dev/null   # pages.yaml, pinned to the pushed digest
    echo "demo pages: https://catalog-data-store.dev.test (this demo: /data-store/)"
    ;;
  psql)        kubectl -n "$NS" exec -it deploy/psql -- psql ;;
  down)
    if [ "$MODE" = localenv ]; then
      kubectl -n "$NS" delete -f k8s.yaml -f pages.yaml --ignore-not-found
      echo "database $OWNER and its roles are kept. To remove the namespace, database and roles:"
      echo "  localenv apps delete $APP    (drops the data)"
    else
      kubectl delete namespace "$NS"
    fi
    ;;
  *)           sed -n '2,34p' "$0"; exit 1 ;;
esac
