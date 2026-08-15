# M20 compact tasks

Author:

1. Create an owned source view and matching composite row type.
2. Run `validate_shared_condition` and record `preview_shared_condition`.
3. Deploy with the preview digest and register each rule/program consumer.
4. Grant value readers separately; use `shared_condition_status`, `cost`, and
   `explain` for bounded inspection.

Operator:

1. Run `doctor()` after deployment, restart, restore, or source DDL.
2. Reconcile drift through `reconcile_shared_condition`; do not edit private
   catalogs or generated relations.
3. Remove consumers before removing a shared condition.
