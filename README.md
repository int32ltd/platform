# Platform

A design for a vendor-neutral internal developer platform, plus a small
runnable demo of it.

The platform exposes every capability (observability, CI/CD, compute, data,
networking, secrets, identity, ...) to developers through a stable contract.
The platform team can swap the underlying vendor (Datadog to Dynatrace, GitHub
Actions to Argo Workflows, AWS to GCP) without touching developer-facing
config, and service ownership can move between teams without re-provisioning
access in every tool by hand.

## Repository layout

| Path | What it is |
|---|---|
| [`docs/`](./docs/) | The design, one folder per topic, each written as a [Diátaxis](https://diataxis.fr) doc set. Start at the [docs index](./docs/README.md). |
| [`docs/platform-abstraction/`](./docs/platform-abstraction/) | The overall design: tutorial, how-to guides, reference, explanation. |
| [`docs/service-catalog/`](./docs/service-catalog/) | The detailed design of the service catalog: kinds, resources, links, identity-group-derived permissions, ingestion, agent query surface. |
| [`docs/data-store/`](./docs/data-store/) | The PostgreSQL database behind the service catalog: tables, ownership and membership derivation, the permission-filtered read surface, the change log and outbox. |
| [`demos/`](./demos/) | Runnable models of the designs, one folder per demo. See the [demos index](./demos/README.md). |

## Quick start

The fastest way in is the [tutorial](./docs/platform-abstraction/tutorial.md),
which runs the platform-abstraction demo. It needs Python 3 and one
dependency:

```
pip install pyyaml
cd demos/platform-abstraction
python3 platform.py apply requests/checkout-latency.yaml \
  --component checkout-service --team team-payments \
  --tenant team-growth --environment production
```

It prints each layer the request passes through: contract validation,
ownership and policy check, provider binding, and the simulated vendor calls.
To skip the install, open
[`demos/platform-abstraction/index.html`](./demos/platform-abstraction/index.html)
in a browser instead. It's the same simulation with every file editable.

For the service catalog, open
[`demos/service-catalog-ownership/index.html`](./demos/service-catalog-ownership/index.html)
in a browser. For the database behind it, run
[`demos/data-store/`](./demos/data-store/) (runs on the local kind environment, localenv):
`./demo.sh up && ./demo.sh walkthrough`.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](./CONTRIBUTING.md) first.
Every contributor signs the [Contributor License Agreement](./CLA.md) once,
by commenting on their first pull request. A bot handles the rest.

## License

Licensed under the [Apache License 2.0](./LICENSE). See [NOTICE](./NOTICE).
