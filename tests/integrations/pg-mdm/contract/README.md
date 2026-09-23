# Contract qualification seam

Run the canonical exact-output contract check from the repository root:

```text
python3 tests/mdm_stewardship_contract.py
```

This proves the approved contract and vectors only. Joint live qualification
against pg-mdm v0.13.1, including the authorized policy-case projection and
occurrence mapping, is recorded in
[`../evidence/v0.47.0/manifest.json`](../evidence/v0.47.0/manifest.json).
