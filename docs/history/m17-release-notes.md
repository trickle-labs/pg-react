# pg-react 0.14.0 release notes

M17 adds fixed UTC-epoch event-time tumbling windows to M16 aggregate
dependencies. Durable requested/complete watermarks, bounded finalization,
ordered replay-safe corrections, late-input barriers, finite evidence, audited
retention, and logical recovery are public and role-checked.

Unwindowed declarations, typed aggregate semantics, lifecycle identity,
worker protocol, consequence delivery, and every M0–M16 compatibility boundary
remain unchanged. Upgrade directly from `0.13.0`; rollback requires the
verified pre-upgrade physical backup.
