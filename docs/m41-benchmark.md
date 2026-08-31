# M41 benchmark

The semantic limits are fixed and do not change with runtime speed:

| Measure | Limit |
| --- | ---: |
| Nodes | 256 |
| Edges | 512 |
| Paths | 64 |
| Depth | 16 |
| Support fan-out | 64 |
| Payload bytes | 65536 |

`cost` reports roots, nodes, edges, paths, support expansion, depth, fan-out,
boundary checks, and separately measured elapsed milliseconds. The published
benchmark profile covers direct source rows, derived layers, converged support,
and the published limits. A reached limit is `partial` and never claims an
omitted count.
