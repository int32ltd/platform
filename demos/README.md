# Demos

Runnable models of the designs in [`../docs/`](../docs/). Each one runs
locally with no infrastructure and no vendor accounts.

| Demo | What it shows | Run it | Docs |
|---|---|---|---|
| [`platform-abstraction/`](./platform-abstraction/) | One observability request passing through every layer: contract validation, ownership check, binding policy, simulated vendor calls. Swap the vendor or move ownership and watch what changes. | Open `index.html` in a browser. The same logic also runs as a Python CLI: `pip install pyyaml`, then see its [README](./platform-abstraction/README.md). | [tutorial](../docs/platform-abstraction/tutorial.md) |
| [`service-catalog-ownership/`](./service-catalog-ownership/) | An interactive graph of people, identity groups, teams, systems, components and infrastructure, with ownership resolution, visibility rules and OpenFGA tuples computed live. Change who owns what and watch access follow. | Open `index.html` in a browser. No build, no dependencies, no network calls. | [reference](../docs/service-catalog/reference.md), [explanation](../docs/service-catalog/explanation.md) |

Each demo has its own folder. A demo that needs more than "open the file"
gets a `README.md` with setup and commands.
