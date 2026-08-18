//! Pure, PostgreSQL-independent M0 lifecycle semantics.

#[cfg(feature = "pg18")]
pgrx::pg_module_magic!();

pub mod managed;

#[cfg(feature = "pg18")]
mod rewrite;

pub mod identity;
pub mod lifecycle;
pub mod oracle;
