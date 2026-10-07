-- ---------------------------------------------------------------------------
-- Concept reference mapping repair.
--
-- Why this exists
--   The pre-populated seed ships ~19,000 rows in `concept_reference_map`: the
--   links between a concept and its external codes (CIEL, LOINC, RxNorm, ...).
--   Modules resolve concepts by those codes -- order entry validation, the
--   medication and lab order workflows, the FHIR concept translation and the
--   concept search in the order forms all read them. An install that has lost
--   them is not obviously broken, it is quietly degraded, which is far worse.
--
--   Those rows are destroyed on the first boot after seeding. Not by the purge,
--   and not by Liquibase: by `openmrs-module-initializer`. For every concept it
--   loads from a content package's `concepts.csv`,
--   `org.openmrs.module.initializer.api.c.MappingsConceptLineProcessor.fill()`
--   does this:
--
--       if (!CollectionUtils.isEmpty(concept.getConceptMappings())) {
--           concept.getConceptMappings().clear();
--       }
--
--   Clearing a Hibernate collection of ConceptMap makes every row disappear on
--   flush. The processor then re-adds only the mappings named in the CSV's
--   `Same as mappings` column. The Intuvance content package declares that
--   column but populates it for no concept, so the net effect of the first boot
--   is to delete all 18,882 mappings and create none. Measured: 13,549 individual
--   `delete from concept_reference_map where concept_map_id = N` statements
--   during a single content package load.
--
--   The clear() is unconditional, and the CSV grammar allows only one mapping
--   per column, so the mappings cannot simply be restated in the content
--   package: 18,882 of them would need 18,882 columns. Repairing the damage is
--   therefore the only available fix, and this file is it.
--
-- How the repair knows what to restore
--   `openmrs_concept_map_archive` is a durable copy of the seed's mappings. It is
--   populated once, while the rows still exist -- by seed.sh immediately after
--   the dump is restored, before the backend can ever boot. Every repair is then
--   a faithful replay of the seed rather than a guess, so it is correct for new
--   deployments and for deployments that were already damaged.
--
-- Deliberate deletion
--   `INSERT IGNORE` keyed on uuid means a mapping an administrator removes is
--   restored. That is intentional: this table is terminology integrity, not
--   configuration, and a mapping silently vanishing is the failure this exists to
--   prevent. To retire a mapping for good, delete it from the archive as well.
--
-- Idempotency
--   Every statement is INSERT IGNORE against a uuid primary key. Running this
--   file any number of times, in any state, converges on the seed's mappings and
--   changes nothing else.
-- ---------------------------------------------------------------------------

-- The archive. No foreign keys on purpose: it must survive the concepts, terms
-- and map types being rebuilt underneath it, and it is never read through the
-- OpenMRS API.
CREATE TABLE IF NOT EXISTS openmrs_concept_map_archive (
    uuid                      CHAR(38)  NOT NULL,
    concept_id                INT(11)   NOT NULL,
    concept_reference_term_id INT(11)   NOT NULL,
    concept_map_type_id       INT(11)   NOT NULL,
    date_created              DATETIME  NOT NULL,
    PRIMARY KEY (uuid),
    KEY archive_for_concept (concept_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Populate from the live table. `INSERT IGNORE` rather than a guarded insert:
-- re-archiving is cheap, and it means a mapping created after seeding (a new
-- concept, a corrected CIEL link) is protected too. It cannot resurrect
-- anything, because a row already in the archive is skipped.
INSERT IGNORE INTO openmrs_concept_map_archive
    (uuid, concept_id, concept_reference_term_id, concept_map_type_id, date_created)
SELECT m.uuid, m.concept_id, m.concept_reference_term_id, m.concept_map_type_id,
       m.date_created
  FROM concept_reference_map m;

-- Restore. The LEFT JOIN keeps the statement to one pass and makes the intent
-- explicit: a mapping is absent, not merely different. Restoring by uuid rather
-- than by (concept, term, map type) means a mapping that still exists but was
-- re-pointed by the loader is left alone.
--
-- Foreign keys are disabled because the archive can outlive the terms it points
-- at, and a stale archive row must not abort the repair of the good ones.
SET FOREIGN_KEY_CHECKS = 0;

INSERT IGNORE INTO concept_reference_map
    (uuid, concept_id, concept_reference_term_id, concept_map_type_id,
     creator, date_created)
SELECT a.uuid, a.concept_id, a.concept_reference_term_id, a.concept_map_type_id,
       COALESCE((SELECT u.user_id FROM users u WHERE u.username = 'daemon'), 1),
       a.date_created
  FROM openmrs_concept_map_archive a
  LEFT JOIN concept_reference_map m ON m.uuid = a.uuid
 WHERE m.uuid IS NULL;

SET FOREIGN_KEY_CHECKS = 1;
