-- Q3 - Library Returns and Overdue Fines
-- Fine = K2 per day after due date. Return on due date = no fine.

-- (a) Tables
CREATE TABLE IF NOT EXISTS books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL
);

CREATE TABLE IF NOT EXISTS loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
    CHECK (due_on >= borrowed_on),
    CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE IF NOT EXISTS loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0,
    total_fine NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- (b) Function: fine for a loan as of a date
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC(10,2) AS $$
DECLARE
    v_due DATE;
    v_returned DATE;
    v_end DATE;
    v_days INT;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
    END IF;
    -- Use earlier of p_as_of and returned_on when returned
    IF v_returned IS NOT NULL THEN
        v_end := LEAST(p_as_of, v_returned);
    ELSE
        v_end := p_as_of;
    END IF;
    v_days := GREATEST(0, v_end - v_due);
    RETURN (v_days * 2)::NUMERIC(10,2);
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: return a loan, store date + final fine together
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine NUMERIC(10,2);
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date cannot be before borrowed date';
    END IF;
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);
    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger: log changes to returned_on only
CREATE OR REPLACE FUNCTION trg_loan_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_loan_audit ON loans;
CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loan_audit_fn();

-- (a) Seed data: 3 books, 6 loans
INSERT INTO books(title) VALUES
('Database Systems'), ('Introduction to SQL'), ('Data Structures')
ON CONFLICT DO NOTHING;

-- 1 = open overdue, 2 = on-time (will return on due date), 3 = returned late, rest varied
INSERT INTO loans(book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
(1, 'Chanda Mwila', '2026-01-01', '2026-01-10', NULL, 0),
(1, 'Grace Banda', '2026-01-02', '2026-01-12', '2026-01-12', 0),
(2, 'Peter Phiri', '2026-01-03', '2026-01-13', '2026-01-16', 6.00),
(2, 'Mary Zulu', '2026-01-05', '2026-01-15', NULL, 0),
(3, 'John Tembo', '2026-01-06', '2026-01-16', '2026-01-16', 0),
(3, 'Sara Chola', '2026-01-07', '2026-01-17', NULL, 0)
ON CONFLICT DO NOTHING;

-- (e) View: currently unreturned + overdue
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

-- (f) Index: for one book's unreturned loans
-- Justification: Equality on book_id + filter on returned_on IS NULL
-- matches the query exactly, avoids scanning all loans.
CREATE INDEX IF NOT EXISTS idx_loans_book_unreturned
ON loans(book_id) WHERE returned_on IS NULL;

-- Matching query + plan:
-- EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;

-- (g) Scheduled job: refresh overdue summary
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
AS $$
BEGIN
    INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE returned_on IS NULL AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$ LANGUAGE plpgsql;

-- Test refresh:
CALL pr_refresh_overdue(CURRENT_DATE);

-- Schedule daily at 00:10 for CURRENT_DATE (pg_cron):
-- SELECT cron.schedule('refresh-overdue-daily', '10 0 * * *',
--   $$CALL pr_refresh_overdue(CURRENT_DATE)$$);

-- Checks:
SELECT * FROM v_overdue_loans;
SELECT fn_loan_fine(1, CURRENT_DATE);
SELECT * FROM loan_audit;
SELECT * FROM overdue_summary;