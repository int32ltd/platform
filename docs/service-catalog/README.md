# Service Catalog

The resource-and-link store at the centre of the platform: ingested from
many sources, queried by agents, reports, scorecards and self-service actions,
with access derived from the graph itself (resource → owning team → identity group →
member).

- [design.md](./design.md) — data model, permission model, ingestion, query
  surface, derived data, storage, open decisions.
- [Service Catalog Components.drawio.png](./Service%20Catalog%20Components.drawio.png)
  — component diagram, exported from draw.io with the source embedded (open
  the PNG in diagrams.net to edit).

This is the detailed design of Layer 3 in
[`../platform-abstraction/`](../platform-abstraction/README.md).
