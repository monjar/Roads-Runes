-- Runs once when the PostGIS container initialises its data directory.
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
-- h3 / h3_postgis are optional: PostGIS images do not ship them. The app
-- computes H3 in Python; these only speed up analytical queries.
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS h3;
    CREATE EXTENSION IF NOT EXISTS h3_postgis;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'h3 extensions not available; skipping';
  END;
END $$;
