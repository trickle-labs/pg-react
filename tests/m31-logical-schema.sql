\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m31_recovery;
CREATE TABLE m31_recovery.orders(
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL);
CREATE VIEW m31_recovery.orders_match AS
SELECT order_id, customer_id FROM m31_recovery.orders;
CREATE TABLE m31_recovery.gate(customer_id bigint PRIMARY KEY);
CREATE TABLE m31_recovery.control(state jsonb NOT NULL);
