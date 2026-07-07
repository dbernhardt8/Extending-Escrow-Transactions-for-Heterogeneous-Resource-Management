-- =============================================================================
-- TEST_add_asset_from_json.sql
--
-- Test script for adding a complete asset from JSON
-- Demonstrates the AddCompleteAssetFromJSON procedure
-- =============================================================================

SET SERVEROUTPUT ON;

DECLARE
    v_json_data CLOB;
    v_new_asset_id NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('    TEST: Add Complete Asset from JSON');
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('');
    
    -- Define JSON data inline (in production, this would be read from file or API)
    v_json_data := '{
  "asset": {
    "name": "Boeing 787-9",
    "description": "Dreamliner - D-ABCE",
    "status": "active",
    "metadata": {
      "registration": "D-ABCE",
      "manufacturer": "Boeing",
      "model": "787-9",
      "year_manufactured": 2024,
      "configuration": "premium_layout",
      "range_km": 14140,
      "max_speed_kmh": 954
    }
  },
  "capacities": [
    {
      "category_name": "First Class",
      "quantity": 8,
      "metadata": {
        "layout": "1-1-1",
        "pitch_inches": 82,
        "width_inches": 21
      }
    },
    {
      "category_name": "Business Class",
      "quantity": 36,
      "metadata": {
        "layout": "1-2-1",
        "pitch_inches": 78,
        "width_inches": 20
      }
    },
    {
      "category_name": "Premium Economy",
      "quantity": 21,
      "metadata": {
        "layout": "2-3-2",
        "pitch_inches": 38,
        "width_inches": 18
      }
    },
    {
      "category_name": "Economy Class",
      "quantity": 21,
      "metadata": {
        "layout": "3-3-3",
        "pitch_inches": 32,
        "width_inches": 17
      }
    }
  ],
  "instances": [
    {
      "category_name": "First Class",
      "seats": [
        {"identifier": "1A", "status": "available", "metadata": {"type": "window", "row": 1, "features": ["lie-flat", "direct_aisle_access"]}},
        {"identifier": "1K", "status": "available", "metadata": {"type": "window", "row": 1, "features": ["lie-flat", "direct_aisle_access"]}},
        {"identifier": "2A", "status": "available", "metadata": {"type": "window", "row": 2, "features": ["lie-flat", "direct_aisle_access"]}},
        {"identifier": "2E", "status": "available", "metadata": {"type": "center", "row": 2, "features": ["lie-flat", "direct_aisle_access"]}},
        {"identifier": "2F", "status": "available", "metadata": {"type": "center", "row": 2, "features": ["lie-flat", "direct_aisle_access"]}},
        {"identifier": "2K", "status": "available", "metadata": {"type": "window", "row": 2, "features": ["lie-flat", "direct_aisle_access"]}},
        {"identifier": "3A", "status": "available", "metadata": {"type": "window", "row": 3, "features": ["lie-flat", "direct_aisle_access"]}},
        {"identifier": "3K", "status": "available", "metadata": {"type": "window", "row": 3, "features": ["lie-flat", "direct_aisle_access"]}}
      ]
    },
    {
      "category_name": "Business Class",
      "seats": [
        {"identifier": "10A", "status": "available", "metadata": {"type": "window", "row": 10}},
        {"identifier": "10D", "status": "available", "metadata": {"type": "center", "row": 10}},
        {"identifier": "10G", "status": "available", "metadata": {"type": "center", "row": 10}},
        {"identifier": "10K", "status": "available", "metadata": {"type": "window", "row": 10}},
        {"identifier": "11A", "status": "available", "metadata": {"type": "window", "row": 11}},
        {"identifier": "11D", "status": "available", "metadata": {"type": "center", "row": 11}},
        {"identifier": "11G", "status": "available", "metadata": {"type": "center", "row": 11}},
        {"identifier": "11K", "status": "available", "metadata": {"type": "window", "row": 11}},
        {"identifier": "12A", "status": "available", "metadata": {"type": "window", "row": 12}},
        {"identifier": "12D", "status": "available", "metadata": {"type": "center", "row": 12}},
        {"identifier": "12G", "status": "available", "metadata": {"type": "center", "row": 12}},
        {"identifier": "12K", "status": "available", "metadata": {"type": "window", "row": 12}},
        {"identifier": "13A", "status": "available", "metadata": {"type": "window", "row": 13}},
        {"identifier": "13D", "status": "available", "metadata": {"type": "center", "row": 13}},
        {"identifier": "13G", "status": "available", "metadata": {"type": "center", "row": 13}},
        {"identifier": "13K", "status": "available", "metadata": {"type": "window", "row": 13}},
        {"identifier": "14A", "status": "available", "metadata": {"type": "window", "row": 14}},
        {"identifier": "14D", "status": "available", "metadata": {"type": "center", "row": 14}},
        {"identifier": "14G", "status": "available", "metadata": {"type": "center", "row": 14}},
        {"identifier": "14K", "status": "available", "metadata": {"type": "window", "row": 14}},
        {"identifier": "15A", "status": "available", "metadata": {"type": "window", "row": 15}},
        {"identifier": "15D", "status": "available", "metadata": {"type": "center", "row": 15}},
        {"identifier": "15G", "status": "available", "metadata": {"type": "center", "row": 15}},
        {"identifier": "15K", "status": "available", "metadata": {"type": "window", "row": 15}},
        {"identifier": "16A", "status": "available", "metadata": {"type": "window", "row": 16}},
        {"identifier": "16D", "status": "available", "metadata": {"type": "center", "row": 16}},
        {"identifier": "16G", "status": "available", "metadata": {"type": "center", "row": 16}},
        {"identifier": "16K", "status": "available", "metadata": {"type": "window", "row": 16}},
        {"identifier": "17A", "status": "available", "metadata": {"type": "window", "row": 17}},
        {"identifier": "17D", "status": "available", "metadata": {"type": "center", "row": 17}},
        {"identifier": "17G", "status": "available", "metadata": {"type": "center", "row": 17}},
        {"identifier": "17K", "status": "available", "metadata": {"type": "window", "row": 17}},
        {"identifier": "18A", "status": "available", "metadata": {"type": "window", "row": 18}},
        {"identifier": "18D", "status": "available", "metadata": {"type": "center", "row": 18}},
        {"identifier": "18G", "status": "available", "metadata": {"type": "center", "row": 18}},
        {"identifier": "18K", "status": "available", "metadata": {"type": "window", "row": 18}}
      ]
    },
    {
      "category_name": "Premium Economy",
      "seats": [
        {"identifier": "20A", "status": "available", "metadata": {"type": "window", "row": 20}},
        {"identifier": "20B", "status": "available", "metadata": {"type": "middle", "row": 20}},
        {"identifier": "20D", "status": "available", "metadata": {"type": "aisle", "row": 20}},
        {"identifier": "20E", "status": "available", "metadata": {"type": "center", "row": 20}},
        {"identifier": "20G", "status": "available", "metadata": {"type": "aisle", "row": 20}},
        {"identifier": "20H", "status": "available", "metadata": {"type": "middle", "row": 20}},
        {"identifier": "20K", "status": "available", "metadata": {"type": "window", "row": 20}},
        {"identifier": "21A", "status": "available", "metadata": {"type": "window", "row": 21}},
        {"identifier": "21B", "status": "available", "metadata": {"type": "middle", "row": 21}},
        {"identifier": "21D", "status": "available", "metadata": {"type": "aisle", "row": 21}},
        {"identifier": "21E", "status": "available", "metadata": {"type": "center", "row": 21}},
        {"identifier": "21G", "status": "available", "metadata": {"type": "aisle", "row": 21}},
        {"identifier": "21H", "status": "available", "metadata": {"type": "middle", "row": 21}},
        {"identifier": "21K", "status": "available", "metadata": {"type": "window", "row": 21}},
        {"identifier": "22A", "status": "available", "metadata": {"type": "window", "row": 22}},
        {"identifier": "22B", "status": "available", "metadata": {"type": "middle", "row": 22}},
        {"identifier": "22D", "status": "available", "metadata": {"type": "aisle", "row": 22}},
        {"identifier": "22E", "status": "available", "metadata": {"type": "center", "row": 22}},
        {"identifier": "22G", "status": "available", "metadata": {"type": "aisle", "row": 22}},
        {"identifier": "22H", "status": "available", "metadata": {"type": "middle", "row": 22}},
        {"identifier": "22K", "status": "available", "metadata": {"type": "window", "row": 22}}
      ]
    },
    {
      "category_name": "Economy Class",
      "seats": [
        {"identifier": "30A", "status": "available", "metadata": {"type": "window", "row": 30, "features": ["bulkhead", "extra_legroom"]}},
        {"identifier": "30B", "status": "available", "metadata": {"type": "middle", "row": 30, "features": ["bulkhead", "extra_legroom"]}},
        {"identifier": "30C", "status": "available", "metadata": {"type": "aisle", "row": 30, "features": ["bulkhead", "extra_legroom"]}},
        {"identifier": "30D", "status": "available", "metadata": {"type": "aisle", "row": 30, "features": ["bulkhead", "extra_legroom"]}},
        {"identifier": "30E", "status": "available", "metadata": {"type": "middle", "row": 30, "features": ["bulkhead", "extra_legroom"]}},
        {"identifier": "30F", "status": "available", "metadata": {"type": "middle", "row": 30, "features": ["bulkhead", "extra_legroom"]}},
        {"identifier": "30G", "status": "available", "metadata": {"type": "aisle", "row": 30, "features": ["bulkhead", "extra_legroom"]}},
        {"identifier": "30H", "status": "available", "metadata": {"type": "middle", "row": 30, "features": ["bulkhead", "extra_legroom"]}},
        {"identifier": "30K", "status": "available", "metadata": {"type": "window", "row": 30, "features": ["bulkhead", "extra_legroom"]}},
        {"identifier": "31A", "status": "available", "metadata": {"type": "window", "row": 31}},
        {"identifier": "31B", "status": "available", "metadata": {"type": "middle", "row": 31}},
        {"identifier": "31C", "status": "available", "metadata": {"type": "aisle", "row": 31}},
        {"identifier": "31D", "status": "available", "metadata": {"type": "aisle", "row": 31}},
        {"identifier": "31E", "status": "available", "metadata": {"type": "middle", "row": 31}},
        {"identifier": "31F", "status": "available", "metadata": {"type": "middle", "row": 31}},
        {"identifier": "31G", "status": "available", "metadata": {"type": "aisle", "row": 31}},
        {"identifier": "31H", "status": "available", "metadata": {"type": "middle", "row": 31}},
        {"identifier": "31K", "status": "available", "metadata": {"type": "window", "row": 31}},
        {"identifier": "32A", "status": "unavailable", "metadata": {"type": "window", "row": 32, "reason": "maintenance", "issue": "seat_mechanism", "until": "2025-12-15"}},
        {"identifier": "32B", "status": "available", "metadata": {"type": "middle", "row": 32}},
        {"identifier": "32C", "status": "available", "metadata": {"type": "aisle", "row": 32}}
      ]
    }
  ]
}';

    -- Call the procedure
    DBMS_OUTPUT.PUT_LINE('Calling AddCompleteAssetFromJSON...');
    DBMS_OUTPUT.PUT_LINE('');
    
    ResourceManagement.AddCompleteAssetFromJSON(
        p_json_data => v_json_data,
        p_new_asset_id => v_new_asset_id
    );
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('✓ SUCCESS: Asset created with ID: ' || v_new_asset_id);
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('');
    
    -- Query the results
    DBMS_OUTPUT.PUT_LINE('Asset Details:');
    FOR rec IN (SELECT * FROM ResourceAsset WHERE id = v_new_asset_id) LOOP
        DBMS_OUTPUT.PUT_LINE('  Name: ' || rec.name);
        DBMS_OUTPUT.PUT_LINE('  Description: ' || rec.description);
        DBMS_OUTPUT.PUT_LINE('  Status: ' || rec.status);
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Capacities:');
    FOR rec IN (
        SELECT rc.name, ac.quantity 
        FROM AssetCapacity ac
        JOIN ResourceCategory rc ON ac.category_id = rc.id
        WHERE ac.asset_id = v_new_asset_id
        ORDER BY ac.quantity DESC
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  ' || rec.name || ': ' || rec.quantity || ' seats');
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Instance Summary:');
    FOR rec IN (
        SELECT rc.name, COUNT(*) as seat_count,
               SUM(CASE WHEN ri.status = 'available' THEN 1 ELSE 0 END) as available,
               SUM(CASE WHEN ri.status = 'unavailable' THEN 1 ELSE 0 END) as unavailable
        FROM ResourceInstance ri
        JOIN ResourceCategory rc ON ri.category_id = rc.id
        WHERE ri.asset_id = v_new_asset_id
        GROUP BY rc.name
        ORDER BY seat_count DESC
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  ' || rec.name || ': ' || rec.seat_count || ' total (' || 
                            rec.available || ' available, ' || rec.unavailable || ' unavailable)');
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Check DebugLog for detailed operation logs.');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('===============================================');
        DBMS_OUTPUT.PUT_LINE('✗ ERROR: ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('===============================================');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Check DebugLog for error details.');
        RAISE;
END;
/

-- View recent debug logs
SELECT message, log_timestamp 
FROM (
    SELECT message, log_timestamp 
    FROM DebugLog 
    ORDER BY log_timestamp DESC
) 
WHERE ROWNUM <= 20;

