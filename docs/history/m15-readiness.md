# M15 readiness

The `0.12.0` repository candidate implements M15's managed runtime, portable
typed semantic keys, final public inventory and grants, complete documentation,
and executable usability qualification. Run `tests/m15.sh pg-react:v0.12.0`,
then tag and push `v0.12.0`; the release workflow rebuilds and publishes the
archive, checksum manifest, and OCI digest.

No post-M15 milestone is committed. M16, richer stratified aggregation, is the
logical next proposal: freeze `COUNT(expression)` first and promote M16 only
after `v0.12.0` artifacts and a bounded executable entry fixture are immutable.
