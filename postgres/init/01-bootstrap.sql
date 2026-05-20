-- Bootstrap script — runs once on first container initialization.
--
-- Hardens the default database created by POSTGRES_DB.  The create-database.sh
-- script applies the same treatment to every subsequent database.

-- Remove the ability for any user to create objects in the public schema by default.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
