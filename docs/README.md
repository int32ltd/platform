# Documentation

Each topic is written as a [Diátaxis](https://diataxis.fr) doc set, so every
document answers one kind of question:

| | Tutorial<br>*learn by doing* | How-to guides<br>*do a task* | Reference<br>*look it up* | Explanation<br>*understand why* |
|---|---|---|---|---|
| [**Platform abstraction**](./platform-abstraction/) | [tutorial.md](./platform-abstraction/tutorial.md) | [how-to-guides.md](./platform-abstraction/how-to-guides.md) | [reference.md](./platform-abstraction/reference.md) | [explanation.md](./platform-abstraction/explanation.md) |
| [**Service catalog**](./service-catalog/) | the [ownership demo](../demos/service-catalog-ownership/) | — | [reference.md](./service-catalog/reference.md) | [explanation.md](./service-catalog/explanation.md) |

**Platform abstraction** is the overall design: how every capability is
exposed through a vendor-neutral contract, with a binding policy choosing the
vendor and an ownership graph deciding access.

**Service catalog** is the detailed design of that ownership graph (Layer 3):
kinds, resources and links, access derived from identity groups, ingestion,
and the query surface for agents.

Runnable demos live in [`../demos/`](../demos/), not here. Docs link to them.

## Conventions

- One folder per topic, containing `README.md` plus one file per Diátaxis
  quadrant the topic has. Leave out a quadrant rather than writing a
  placeholder.
- Diagrams go in the topic's `diagrams/` folder as `*.drawio.png`, exported
  from draw.io with the source embedded, so the PNG is the editable file.
  Name them in kebab-case.
