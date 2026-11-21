-- Planet Ops Phase 3: the database's estimate arithmetic (private.estimate_totals, through
-- save_estimate_version) against fixed, fictional cases whose expected figures were worked out apart
-- from the app (Python Decimal, half up). The same cases run through packages/core's calculateEstimate
-- in apps/web/test/estimatingCases.test.ts, which also checks that the cases below are exactly
-- supabase/tests/estimating_cases.json. Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_ec;
create function tpo_ec.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;

insert into auth.users (id, email, raw_user_meta_data) values ('e2800000-0000-0000-0000-000000000001', 'owner@planet-ec.test', '{"full_name": "Test Owner"}');
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', 'e2800000-0000-0000-0000-000000000001', 'role', 'authenticated')::text, true);
select public.create_company('TEST Planet Demolition EC', 'general') as co \gset
commit;

-- cases:begin
create table tpo_ec.cases as select $cases$[
 {
  "name": "markup 25% on the subtotal",
  "pricing": {
   "method": "markup",
   "pct": "0.25",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "crew",
    "section": "labor",
    "name": "Crew",
    "unit": "hour",
    "count": 1,
    "hours": 10,
    "days": 1,
    "unit_cost": "50",
    "risk_pct": "0",
    "customer_item": "Demolition"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 600.0,
   "risk": 0.0,
   "subtotal": 600.0,
   "markup": 150.0,
   "price_before_owner_pay": 750.0,
   "owner_pay": 0.0,
   "selling_price": 750.0,
   "line_prices": [
    625.0,
    125.0
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "target margin 25% (the same lines): the fee is 25% of the price",
  "pricing": {
   "method": "margin",
   "pct": "0.25",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "crew",
    "section": "labor",
    "name": "Crew",
    "unit": "hour",
    "count": 1,
    "hours": 10,
    "days": 1,
    "unit_cost": "50",
    "risk_pct": "0",
    "customer_item": "Demolition"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 600.0,
   "risk": 0.0,
   "subtotal": 600.0,
   "markup": 200.0,
   "price_before_owner_pay": 800.0,
   "owner_pay": 0.0,
   "selling_price": 800.0,
   "line_prices": [
    666.67,
    133.33
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "owner pay 10% of the price before it",
  "pricing": {
   "method": "markup",
   "pct": "0.25",
   "owner_pay": "percent_of_price",
   "owner_pct": "0.10"
  },
  "lines": [
   {
    "key": "crew",
    "section": "labor",
    "name": "Crew",
    "unit": "hour",
    "count": 1,
    "hours": 10,
    "days": 1,
    "unit_cost": "50",
    "risk_pct": "0",
    "customer_item": "Demolition"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 600.0,
   "risk": 0.0,
   "subtotal": 600.0,
   "markup": 150.0,
   "price_before_owner_pay": 750.0,
   "owner_pay": 75.0,
   "selling_price": 825.0,
   "line_prices": [
    687.5,
    137.5
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "owner pay on at 0% (allowed)",
  "pricing": {
   "method": "markup",
   "pct": "0.25",
   "owner_pay": "percent_of_price",
   "owner_pct": "0"
  },
  "lines": [
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 100.0,
   "risk": 0.0,
   "subtotal": 100.0,
   "markup": 25.0,
   "price_before_owner_pay": 125.0,
   "owner_pay": 0.0,
   "selling_price": 125.0,
   "line_prices": [
    125.0
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "burden 20% on labor whose rate excludes it, not on a fully loaded rate, not on equipment",
  "pricing": {
   "method": "markup",
   "pct": "0",
   "owner_pay": "none",
   "burden_pct": "0.20"
  },
  "lines": [
   {
    "key": "reg",
    "section": "labor",
    "name": "Regular crew",
    "unit": "hour",
    "count": 2,
    "hours": 8,
    "days": 1,
    "unit_cost": "25",
    "risk_pct": "0",
    "includes_burden": false,
    "customer_item": "Demolition"
   },
   {
    "key": "ot",
    "section": "labor",
    "name": "Overtime crew (OT hourly rate)",
    "unit": "hour",
    "count": 2,
    "hours": 2,
    "days": 1,
    "unit_cost": "37.50",
    "risk_pct": "0",
    "includes_burden": false,
    "customer_item": "Demolition"
   },
   {
    "key": "loaded",
    "section": "labor",
    "name": "Operator (rate includes burden)",
    "unit": "hour",
    "count": 1,
    "hours": 8,
    "days": 1,
    "unit_cost": "45",
    "risk_pct": "0",
    "includes_burden": true,
    "customer_item": "Demolition"
   },
   {
    "key": "skid",
    "section": "equipment",
    "name": "Skid steer",
    "unit": "day",
    "count": 1,
    "days": 1,
    "unit_cost": "300",
    "risk_pct": "0",
    "customer_item": "Equipment"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "0",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 1320.0,
   "risk": 0.0,
   "subtotal": 1320.0,
   "markup": 0.0,
   "price_before_owner_pay": 1320.0,
   "owner_pay": 0.0,
   "selling_price": 1320.0,
   "line_prices": [
    480.0,
    180.0,
    360.0,
    300.0,
    0.0
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "equipment with fuel included plus a fuel line for it: warned, still complete",
  "pricing": {
   "method": "markup",
   "pct": "0.10",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "ex",
    "section": "equipment",
    "name": "Excavator (rate includes fuel)",
    "unit": "day",
    "count": 1,
    "days": 2,
    "unit_cost": "650",
    "risk_pct": "0",
    "includes_fuel": true,
    "customer_item": "Equipment"
   },
   {
    "key": "exfuel",
    "section": "equipment",
    "name": "Excavator fuel",
    "unit": "gallon",
    "count": 40,
    "unit_cost": "5.25",
    "risk_pct": "0",
    "fuel_for": "ex",
    "customer_item": "Equipment"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "50",
    "risk_pct": "0",
    "customer_item": "Equipment"
   }
  ],
  "expect": {
   "base": 1560.0,
   "risk": 0.0,
   "subtotal": 1560.0,
   "markup": 156.0,
   "price_before_owner_pay": 1716.0,
   "owner_pay": 0.0,
   "selling_price": 1716.0,
   "line_prices": [
    1430.0,
    231.0,
    55.0
   ],
   "status": "ok",
   "warnings": [
    "Fuel"
   ]
  }
 },
 {
  "name": "equipment without fuel and its own fuel line in gallons; truck fuel in gallons",
  "pricing": {
   "method": "markup",
   "pct": "0.10",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "ex",
    "section": "equipment",
    "name": "Excavator (dry rate)",
    "unit": "day",
    "count": 1,
    "days": 2,
    "unit_cost": "600",
    "risk_pct": "0",
    "includes_fuel": false,
    "customer_item": "Equipment"
   },
   {
    "key": "exfuel",
    "section": "equipment",
    "name": "Excavator fuel",
    "unit": "gallon",
    "count": 40,
    "unit_cost": "5.25",
    "risk_pct": "0",
    "fuel_for": "ex",
    "customer_item": "Equipment"
   },
   {
    "key": "truck",
    "section": "travel",
    "name": "Truck fuel",
    "unit": "gallon",
    "count": 12.5,
    "unit_cost": "4.899",
    "risk_pct": "0",
    "customer_item": "Mobilization"
   },
   {
    "key": "miles",
    "section": "travel",
    "name": "Mileage (round trip)",
    "unit": "mile",
    "count": 84,
    "unit_cost": "0.70",
    "risk_pct": "0",
    "customer_item": "Mobilization"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "50",
    "risk_pct": "0",
    "customer_item": "Equipment"
   }
  ],
  "expect": {
   "base": 1580.04,
   "risk": 0.0,
   "subtotal": 1580.04,
   "markup": 158.0,
   "price_before_owner_pay": 1738.04,
   "owner_pay": 0.0,
   "selling_price": 1738.04,
   "line_prices": [
    1320.0,
    231.0,
    67.36,
    64.68,
    55.0
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "disposal priced by what's billed (tons); loose CY, container CY and loads kept apart and not priced",
  "pricing": {
   "method": "markup",
   "pct": "0.20",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "debris",
    "section": "disposal",
    "name": "Mixed C&D",
    "unit": "ton",
    "count": 3.4,
    "unit_cost": "85",
    "risk_pct": "0",
    "est_tons": 3.4,
    "est_loose_cy": 12,
    "container_cy": 20,
    "expected_loads": 1,
    "customer_item": "Haul-off and disposal"
   },
   {
    "key": "haul",
    "section": "hauling",
    "name": "Container haul",
    "unit": "haul",
    "count": 1,
    "unit_cost": "275",
    "risk_pct": "0",
    "container_cy": 20,
    "expected_loads": 1,
    "customer_item": "Haul-off and disposal"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "75",
    "risk_pct": "0",
    "customer_item": "Haul-off and disposal"
   }
  ],
  "expect": {
   "base": 639.0,
   "risk": 0.0,
   "subtotal": 639.0,
   "markup": 127.8,
   "price_before_owner_pay": 766.8,
   "owner_pay": 0.0,
   "selling_price": 766.8,
   "line_prices": [
    346.8,
    330.0,
    90.0
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "per-line risk: 10% on one line, 0% on another",
  "pricing": {
   "method": "markup",
   "pct": "0.20",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "slab",
    "section": "subcontractor",
    "name": "Slab saw-cutting (sub quote)",
    "unit": "lump",
    "count": 1,
    "unit_cost": "1200",
    "risk_pct": "0.10",
    "customer_item": "Demolition"
   },
   {
    "key": "permit",
    "section": "permits",
    "name": "Demolition permit",
    "unit": "each",
    "count": 1,
    "unit_cost": "350",
    "risk_pct": "0",
    "customer_item": "Permits"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "150",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 1700.0,
   "risk": 120.0,
   "subtotal": 1820.0,
   "markup": 364.0,
   "price_before_owner_pay": 2184.0,
   "owner_pay": 0.0,
   "selling_price": 2184.0,
   "line_prices": [
    1584.0,
    420.0,
    180.0
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "a credit on an Other line lowers the base",
  "pricing": {
   "method": "markup",
   "pct": "0.30",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "crew",
    "section": "labor",
    "name": "Crew",
    "unit": "hour",
    "count": 2,
    "hours": 8,
    "days": 1,
    "unit_cost": "30",
    "risk_pct": "0",
    "customer_item": "Demolition"
   },
   {
    "key": "salvage",
    "section": "other",
    "name": "Salvage credit (steel)",
    "unit": "lump",
    "count": 1,
    "unit_cost": "-120",
    "risk_pct": "0",
    "customer_item": "Salvage credit"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 460.0,
   "risk": 0.0,
   "subtotal": 460.0,
   "markup": 138.0,
   "price_before_owner_pay": 598.0,
   "owner_pay": 0.0,
   "selling_price": 598.0,
   "line_prices": [
    624.0,
    -156.0,
    130.0
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "fractional quantities, exact to the cent",
  "pricing": {
   "method": "margin",
   "pct": "0.235",
   "owner_pay": "percent_of_price",
   "owner_pct": "0.0725",
   "burden_pct": "0.1825"
  },
  "lines": [
   {
    "key": "crew",
    "section": "labor",
    "name": "Crew",
    "unit": "hour",
    "count": 2.5,
    "hours": 7.75,
    "days": 1.333,
    "unit_cost": "33.3333",
    "risk_pct": "0.035",
    "customer_item": "Demolition"
   },
   {
    "key": "debris",
    "section": "disposal",
    "name": "Debris",
    "unit": "ton",
    "count": 4.125,
    "unit_cost": "92.40",
    "risk_pct": "0.015",
    "est_tons": 4.125,
    "customer_item": "Haul-off and disposal"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "99.99",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 1499.15,
   "risk": 41.35,
   "subtotal": 1540.5,
   "markup": 473.22,
   "price_before_owner_pay": 2013.72,
   "owner_pay": 145.99,
   "selling_price": 2159.71,
   "line_prices": [
    1477.16,
    542.37,
    140.18
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "rounding boundary: three equal lines, the leftover cent on the first",
  "pricing": {
   "method": "markup",
   "pct": "0.11112",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "a",
    "section": "labor",
    "name": "Crew A",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Part A"
   },
   {
    "key": "b",
    "section": "labor",
    "name": "Crew B",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Part B"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Part C"
   }
  ],
  "expect": {
   "base": 300.0,
   "risk": 0.0,
   "subtotal": 300.0,
   "markup": 33.34,
   "price_before_owner_pay": 333.34,
   "owner_pay": 0.0,
   "selling_price": 333.34,
   "line_prices": [
    111.12,
    111.11,
    111.11
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "half a cent rounds up (not to even)",
  "pricing": {
   "method": "markup",
   "pct": "0",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "permit",
    "section": "permits",
    "name": "Permit fee",
    "unit": "each",
    "count": 1,
    "unit_cost": "10.005",
    "risk_pct": "0",
    "customer_item": "Permits"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "0",
    "risk_pct": "0",
    "customer_item": "Permits"
   }
  ],
  "expect": {
   "base": 10.01,
   "risk": 0.0,
   "subtotal": 10.01,
   "markup": 0.0,
   "price_before_owner_pay": 10.01,
   "owner_pay": 0.0,
   "selling_price": 10.01,
   "line_prices": [
    10.01,
    0.0
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "all zero: nothing to price, nothing on the document",
  "pricing": {
   "method": "margin",
   "pct": "0.30",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 0,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 0.0,
   "risk": 0.0,
   "subtotal": 0.0,
   "markup": 0.0,
   "price_before_owner_pay": 0.0,
   "owner_pay": 0.0,
   "selling_price": 0.0,
   "line_prices": [
    0.0
   ],
   "status": "ok",
   "warnings": []
  }
 },
 {
  "name": "a line with no rate: incomplete (can't be approved or sent on)",
  "pricing": {
   "method": "markup",
   "pct": "0.25",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "crew",
    "section": "labor",
    "name": "Crew",
    "unit": "hour",
    "count": 2,
    "hours": 8,
    "days": 1,
    "unit_cost": null,
    "risk_pct": "0",
    "customer_item": "Demolition"
   },
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 100.0,
   "risk": 0.0,
   "subtotal": 100.0,
   "markup": 25.0,
   "price_before_owner_pay": 125.0,
   "owner_pay": 0.0,
   "selling_price": 125.0,
   "line_prices": [
    0.0,
    125.0
   ],
   "status": "unresolved",
   "warnings": []
  }
 },
 {
  "name": "owner pay on with no percentage: incomplete",
  "pricing": {
   "method": "markup",
   "pct": "0.25",
   "owner_pay": "percent_of_price"
  },
  "lines": [
   {
    "key": "cont",
    "section": "contingency",
    "name": "Contingency",
    "unit": "lump",
    "count": 1,
    "unit_cost": "100",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 100.0,
   "risk": 0.0,
   "subtotal": 100.0,
   "markup": 25.0,
   "price_before_owner_pay": 125.0,
   "owner_pay": 0.0,
   "selling_price": 125.0,
   "line_prices": [
    125.0
   ],
   "status": "unresolved",
   "warnings": []
  }
 },
 {
  "name": "no contingency line: a warning, not a block",
  "pricing": {
   "method": "markup",
   "pct": "0.25",
   "owner_pay": "none"
  },
  "lines": [
   {
    "key": "crew",
    "section": "labor",
    "name": "Crew",
    "unit": "hour",
    "count": 1,
    "hours": 4,
    "days": 1,
    "unit_cost": "40",
    "risk_pct": "0",
    "customer_item": "Demolition"
   }
  ],
  "expect": {
   "base": 160.0,
   "risk": 0.0,
   "subtotal": 160.0,
   "markup": 40.0,
   "price_before_owner_pay": 200.0,
   "owner_pay": 0.0,
   "selling_price": 200.0,
   "line_prices": [
    200.0
   ],
   "status": "ok",
   "warnings": [
    "Contingency"
   ]
  }
 }
]$cases$::jsonb as cases;
-- cases:end

-- Each case saved as the server would (no one signed in: every area), then its stored figures read.
do $$
declare
  k jsonb; e jsonb; v_estimate uuid; v_version uuid; v public.estimate_versions; v_prices numeric[]; v_items numeric; i integer := 0;
  v_company uuid := (select id from public.companies where name = 'TEST Planet Demolition EC');
begin
  for k in select jsonb_array_elements(cases) from tpo_ec.cases loop
    i := i + 1;
    e := k -> 'expect';
    v_estimate := public.create_estimate(v_company, gen_random_uuid(), k ->> 'name');
    select current_version_id into v_version from public.estimates where id = v_estimate;
    perform public.save_estimate_version(v_version, 0, jsonb_build_object(
      'pricing_method', k -> 'pricing' ->> 'method', 'pricing_pct', k -> 'pricing' ->> 'pct', 'owner_pay_method', k -> 'pricing' ->> 'owner_pay',
      'owner_pct', k -> 'pricing' -> 'owner_pct', 'burden_pct', k -> 'pricing' -> 'burden_pct', 'lines', k -> 'lines'));
    select * into v from public.estimate_versions where id = v_version;
    select array_agg(price order by sort) into v_prices from public.estimate_lines where version_id = v_version;
    perform tpo_ec.check(v.base_cost = (e ->> 'base')::numeric and v.risk_reserve = (e ->> 'risk')::numeric and v.subtotal = (e ->> 'subtotal')::numeric
                         and v.markup_amount = (e ->> 'markup')::numeric and v.price_before_owner_pay = (e ->> 'price_before_owner_pay')::numeric
                         and v.owner_pay = (e ->> 'owner_pay')::numeric and v.selling_price = (e ->> 'selling_price')::numeric,
      format('case %s, %s: base %s, risk %s, markup %s, owner pay %s, selling price %s', i, k ->> 'name', v.base_cost, v.risk_reserve, v.markup_amount, v.owner_pay, v.selling_price));
    perform tpo_ec.check(v_prices = (select array_agg(x::numeric order by n) from jsonb_array_elements_text(e -> 'line_prices') with ordinality t(x, n)),
      format('case %s: each line''s share of the price %s', i, v_prices));
    perform tpo_ec.check(v.calc_status = e ->> 'status', format('case %s: %s', i, v.calc_status));
    select coalesce(sum(price), 0) into v_items from private.estimate_customer_items(v_version);
    perform tpo_ec.check(v_items = v.selling_price, format('case %s: the customer items add up to the selling price (%s)', i, v_items));
  end loop;
end $$;

-- Disposal keeps weight, loose volume, container capacity and loads apart, and prices only the count.
select tpo_ec.check((select est_tons = 3.4 and est_loose_cy = 12 and container_cy = 20 and expected_loads = 1 and base = 289 from public.estimate_lines l
                      join public.estimate_versions v on v.id = l.version_id join public.estimates e on e.id = v.estimate_id
                     where e.title like 'disposal priced%' and l.key = 'debris'),
  'a disposal line stores 3.4 tons, 12 loose CY, a 20 CY container and 1 load, and prices 3.4 × $85 only');

-- The estimate's default risk fills a line saved without one (not a line saved with 0%).
do $$
declare v_estimate uuid; v_version uuid; v_company uuid := (select id from public.companies where name = 'TEST Planet Demolition EC');
begin
  v_estimate := public.create_estimate(v_company, gen_random_uuid(), 'Default risk');
  select current_version_id into v_version from public.estimates where id = v_estimate;
  perform public.save_estimate_version(v_version, 0, jsonb_build_object('pricing_method', 'markup', 'pricing_pct', 0, 'owner_pay_method', 'none', 'default_risk_pct', 0.05));
  perform public.save_estimate_version(v_version, 1, jsonb_build_object('lines', jsonb_build_array(
    jsonb_build_object('key', 'a', 'section', 'permits', 'name', 'Permit', 'count', 1, 'unit', 'each', 'unit_cost', 200),
    jsonb_build_object('key', 'b', 'section', 'permits', 'name', 'Test', 'count', 1, 'unit', 'each', 'unit_cost', 200, 'risk_pct', 0),
    jsonb_build_object('key', 'c', 'section', 'contingency', 'name', 'Contingency', 'count', 1, 'unit', 'lump', 'unit_cost', 0))));
  perform tpo_ec.check((select string_agg(key || '=' || risk_pct::float8, ',' order by sort) from public.estimate_lines where version_id = v_version) = 'a=0.05,b=0,c=0.05'
                       and (select risk_reserve = 10 and selling_price = 410 from public.estimate_versions where id = v_version),
    'the default 5% risk fills lines saved without a risk %, not a line saved at 0%: $10 reserve, $410');
end $$;

-- Values the database refuses outright (the screen shows them as problems before saving).
do $$
declare v_estimate uuid; v_version uuid; v_company uuid := (select id from public.companies where name = 'TEST Planet Demolition EC'); v_msg text;
begin
  v_estimate := public.create_estimate(v_company, gen_random_uuid(), 'Refused values');
  select current_version_id into v_version from public.estimates where id = v_estimate;
  foreach v_msg in array array['{"pricing_method": "margin", "pricing_pct": 1}', '{"pricing_pct": -0.1}', '{"owner_pay_method": "percent_of_price", "owner_pct": 1}',
                               '{"lines": [{"section": "labor", "name": "Crew", "unit": "hour", "unit_cost": -25}]}', '{"lines": [{"section": "labor", "name": "Crew", "unit": "hour", "count": "2,5"}]}',
                               '{"lines": [{"section": "labor", "name": "Crew", "unit": "furlong"}]}', '{"lines": [{"section": "labor", "name": "Crew", "unit": "hour", "count": 1e12}]}'] loop
    begin
      perform public.save_estimate_version(v_version, 0, v_msg::jsonb);
      raise exception 'FAIL: % was accepted', v_msg;
    exception when sqlstate '22023' then
      raise notice 'ok - refused % (%)', v_msg, sqlerrm;
    end;
  end loop;
  perform tpo_ec.check((select revision = 0 from public.estimate_versions where id = v_version), 'nothing refused was saved');
end $$;

\o
\echo 'All Planet Ops estimating calculation cases passed.'
