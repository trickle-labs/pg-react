# M35 benchmark profile

The qualification fixture measures a small source table and the configured
change limit. The public cost object reports rows considered, hypothetical
rows, affected subjects, reevaluation, elapsed time, memory when available,
and temporary storage.

M35 publishes limits of 1000 evidence rows and 1000 ordered row changes. These
are safety limits, not a latency promise. A complete result exposes exact
counts. A bounded result reports `partial` and identifies the requested limit.
