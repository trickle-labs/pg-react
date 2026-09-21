# pg-mdm stewardship adapter

This optional adapter is disabled in pg-react 0.46.0. It records the approved
`MDM-STEWARDSHIP/1` contract and qualification boundary; it does not call MDM,
read private catalogs, or enable routing, deadlines, escalation, or intent
submission.

The adapter can be implemented after pg-mdm M1 supplies the authorized
`mdm_steward.policy_cases_v1` projection and stable occurrence mapping.
