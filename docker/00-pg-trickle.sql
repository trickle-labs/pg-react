CREATE EXTENSION IF NOT EXISTS pg_trickle;
\getenv pg_react_init_version PG_REACT_INIT_VERSION
SELECT format(
  'CREATE EXTENSION IF NOT EXISTS pg_react VERSION %L',
  :'pg_react_init_version'
)
\gexec
