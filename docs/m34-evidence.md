# M34 evidence

The M34 qualification lane is `tests/m34.sh complete`. It checks the exact
upgrade pair, a populated `0.30.0 -> 0.31.0` update and rollback-by-restore,
documentation metadata,
executable comparison examples, bounded evidence, role/search-path safety,
no-effect checksums across rule, decision, policy, limit, and error paths, and
the inherited M33 lane when its image is available.

The SQL fixture covers:

- unchanged shape plus added, removed, and changed rule results;
- relational `current`, `proposed`, `delta`, `lifecycle`, and `work` rows;
- exact versus truncated evidence;
- sampled frontier and declaration-digest metadata;
- unchanged authoritative checksums before and after comparison;
- no durable work, deployment, or external effect;
- RLS rejection, security-definer search paths, and the M34 finding registry.

The candidate Docker lane is the evidence source for a packaged artifact. The
release workflow builds the exact M33 predecessor from its recorded baseline
commit when a published `v0.30.0` image is not available. If Docker or that
baseline cannot be built, the script reports the fact and does not claim
external qualification.
