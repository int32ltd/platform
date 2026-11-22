# Demos

Runnable models of the designs in [`../docs/`](../docs/). Each one runs
locally with no vendor accounts. The browser demos need nothing at all; the
data-store demo needs a local Kubernetes cluster (kind is enough).

[`index.html`](./index.html) is a landing page that links to every demo. Open
it in a browser, or it's the root page when this folder is published. Each
demo links back to it.

| Demo | What it shows | Run it | Docs |
|---|---|---|---|
| [`platform-abstraction/`](./platform-abstraction/) | One observability request passing through every layer: contract validation, ownership check, binding policy, simulated vendor calls. Swap the vendor or move ownership and watch what changes. | Open `index.html` in a browser. The same logic also runs as a Python CLI: `pip install pyyaml`, then see its [README](./platform-abstraction/README.md). | [tutorial](../docs/platform-abstraction/tutorial.md) |
| [`data-store/`](./data-store/) | The catalog's PostgreSQL store running in its own Kubernetes namespace, seeded with the ownership demo's graph. A SQL walkthrough moves ownership, tags an orphan, offboards a contractor and breaks a sync, and shows what each person can see after every step. | A Kubernetes cluster (kind is enough) and `kubectl`, then `./demo.sh up && ./demo.sh walkthrough` | [tutorial](../docs/data-store/tutorial.md), [reference](../docs/data-store/reference.md), [explanation](../docs/data-store/explanation.md) |
| [`service-catalog-ownership/`](./service-catalog-ownership/) | An interactive graph of people, identity groups, teams, systems, components and infrastructure, with ownership resolution, visibility rules and OpenFGA tuples computed live. Change who owns what and watch access follow. | Open `index.html` in a browser. No build, no dependencies, no network calls. | [reference](../docs/service-catalog/reference.md), [explanation](../docs/service-catalog/explanation.md) |

Each demo has its own folder. A demo that needs more than "open the file"
gets a `README.md` with setup and commands. When you add a demo, add a card
for it to `index.html` and a "← All demos" link back in its header.
