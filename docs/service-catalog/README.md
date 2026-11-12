# Service Catalog

The entity-and-relationship store at the centre of the platform: ingested from
many sources, queried by agents, reports, scorecards and self-service actions,
with access derived from the graph itself (entity → owning team → AD group →
member).

- [design.md](./design.md) — data model, permission model, ingestion, query
  surface, derived data, storage, open decisions.

This is the detailed design of Layer 3 in
[`../platform-abstraction/`](../platform-abstraction/README.md).
