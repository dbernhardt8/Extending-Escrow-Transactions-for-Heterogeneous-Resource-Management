-- =============================================================================
-- 9.0_minimal_concurrency_sandbox.sql
--
-- Minimal concurrency sandbox for RESERVABLE counters.
-- Create and run this in a separate schema if desired.
-- No commits are issued; manage commits manually during tests.
-- =============================================================================

SET SERVEROUTPUT ON;

-- Minimal capacity table with a RESERVABLE column
CREATE TABLE MiniCapacity(
    id NUMBER PRIMARY KEY,
    total_capacity NUMBER NOT NULL,
    available_capacity NUMBER RESERVABLE NOT NULL,
    CONSTRAINT chk_available_nonnegative CHECK (available_capacity >= 0) DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT chk_available_max CHECK (available_capacity <= total_capacity) DEFERRABLE INITIALLY DEFERRED
);

CREATE OR REPLACE PACKAGE MiniEscrow AUTHID CURRENT_USER AS
  PROCEDURE ReserveCapacity(p_id IN NUMBER, p_amount IN NUMBER);
  PROCEDURE ReleaseCapacity(p_id IN NUMBER, p_amount IN NUMBER);
END MiniEscrow;
/

CREATE OR REPLACE PACKAGE BODY MiniEscrow AS

  PROCEDURE ReserveCapacity(p_id IN NUMBER, p_amount IN NUMBER) IS
  BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
      RAISE_APPLICATION_ERROR(-20901, 'Reserve amount must be > 0.');
    END IF;

    UPDATE MiniCapacity
    SET available_capacity = available_capacity - p_amount
    WHERE id = p_id;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20902, 'Capacity row not found for id: ' || p_id);
    END IF;
  END ReserveCapacity;

  PROCEDURE ReleaseCapacity(p_id IN NUMBER, p_amount IN NUMBER) IS
  BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
      RAISE_APPLICATION_ERROR(-20903, 'Release amount must be > 0.');
    END IF;

    UPDATE MiniCapacity
    SET available_capacity = available_capacity + p_amount
    WHERE id = p_id;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20904, 'Capacity row not found for id: ' || p_id);
    END IF;
  END ReleaseCapacity;

END MiniEscrow;
/

-- Optional seed example (uncomment if needed)
INSERT INTO MiniCapacity(id, total_capacity, available_capacity)
VALUES (1, 10, 10);
COMMIT;

BEGIN
  MINIESCROW.RESERVECAPACITY(p_id => 1, p_amount => 10);
END;
/

BEGIN
  MINIESCROW.RELEASECAPACITY(p_id => 1, p_amount => 1);
END;
/