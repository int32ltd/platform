#!/usr/bin/env sh
# Run the catalog data-store demo in its own namespace on the current
# Kubernetes cluster (a local kind cluster is enough).
#
#   ./demo.sh up            deploy Postgres 18 (k8s.yaml), (re)create the
#                           `catalog` database and load sql/*.sql
#   ./demo.sh walkthrough   run the guided walkthrough (walkthrough.sql)
#   ./demo.sh test          run the invariant checks (test.sql, rolled back),
#                           then check-page
#   ./demo.sh check-page    check that index.html (the schema page) lists exactly
#                           the tables, views, columns, types and functions
#                           the database has
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

check_page() {
  command -v python3 >/dev/null || { echo 'check-page needs python3'; exit 1; }
  tmp=$(mktemp -d)
  pod_psql "$DB" -At -c "$LIVE_SQL" | LC_ALL=C sort > "$tmp/live"
  python3 -I -c "$PAGE_PY" < index.html > "$tmp/page"
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
    echo "ready: $NS/$POD, database $DB"
    ;;
  walkthrough) pod_psql "$DB" < walkthrough.sql ;;
  test)        pod_psql "$DB" < test.sql && check_page ;;
  check-page)  check_page ;;
  psql)        kubectl -n "$NS" exec -it "$POD" -- psql -U postgres -d "$DB" ;;
  down)        kubectl delete namespace "$NS" ;;
  *)           sed -n '2,17p' "$0"; exit 1 ;;
esac
