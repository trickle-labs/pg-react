# Deprecations

The current release is pg-react `0.43.0`. No ordinary public function is
removed in M54. Existing UUID-oriented replacement and recovery functions are
compatibility or administrative paths; ordinary application code should use
stable names, `preview`, `review_token`, and `deploy`.

When a future release deprecates an ordinary function, its replacement,
migration, and removal horizon will be recorded here and in release notes.
