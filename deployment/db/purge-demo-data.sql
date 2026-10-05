-- ---------------------------------------------------------------------------
-- Purge demo clinical data from a pre-populated OpenMRS database.
--
-- SCOPE AND SAFETY
--   This script runs exactly once, against a freshly seeded volume:
--     * in CI, against the upstream pre-populated image before the dump is taken
--       (.github/workflows/build-db-seed.yml)
--     * at runtime, only if OMRS_DB_PURGE_AFTER_SEED=true is set explicitly
--       (deployment/db/seed.sh)
--   It is never executed against a database that already holds production data.
--
--   Requires a user with CREATE ROUTINE and DELETE on the schema. It does not
--   require, and does not modify, any account's credentials.
--
--   Every step below fails loudly: the stored procedure propagates SQL errors,
--   and the script's final statement is a verification SELECT whose output is
--   asserted by CI. A partial purge must never look like success.
--
-- WHAT IS REMOVED
--   Sample patients, persons, names, identifiers, person attributes, encounters,
--   visits, observations, orders, allergies, conditions, referrals, tasks,
--   appointments, program enrolments, stock transactions, visit/encounter
--   attributes, the FHIR and search-index copies derived from them, the demo
--   providers, and the demo application users.
--
-- WHAT IS PRESERVED  (this is the important part)
--   Core *metadata* is never touched, including anything that happened to arrive
--   from the same demo package. In particular this keeps:
--     * concepts, concept names, concept classes, concept sources, concept sets
--     * concept_reference_map and concept_map_type  (the CIEL mappings)
--     * locations, location tags, address hierarchy
--     * visit types, encounter types, encounter roles
--     * drugs, drug ingredients, order types, order frequencies, drug concepts
--     * provider roles, specialities
--     * programs, program workflows, workflow states
--     * forms, form field types
--     * roles, privileges, privileges_*
--     * global_property, global_property_allowlist
--     * module and extension metadata of every kind
--   Removing these would break the hard-coded concept UUIDs that O3, order entry,
--   forms and REST/FHIR depend on. They are excluded by construction: none of
--   them carry a person_id / patient_id / encounter_id / visit_id / obs_id /
--   order_id column, which is exactly how the cursor below selects its tables.
--
--   Three groups of tables are deliberately NOT swept up by that rule:
--     users*  -- identity, not clinical data; handled by the demo-user list
--     person, person_name, person_address, person_attribute
--             -- `person` has a person_id column (its own primary key), so the
--                cursor below would otherwise delete EVERY person, including the
--                ones belonging to the surviving admin user. That orphans the
--                admin account and removes both system providers. Handled
--                explicitly in step 3.
--     provider -- carries a person_id, but holds the system providers order entry
--             depends on. Handled explicitly in step 3.
--
--   DO NOT PURGE THE `daemon` USER
--     The `daemon` account (user_id 2) is OpenMRS's own system user, not demo
--     data. It is the `creator` of effectively all shipped reference metadata:
--     4391 concepts, 58 locations, 323 drugs and every `person` row in the
--     upstream image carry creator = 2. Deleting it orphans those thousands of
--     `creator` / `changed_by` foreign keys, and OpenMRS then fails at runtime
--     with `org.hibernate.FetchNotFoundException: Entity
--     'org.openmrs.User' with identifier value '2' does not exist` on every
--     metadata read -- which is what broke the location, party and location-tree
--     synchronisers, the reporting tasks and the Initializer's CSV loads.
--     It is excluded from the demo-user list below and asserted in step 4.
-- ---------------------------------------------------------------------------

SET SESSION foreign_key_checks = 0;

-- --- 1. Demo application users ------------------------------------------------
-- Only the human-facing demo accounts are removed. `admin` (the superuser) and
-- `daemon` (the system user that owns the metadata audit trail) are preserved,
-- as is the NULL-username superuser row OpenMRS creates during initial setup.
DELETE ur FROM user_role ur
  JOIN users u ON u.user_id = ur.user_id
 WHERE u.username IN ('clerk','technician','nurse','doctor','scheduler',
                       'finance','accountmanagertest',
                       'receptionist','printer','retiredpharmacist');
DELETE up FROM user_property up
  JOIN users u ON u.user_id = up.user_id
 WHERE u.username IN ('clerk','technician','nurse','doctor','scheduler',
                       'finance','accountmanagertest',
                       'receptionist','printer','retiredpharmacist');
DELETE FROM users
 WHERE username IN ('clerk','technician','nurse','doctor','scheduler',
                    'finance','accountmanagertest',
                    'receptionist','printer','retiredpharmacist');

-- --- 2. Clinical data ---------------------------------------------------------
-- Every table carrying a clinical foreign key, discovered from information_schema
-- so this keeps working as the schema evolves: fhir2, stockmgmt, cashier and
-- other modules each add their own tables.
--
-- provider_id is included because several demo tables reference providers without
-- carrying any other clinical key -- patient_appointment_provider,
-- provider_attribute, room_provider_map, fhir_diagnostic_report_performers -- and
-- would otherwise be left orphaned. None of those are metadata: they only exist
-- to attach clinical records to a provider.
--
-- A cursor is used rather than a single PREPARE because PREPARE accepts exactly
-- one statement, and this needs to issue one DELETE per table (42 tables today).
-- Each statement is prepared, executed and deallocated individually, so a failure
-- on any one of them aborts the procedure rather than silently skipping it.
DROP PROCEDURE IF EXISTS purge_clinical_data;
DELIMITER //
CREATE PROCEDURE purge_clinical_data()
BEGIN
    DECLARE finished  INT DEFAULT 0;
    DECLARE tbl       VARCHAR(64);
    DECLARE stmt      TEXT;

    DECLARE cur CURSOR FOR
        SELECT DISTINCT TABLE_NAME
          FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE()
           AND COLUMN_NAME IN ('person_id', 'patient_id', 'encounter_id',
                               'visit_id', 'obs_id', 'order_id', 'provider_id')
           AND TABLE_NAME NOT IN (
                 'users', 'user_role', 'user_property', 'user_change_log',
                 'user_notification', 'user_credential',
                 'user_credential_change_log',
                 'global_property', 'global_property_allowlist',
                 -- handled explicitly in step 3
                 'person', 'person_name', 'person_address', 'person_attribute',
                 'provider'
               );

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET finished = 1;

    OPEN cur;
    purge_loop: LOOP
        FETCH cur INTO tbl;
        IF finished = 1 THEN
            LEAVE purge_loop;
        END IF;

        SET stmt = CONCAT('DELETE FROM `', tbl, '`');
        PREPARE s FROM stmt;
        EXECUTE s;
        DEALLOCATE PREPARE s;
    END LOOP;
    CLOSE cur;
END//
DELIMITER ;

CALL purge_clinical_data();
DROP PROCEDURE purge_clinical_data;

-- --- 3. Providers and persons -------------------------------------------------
-- Done explicitly, and in this order, because `person` must outlive the decision
-- about which providers survive.
--
--   a. Drop the demo providers by identifier, keeping the two system providers
--      (UNKNOWN, admin). Order entry and encounter forms need a provider, and
--      these are the defaults a fresh installation relies on.
--   b. Drop every person that is not reachable from a surviving user or a
--      surviving provider. This is what removes the demo patients, and it keeps
--      the admin user's person -- deleting it would orphan the admin account.
--   c. Drop the name/address/attribute rows of those persons only.
--
-- The two system providers reference person rows through the `daemon` and `admin`
-- users, so (b) keeps those persons even though the demo users were removed in
-- step 1. That is deliberate: a provider row with a dangling person_id would be
-- worse than an apparently extra person.
DELETE FROM provider WHERE identifier NOT IN ('UNKNOWN', 'admin');

DELETE FROM person
 WHERE person_id NOT IN (SELECT person_id FROM users   WHERE person_id IS NOT NULL)
   AND person_id NOT IN (SELECT person_id FROM provider WHERE person_id IS NOT NULL);

DELETE FROM person_name     WHERE person_id NOT IN (SELECT person_id FROM person);
DELETE FROM person_address  WHERE person_id NOT IN (SELECT person_id FROM person);
DELETE FROM person_attribute WHERE person_id NOT IN (SELECT person_id FROM person);

-- --- 3b. Audit-trail guard ----------------------------------------------------
-- A user may only be deleted if nothing that survives still points at it. The
-- demo-user deletes in step 1 are name-based, so a future upstream image that
-- reuses one of those names for a system account -- or a new module that stamps
-- `creator` with a purged user -- would silently orphan the audit trail again,
-- and the symptom only appears at OpenMRS startup, long after this script has
-- exited. Detect it here, where it is still cheap, and fail loudly.
--
-- This is a SIGNAL, not a purge: it runs after the deletes so it inspects the
-- state that is actually about to be shipped.
DROP PROCEDURE IF EXISTS assert_no_dangling_user_refs;
DELIMITER //
CREATE PROCEDURE assert_no_dangling_user_refs()
BEGIN
    DECLARE done     INT DEFAULT 0;
    DECLARE dangling INT DEFAULT 0;
    DECLARE tbl      VARCHAR(64);
    DECLARE col      VARCHAR(64);
    DECLARE stmt     TEXT;

    DECLARE cur CURSOR FOR
        SELECT TABLE_NAME, COLUMN_NAME
          FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE()
           AND COLUMN_NAME IN ('creator', 'changed_by', 'retired_by')
           AND TABLE_NAME <> 'users';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    SET done = 0;
    OPEN cur;
    scan: LOOP
        FETCH cur INTO tbl, col;
        IF done = 1 THEN
            LEAVE scan;
        END IF;

        -- 0 is OpenMRS's "no user" sentinel for these columns and never refers
        -- to a real row in `users`, so it is not a dangling reference.
        SET stmt = CONCAT(
            'SELECT COUNT(*) INTO @dangling FROM `', tbl, '` ',
            'WHERE `', col, '` IS NOT NULL ',
            '  AND `', col, '` <> 0 ',
            '  AND `', col, '` NOT IN (SELECT user_id FROM users)');
        PREPARE s FROM stmt;
        EXECUTE s;
        DEALLOCATE PREPARE s;

        SET dangling = @dangling;
        IF dangling > 0 THEN
            CLOSE cur;
            SELECT CONCAT('assert_no_dangling_user_refs: ', dangling, ' row(s) in `',
                          tbl, '`.`', col, '` reference a user that no longer exists. ',
                          'The metadata audit trail would be orphaned and OpenMRS ',
                          'would fail at startup with FetchNotFoundException.') AS failure;
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'dangling user references after purge';
        END IF;
    END LOOP;
    CLOSE cur;
END//
DELIMITER ;

CALL assert_no_dangling_user_refs();
DROP PROCEDURE assert_no_dangling_user_refs;

-- Re-enable only once every DELETE has run. Doing it earlier fails the person
-- delete, because person_name/person_address/person_attribute are children of
-- person and are cleared after it.
SET SESSION foreign_key_checks = 1;

-- --- 4. Verification -----------------------------------------------------------
-- CI asserts these numbers, so a purge that only partially succeeded is visible
-- rather than reported as done.
--
-- `users` and `daemon_users` are asserted here as well as the metadata counts.
-- They are the two failure modes that produce a database which restores cleanly
-- and still breaks at OpenMRS startup, so they belong next to the counts that
-- describe the same property: the seed is usable, not merely well-formed.
SELECT 'purge.completed' AS marker,
       (SELECT COUNT(*) FROM concept)               AS concepts,
       (SELECT COUNT(*) FROM concept_reference_map) AS concept_reference_map,
       (SELECT COUNT(*) FROM location)              AS locations,
       (SELECT COUNT(*) FROM location_tag)          AS location_tags,
       (SELECT COUNT(*) FROM visit_type)            AS visit_types,
       (SELECT COUNT(*) FROM encounter_type)        AS encounter_types,
       (SELECT COUNT(*) FROM encounter_role)        AS encounter_roles,
       (SELECT COUNT(*) FROM drug)                  AS drugs,
       (SELECT COUNT(*) FROM order_type)            AS order_types,
       (SELECT COUNT(*) FROM form)                  AS forms,
       (SELECT COUNT(*) FROM role)                  AS roles,
       (SELECT COUNT(*) FROM privilege)             AS privileges,
       (SELECT COUNT(*) FROM provider)              AS providers,
       (SELECT COUNT(*) FROM obs)                   AS obs,
       (SELECT COUNT(*) FROM encounter)             AS encounters,
       (SELECT COUNT(*) FROM visit)                 AS visits,
       (SELECT COUNT(*) FROM person)                AS persons,
       (SELECT COUNT(*) FROM patient)               AS patients,
       (SELECT COUNT(*) FROM orders)                AS orders,
       -- The admin superuser and the daemon system user must both survive. The
       -- daemon user owns the metadata audit trail, so losing it breaks startup
       -- even though the counts above all look healthy.
       (SELECT COUNT(*) FROM users WHERE username = 'admin')  AS admin_users,
       (SELECT COUNT(*) FROM users WHERE username = 'daemon') AS daemon_users;
