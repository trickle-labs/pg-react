//! Portable identity for the M0 non-null `bigint` semantic key.

use sha2::{Digest, Sha256};
use uuid::Uuid;

pub const BIGINT_CODEC_V1: u8 = 1;
pub const BIGINT_TYPE_TAG: u8 = 1;
const BIGINT_BYTES: u32 = 8;

/// Fixed v1 fixture for SQL parity: nil rule-version UUID and semantic key `42`.
pub const SQL_PARITY_RULE_VERSION: &str = "00000000-0000-0000-0000-000000000000";
pub const SQL_PARITY_CANONICAL_KEY: [u8; 14] = [1, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 42];
pub const SQL_PARITY_DIGEST_HEX: &str =
    "8307bd70b28711d35b356a1df7c9bb606b720b2be74025b0d2c7dab15f4fa23e";
pub const SQL_PARITY_ACTIVATION_ID: &str = "8307bd70-b287-81d3-9b35-6a1df7c9bb60";

/// Codec v1: codec version, type tag, 32-bit network-order length, signed i64 bytes.
pub fn encode_bigint_v1(value: i64) -> Vec<u8> {
    let mut encoded = Vec::with_capacity(14);
    encoded.extend([BIGINT_CODEC_V1, BIGINT_TYPE_TAG]);
    encoded.extend(BIGINT_BYTES.to_be_bytes());
    encoded.extend(value.to_be_bytes());
    encoded
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivationIdentity {
    pub activation_id: Uuid,
    pub canonical_key: Vec<u8>,
    pub digest: [u8; 32],
}

/// Derives a stable private-use UUID (version 8) from the complete SHA-256 digest.
pub fn activation_identity(rule_version: Uuid, key: i64) -> ActivationIdentity {
    let canonical_key = encode_bigint_v1(key);
    let mut hasher = Sha256::new();
    hasher.update(rule_version.as_bytes());
    hasher.update(&canonical_key);
    let digest: [u8; 32] = hasher.finalize().into();
    let mut bytes: [u8; 16] = digest[..16].try_into().expect("digest prefix");
    bytes[6] = (bytes[6] & 0x0f) | 0x80; // UUID version 8: application-defined.
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant.
    ActivationIdentity {
        activation_id: Uuid::from_bytes(bytes),
        canonical_key,
        digest,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bigint_codec_is_versioned_and_network_order() {
        assert_eq!(
            encode_bigint_v1(-1),
            vec![1, 1, 0, 0, 0, 8, 255, 255, 255, 255, 255, 255, 255, 255]
        );
        assert_eq!(&encode_bigint_v1(42)[6..], &42_i64.to_be_bytes());
    }

    #[test]
    fn identity_is_deterministic_and_rfc_compatible() {
        let rule = Uuid::nil();
        let first = activation_identity(rule, 42);
        assert_eq!(first, activation_identity(rule, 42));
        assert_ne!(first, activation_identity(rule, 43));
        assert_eq!(first.canonical_key, SQL_PARITY_CANONICAL_KEY);
        assert_eq!(
            first.digest,
            [
                0x83, 0x07, 0xbd, 0x70, 0xb2, 0x87, 0x11, 0xd3, 0x5b, 0x35, 0x6a, 0x1d, 0xf7, 0xc9,
                0xbb, 0x60, 0x6b, 0x72, 0x0b, 0x2b, 0xe7, 0x40, 0x25, 0xb0, 0xd2, 0xc7, 0xda, 0xb1,
                0x5f, 0x4f, 0xa2, 0x3e,
            ]
        );
        assert_eq!(
            SQL_PARITY_DIGEST_HEX,
            "8307bd70b28711d35b356a1df7c9bb606b720b2be74025b0d2c7dab15f4fa23e"
        );
        assert_eq!(first.activation_id.to_string(), SQL_PARITY_ACTIVATION_ID);
        assert_eq!(first.activation_id.get_version_num(), 8);
        assert_eq!(first.activation_id.get_variant(), uuid::Variant::RFC4122);
    }
}
