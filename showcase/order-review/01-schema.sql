\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- The app schema holds business data and rows written by consequences.
CREATE SCHEMA app;
-- Rule conditions and consequence functions use separate schemas.
CREATE SCHEMA rule_def;
CREATE SCHEMA rule_action;

CREATE TABLE app.customers (
    customer_id bigint PRIMARY KEY,
    chargeback_count integer NOT NULL CHECK (chargeback_count >= 0),
    account_status text NOT NULL CHECK (account_status IN ('OPEN', 'SUSPENDED'))
);

CREATE TABLE app.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES app.customers (customer_id),
    customer_chargeback_count integer NOT NULL CHECK (customer_chargeback_count >= 0),
    customer_account_status text NOT NULL CHECK (customer_account_status IN ('OPEN', 'SUSPENDED')),
    merchant_id bigint NOT NULL,
    amount numeric(12,2) NOT NULL CHECK (amount >= 0),
    risk_level text NOT NULL CHECK (risk_level IN ('LOW', 'HIGH')),
    status text NOT NULL CHECK (status IN ('PENDING', 'RELEASED', 'CANCELLED')),
    review_deadline timestamptz
);

CREATE FUNCTION app.sync_customer_order_facts()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE app.orders
    SET customer_chargeback_count = NEW.chargeback_count,
        customer_account_status = NEW.account_status
    WHERE customer_id = NEW.customer_id;
    RETURN NEW;
END;
$$;

-- A customer change becomes an order change, so the rule can watch one view.
CREATE TRIGGER sync_customer_order_facts
AFTER UPDATE OF chargeback_count, account_status ON app.customers
FOR EACH ROW
WHEN (
    OLD.chargeback_count IS DISTINCT FROM NEW.chargeback_count
    OR OLD.account_status IS DISTINCT FROM NEW.account_status
)
EXECUTE FUNCTION app.sync_customer_order_facts();

CREATE TABLE app.payment_attempts (
    payment_attempt_id bigint PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES app.orders (order_id),
    outcome text NOT NULL CHECK (outcome IN ('APPROVED', 'DECLINED', 'FAILED')),
    attempted_at timestamptz NOT NULL
);

CREATE TABLE app.reviewer_candidates (
    order_id bigint NOT NULL REFERENCES app.orders (order_id),
    reviewer_id bigint NOT NULL,
    priority bigint NOT NULL CHECK (priority >= 0),
    queue_name text NOT NULL,
    PRIMARY KEY (order_id, reviewer_id)
);

CREATE TABLE app.review_tasks (
    order_id bigint NOT NULL REFERENCES app.orders (order_id),
    generation bigint NOT NULL CHECK (generation > 0),
    state text NOT NULL CHECK (state IN ('OPEN', 'CLOSED')),
    reason_code text NOT NULL,
    amount numeric(12,2) NOT NULL CHECK (amount >= 0),
    activation_id uuid NOT NULL,
    last_revision bigint NOT NULL CHECK (last_revision >= 0),
    last_idempotency_key text NOT NULL UNIQUE,
    PRIMARY KEY (order_id, generation)
);

-- This flag makes the retry scenario deterministic without a remote service.
CREATE TABLE app.failure_controls (
    order_id bigint PRIMARY KEY REFERENCES app.orders (order_id),
    fail_review_task boolean NOT NULL
);