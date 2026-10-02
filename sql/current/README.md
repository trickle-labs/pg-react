# Current SQL

`assembly.txt` lists the frozen 0.46.0 predecessor followed by the 0.46.1
claim correction in `claim.sql` and the managed-worker grants in
`worker-grants.sql`. The adjacent upgrade manifest applies those same corrections.
Published install/upgrade history remains byte-for-byte frozen.

Starting from the actual published predecessor preserves coordinator locking
and the package-preview patch that differ from the older 0.43.3-based assembly.
