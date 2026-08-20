\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- The fixture gives each scenario a named order: an initial match, a proposed
-- match, a full lifecycle, and an ineligible high-risk order.
INSERT INTO app.customers (customer_id, chargeback_count, account_status) VALUES
    (501, 1, 'OPEN'),
    (502, 0, 'OPEN'),
    (503, 0, 'OPEN'),
    (504, 0, 'SUSPENDED');

INSERT INTO app.orders (
    order_id, customer_id, customer_chargeback_count, customer_account_status,
    merchant_id, amount, risk_level, status, review_deadline
) VALUES
    (1001, 501, 1, 'OPEN',      9001, 1500.00, 'HIGH', 'PENDING', '2026-08-20 12:30:00+00'),
    (1002, 502, 0, 'OPEN',      9001,  750.00, 'HIGH', 'PENDING', '2026-08-20 13:00:00+00'),
    (1003, 503, 0, 'OPEN',      9002, 1200.00, 'LOW',  'PENDING', '2026-08-20 13:30:00+00'),
    (1004, 504, 0, 'SUSPENDED', 9002, 2000.00, 'HIGH', 'PENDING', '2026-08-20 14:00:00+00');

INSERT INTO app.payment_attempts (
    payment_attempt_id, order_id, outcome, attempted_at
) VALUES
    (7001, 1001, 'APPROVED', '2026-08-20 12:00:00+00'),
    (7002, 1002, 'DECLINED', '2026-08-20 12:01:00+00'),
    (7003, 1003, 'FAILED',   '2026-08-20 12:02:00+00'),
    (7004, 1003, 'FAILED',   '2026-08-20 12:03:00+00'),
    (7005, 1004, 'APPROVED', '2026-08-20 12:04:00+00');

INSERT INTO app.reviewer_candidates (
    order_id, reviewer_id, priority, queue_name
) VALUES
    (1001, 201, 1, 'chargeback-review'),
    (1001, 202, 2, 'general-review'),
    (1002, 203, 1, 'east-review'),
    (1002, 204, 1, 'west-review'),
    (1003, 205, 1, 'general-review');

INSERT INTO app.failure_controls (order_id, fail_review_task) VALUES
    (1001, false),
    (1002, false),
    (1003, false),
    (1004, false);