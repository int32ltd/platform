#!/usr/bin/env sh
# Run the catalog data-store demo in its own namespace on the current
# Kubernetes cluster (a local kind cluster is enough).
#
#   ./demo.sh up            deploy Postgres 18 (k8s.yaml), (re)create the
#                           `catalog` database and load sql/*.sql
#   ./demo.sh walkthrough   run the guided walkthrough (walkthrough.sql)
#   ./demo.sh test          run the invariant checks (test.sql, rolled back)
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
  test)        pod_psql "$DB" < test.sql ;;
  psql)        kubectl -n "$NS" exec -it "$POD" -- psql -U postgres -d "$DB" ;;
  down)        kubectl delete namespace "$NS" ;;
  *)           sed -n '2,13p' "$0"; exit 1 ;;
esac
