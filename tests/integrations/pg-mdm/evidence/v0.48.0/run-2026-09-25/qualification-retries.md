# Qualification retry record

The first repair runs hit setup failures only; the clean final container completed
the v0.48 qualification lanes without a failed assertion.

| Attempt | Exit | Captured diagnostic | Resolution |
| --- | ---: | --- | --- |
| Targeted upgrade fixture | 3 | `ERROR: schema "pgreact_mdm" does not exist` | Added the isolated fixture schema bootstrap. |
| Full qualification setup | 3 | `ERROR: relation "pgreact_mdm.policy_packages" does not exist` | Added the predecessor policy-input and package setup. |
| Full qualification setup | 3 | `ERROR: function pgreact_mdm.route_cases(regclass, text, text) does not exist` | Added the predecessor routing, deadline, and comparison SQL. |

The final clean run passed the live, security, restore, admission, codec, and
v0.47 live lanes. The final logs and hashes are listed in `manifest.json`.
