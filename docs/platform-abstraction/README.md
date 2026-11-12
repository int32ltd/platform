# Platform Capability Abstraction

How the platform exposes every capability (observability, CI/CD, compute, data,
networking, secrets, identity, ...) to developers through a stable, vendor-neutral
contract — while letting the platform team swap the underlying implementation
(Datadog ↔ Dynatrace, GitHub Actions ↔ Jenkins ↔ Argo Workflows, AWS ↔ GCP, ...)
without touching developer-facing config, and letting service/code ownership move
between teams without re-provisioning access in every tool by hand.

Diagram: [`abstraction-layers.drawio`](./abstraction-layers.drawio) — open in
[diagrams.net](https://app.diagrams.net) or the VS Code Draw.io extension.
It has three pages: *Capability Abstraction Layers*, *C4 Container View
(technology-agnostic)*, and *System layers* (the full capability map).

This doc set follows the [Diátaxis](https://diataxis.fr) framework — four
documents, each answering a different kind of question:

| Quadrant | Question it answers | Document |
|---|---|---|
| Tutorial | "Walk me through building one, start to finish" | [tutorial.md](./tutorial.md) |
| How-to guides | "How do I do X?" | [how-to-guides.md](./how-to-guides.md) |
| Reference | "What exactly is the schema / API / mapping?" | [reference.md](./reference.md) |
| Explanation | "Why is it built this way?" | [explanation.md](./explanation.md) |

## The shape of it, in one paragraph

Every capability is split into three independent layers: a **capability
contract** (the vendor-neutral schema developers and golden-path templates
consume), a **policy & ownership graph** (who owns what, who may do what —
backed by a policy engine, never by a vendor's native IAM), and **provider
adapters** that realize the contract against a concrete vendor. A git-versioned
**binding policy** decides which adapter answers which contract, per tenant /
environment / region. Changing a vendor means changing the binding policy, not
the developer-facing surface. Moving ownership means mutating the graph, not
re-provisioning six different tools.
