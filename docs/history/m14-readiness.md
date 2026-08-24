# M14 readiness

The `0.11.0` repository candidate implements M14’s diagnosis, unified evidence, and inferred positive derived-program authoring. Run `tests/m14.sh pg-react:v0.11.0`, then tag and push `v0.11.0`. The release workflow rebuilds the image, reruns the gate, and publishes the archive, checksum, and OCI digest.

M15 is already defined: managed workers, broader semantic keys, final public inventory, and complete workflow qualification. Do not start it until the `v0.11.0` release artifacts and M15 entry fixture are immutable.

