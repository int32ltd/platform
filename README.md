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
| [`docs/platform-abstraction/`](./docs/platform-abstraction/) | The design, written as a [Diátaxis](https://diataxis.fr) doc set: tutorial, how-to guides, reference, and explanation. Start at its [README](./docs/platform-abstraction/README.md). |
| [`docs/service-catalog/`](./docs/service-catalog/) | Detailed design of the service catalog: kinds, resources, links, identity-group-derived permissions, ingestion, agent query surface. Start at its [README](./docs/service-catalog/README.md). |
| [`demo/`](./demo/) | A tiny Python simulation of the architecture. One capability (observability) modeled end to end with two fake providers. See the [demo README](./demo/README.md). |

## Quick start

The demo needs Python 3 and one dependency:

```
pip install pyyaml
cd demo
python3 platform.py apply requests/checkout-latency.yaml \
  --component checkout-service --team team-payments \
  --tenant team-growth --environment production
```

It prints each layer the request passes through: contract validation,
ownership and policy check, provider binding, and the simulated vendor calls.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](./CONTRIBUTING.md) first.
Every contributor signs the [Contributor License Agreement](./CLA.md) once,
by commenting on their first pull request. A bot handles the rest.

## License

Licensed under the [Apache License 2.0](./LICENSE). See [NOTICE](./NOTICE).
