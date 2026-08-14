# M18 fixture manifest

The canonical manifest is `tests/fixtures/m18/manifest.json`; the public small
transcript is `tests/fixtures/m18/expected-small-transcript.txt`. The manifest
pins versions, platform/configuration, deterministic clock inputs, roles,
workloads, named benchmark cases, entry-release identities, and frozen faults.

Profiles are explicit: `small` is the authoring oracle; `complete` is the named
non-Cartesian benchmark and recovery profile. Exact public state is asserted by
the SQL fixtures named in the manifest rather than copied into prose.
