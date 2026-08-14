# M18 upgrade

M18 ships extension `0.15.0` with direct upgrade `0.14.0 -> 0.15.0` only.
`tests/m18-upgrade.sql` compares the unchanged public rule status, explanation,
and watermark before and after the administrator update, then applies new input
and verifies the exact aggregate result. The public inventory, grants, and
recovery contracts remain covered by the inherited gates and M18 matrix.

Rollback is restore of the verified pre-upgrade physical backup; SQL downgrade
is unsupported.
