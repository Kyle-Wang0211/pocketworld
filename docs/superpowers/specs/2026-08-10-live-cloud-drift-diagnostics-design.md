# Live-cloud Drift Diagnostics Design

The approved design is the OpenSpec change at
`openspec/changes/add-live-cloud-drift-diagnostics-v1/`.

It adds four observation-only evidence streams: complete ARKit subject-anchor
delta, live-cloud receive/render generations, streaming BA camera-center deltas
against immutable ARKit seeds, and exact app/Dart/native build identity. It does
not correct or suppress any drift. Deployment is an in-place update of the
existing production bundle only after verified `Documents` and `Library`
backups.

The approved V2 extension adds two more native, observation-only streams at each
post-local-BA and successful post-global-BA model state: a robust best Sim3
between optimized BA camera centers and immutable ARKit camera centers, and exact
same-ID Point3D displacement/churn against the immediately previous native model
state. Both fail open and cannot modify reconstruction, publication, or render
inputs.
