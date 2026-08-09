\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
CREATE SCHEMA app;
CREATE SCHEMA rule_def;
CREATE SCHEMA rule_action;
CREATE TABLE app.customers (id bigint PRIMARY KEY, risk_level text NOT NULL);
CREATE TABLE app.orders (id bigint PRIMARY KEY, customer_id bigint NOT NULL REFERENCES app.customers, amount numeric NOT NULL);
CREATE TABLE app.manual_review_tasks (
    activation_id uuid PRIMARY KEY,
    order_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    amount numeric NOT NULL,
    condition_active boolean NOT NULL
);

-- README: "A rule in three steps", copied verbatim.
CREATE VIEW rule_def.high_value_risky_order AS
SELECT
    o.id          AS order_id,
    o.customer_id AS customer_id,
    o.amount
FROM app.orders AS o
JOIN app.customers AS c ON c.id = o.customer_id
WHERE o.amount > 10000
  AND c.risk_level = 'HIGH';

CREATE FUNCTION rule_action.open_review(
    context pgreact.activation_context,
    match   rule_def.high_value_risky_order
)
RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    INSERT INTO app.manual_review_tasks (
        activation_id, order_id, customer_id, amount, condition_active
    )
    VALUES (
        (context).activation_id,
        (match).order_id,
        (match).customer_id,
        (match).amount,
        true
    )
    ON CONFLICT (activation_id) DO UPDATE
       SET customer_id = EXCLUDED.customer_id,
           amount = EXCLUDED.amount,
           condition_active = true;
END;

SELECT pgreact.create_rule(
    name        => 'manual_review_required',
    definition  => 'rule_def.high_value_risky_order'::regclass,
    key_columns => ARRAY['order_id'],
    on_activate => 'rule_action.open_review(
        pgreact.activation_context,
        rule_def.high_value_risky_order
    )'::regprocedure
);

INSERT INTO app.customers VALUES (7, 'HIGH');
INSERT INTO app.orders VALUES (42, 7, 15000);
