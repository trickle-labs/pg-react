# Compatibility

The current release is pg-react `0.43.1`. Valid ordinary calls are
compatibility-preserving across adjacent 0.x releases by project policy.
Existing JSON-preconditions deployment calls, specialized authoring APIs,
compatibility replacement functions, and historical documents remain
reachable.

New ordinary behavior is additive. Removal requires a documented replacement
and deprecation releases unless retaining it would preserve unsafe behavior.
Private schemas and internal catalogs are outside the compatibility promise.
