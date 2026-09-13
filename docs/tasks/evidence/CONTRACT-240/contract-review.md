# CONTRACT-240 review

The contract was checked against the current evidence store, directory scanner,
persistent monitoring probe, FSEvents collector, optional Endpoint Security
bridge, provenance engine, agent-session registry, exporter, app query backend,
and MCP catalog.

The normative result is:

- immutable observations and changes explain history;
- an atomic `CurrentFileState` projection answers what exists now;
- stable filesystem identity plus temporal path bindings distinguish rename,
  replacement, deletion, and path reuse;
- absence proves deletion only after complete same-scope coverage;
- partial coverage creates uncertainty and a durable gap;
- provenance claims and session context are persisted separately and never
  promote inference into an exact actor;
- retention compacts historical precision without changing current truth;
- all MCP filters run before limit and privacy shaping; and
- manual exports remain user-owned while MCP temporaries are destroyed.

`abc-complete-deletion.json` and `abc-partial-observation.json` encode the
load-bearing difference between deleting B and merely failing to observe B.
Both fixtures validate against `reconciliation-scenario-v1.schema.json`.
