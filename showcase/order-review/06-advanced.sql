\set ON_ERROR_STOP on

-- These chapters are named here so the example is explicit about its limits.
-- Advanced chapters are intentionally omitted from the 0.43.0 showcase.
-- Add one only after its specialized public API and exact transcript pass in
-- the qualified PostgreSQL 18.3 and pg_trickle 0.81.0 Docker environment.

SELECT jsonb_build_object(
	'step', 'advanced chapters',
	'state', 'omitted',
	'chapters', jsonb_build_array(
		'deadline escalation',
		'derived facts and provenance',
		'effective-dated policy versions'
	),
	'reason', 'no specialized API call is qualified by this fixture'
);
