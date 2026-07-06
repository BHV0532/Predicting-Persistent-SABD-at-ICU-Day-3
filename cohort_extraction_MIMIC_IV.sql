/*
================================================================================
MIMIC-IV Cohort Extraction for Persistent Sepsis-Associated Brain Dysfunction
Prediction Model

Database: MIMIC-IV v2.2
Environment: PostgreSQL
Final output table: sabd_persistent_cohort

Cohort definition:
  - Adult patients (age >= 18)
  - First ICU stay
  - Sepsis-3 (suspected infection + SOFA >= 2)
  - SABD within first 24 hours (GCS < 15)

Outcome:
  - Persistent SABD at ICU day 3: peak GCS < 15 during 48-72 hours

Predictors extracted (all within first 24 hours of ICU admission):
  - Neurological: peak GCS (0-24h)
  - Severity scores: OASIS, SOFA
  - Demographics: age
  - Vital signs: heart rate, mean arterial pressure
  - Laboratory: blood lactate, serum creatinine, serum sodium, serum glucose
  - Treatments: invasive mechanical ventilation, dexmedetomidine, opioid use
  - Comorbidities: chronic kidney disease, respiratory failure
  - Pre-ICU statin use

Note: This script extracts only the core variables used in the final prediction
model. Additional variables from the full extraction pipeline are omitted.
================================================================================
*/

SET search_path TO mimiciv_derived, mimiciv_icu, mimiciv_hosp, public;

/* Helper function for safe numeric conversion */
CREATE OR REPLACE FUNCTION public.safe_to_numeric(txt TEXT)
RETURNS NUMERIC AS $$
BEGIN
    IF txt IS NULL THEN
        RETURN NULL;
    ELSIF txt ~ '^[-]?[0-9]+([.][0-9]+)?$' THEN
        RETURN txt::NUMERIC;
    ELSE
        RETURN NULL;
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

/* =============================================================================
   01. Base cohort: adult, first ICU stay, Sepsis-3
   ============================================================================= */
DROP TABLE IF EXISTS sabd_base_cohort CASCADE;
CREATE TABLE sabd_base_cohort AS
WITH first_icu AS (
    SELECT
        icu.subject_id,
        icu.hadm_id,
        icu.stay_id,
        icu.intime AS icu_intime,
        icu.outtime AS icu_outtime,
        icu.los AS icu_los_days,
        ROW_NUMBER() OVER (PARTITION BY icu.subject_id ORDER BY icu.intime, icu.stay_id) AS icu_order
    FROM mimiciv_icu.icustays icu
), sepsis AS (
    SELECT
        s3.stay_id,
        MIN(s3.suspected_infection_time) AS suspected_infection_time,
        MIN(s3.sofa_time) AS sepsis_time,
        MAX(s3.sofa_score) AS sofa_sepsis3
    FROM sepsis3 s3
    GROUP BY s3.stay_id
)
SELECT
    'MIMIC-IV'::TEXT AS database_source,
    fi.subject_id,
    fi.hadm_id,
    fi.stay_id,
    fi.icu_intime,
    fi.icu_outtime,
    fi.icu_los_days,
    CASE WHEN fi.icu_los_days >= 1 THEN 1 ELSE 0 END::SMALLINT AS icu_los_ge_24h,
    (pat.anchor_age + EXTRACT(YEAR FROM adm.admittime)::INT - pat.anchor_year)::INT AS age,
    pat.gender,
    CASE WHEN pat.gender = 'M' THEN 1 WHEN pat.gender = 'F' THEN 0 ELSE NULL END::SMALLINT AS sex_male,
    adm.race,
    adm.hospital_expire_flag AS hosp_mort,
    sepsis.suspected_infection_time,
    sepsis.sepsis_time,
    sepsis.sofa_sepsis3,
    fi.icu_order
FROM first_icu fi
INNER JOIN mimiciv_hosp.patients pat
    ON fi.subject_id = pat.subject_id
INNER JOIN mimiciv_hosp.admissions adm
    ON fi.hadm_id = adm.hadm_id
INNER JOIN sepsis
    ON fi.stay_id = sepsis.stay_id
WHERE fi.icu_order = 1
  AND (pat.anchor_age + EXTRACT(YEAR FROM adm.admittime)::INT - pat.anchor_year) >= 18;

CREATE INDEX IF NOT EXISTS idx_sabd_base_stay ON sabd_base_cohort(stay_id);
CREATE INDEX IF NOT EXISTS idx_sabd_base_hadm ON sabd_base_cohort(hadm_id);
CREATE INDEX IF NOT EXISTS idx_sabd_base_subject ON sabd_base_cohort(subject_id);

/* =============================================================================
   02. Exclusion flags: acute brain injury and alcohol abuse
   ============================================================================= */
DROP TABLE IF EXISTS sabd_exclusion_flags CASCADE;
CREATE TABLE sabd_exclusion_flags AS
WITH dx AS (
    SELECT
        d.hadm_id,
        d.icd_version,
        REPLACE(UPPER(d.icd_code), '.', '') AS icd_code_clean,
        LOWER(COALESCE(dic.long_title, '')) AS long_title
    FROM mimiciv_hosp.diagnoses_icd d
    LEFT JOIN mimiciv_hosp.d_icd_diagnoses dic
        ON d.icd_code = dic.icd_code
       AND d.icd_version = dic.icd_version
), flags AS (
    SELECT
        b.hadm_id,
        MAX(CASE WHEN
            (dx.icd_version = 10 AND (
                SUBSTR(dx.icd_code_clean, 1, 3) IN ('G00','G01','G02','G03','G04','G41','S06','I60','I61','I62','I63','I64')
                OR SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN 'I65' AND 'I69'
            ))
            OR
            (dx.icd_version = 9 AND (
                SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN '320' AND '323'
                OR SUBSTR(dx.icd_code_clean, 1, 4) = '3453'
                OR SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN '430' AND '438'
                OR SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN '800' AND '804'
                OR SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN '850' AND '854'
            ))
            OR dx.long_title ~ '(meningitis|encephalitis|status epilepticus|traumatic brain injury|intracranial hemorrhage|subarachnoid hemorrhage|subdural|epidural|cerebral infarction|ischemic stroke|haemorrhagic stroke|hemorrhagic stroke|cerebrovascular accident)'
        THEN 1 ELSE 0 END) AS acute_brain_injury,
        MAX(CASE WHEN
            (dx.icd_version = 10 AND SUBSTR(dx.icd_code_clean, 1, 3) = 'F10')
            OR (dx.icd_version = 9 AND (
                SUBSTR(dx.icd_code_clean, 1, 3) IN ('291','303')
                OR SUBSTR(dx.icd_code_clean, 1, 4) = '3050'
            ))
            OR dx.long_title ~ '(alcohol abuse|alcohol dependence|alcohol withdrawal|alcohol intoxication|alcoholism|alcohol-related)'
        THEN 1 ELSE 0 END) AS alcohol_abuse
    FROM sabd_base_cohort b
    LEFT JOIN dx
        ON b.hadm_id = dx.hadm_id
    GROUP BY b.hadm_id
)
SELECT
    b.stay_id,
    b.hadm_id,
    COALESCE(f.acute_brain_injury, 0)::SMALLINT AS acute_brain_injury,
    COALESCE(f.alcohol_abuse, 0)::SMALLINT AS alcohol_abuse
FROM sabd_base_cohort b
LEFT JOIN flags f
    ON b.hadm_id = f.hadm_id;

CREATE INDEX IF NOT EXISTS idx_sabd_excl_stay ON sabd_exclusion_flags(stay_id);

/* =============================================================================
   03. GCS reconstruction: first 24 hours and 48-72 hours
   ============================================================================= */
DROP TABLE IF EXISTS sabd_gcs_long CASCADE;
CREATE TABLE sabd_gcs_long AS
WITH gcs_raw AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        MAX(CASE WHEN ce.itemid = 220739 AND ce.valuenum BETWEEN 1 AND 4 THEN ce.valuenum ELSE NULL END)::NUMERIC AS gcs_eyes,
        MAX(CASE
                WHEN ce.itemid = 223900
                 AND (
                     LOWER(COALESCE(ce.value, '')) LIKE '%ett%'
                     OR LOWER(COALESCE(ce.value, '')) LIKE '%tube%'
                     OR LOWER(COALESCE(ce.value, '')) LIKE '%intub%'
                 ) THEN 1
                WHEN ce.itemid = 223900 AND ce.valuenum BETWEEN 1 AND 5 THEN ce.valuenum
                ELSE NULL
            END)::NUMERIC AS gcs_verbal,
        MAX(CASE WHEN ce.itemid = 223901 AND ce.valuenum BETWEEN 1 AND 6 THEN ce.valuenum ELSE NULL END)::NUMERIC AS gcs_motor
    FROM sabd_base_cohort b
    JOIN mimiciv_icu.chartevents ce
        ON b.stay_id = ce.stay_id
       AND ce.charttime >= b.icu_intime
       AND ce.charttime < b.icu_outtime
    WHERE ce.itemid IN (220739, 223900, 223901)
      AND ce.charttime IS NOT NULL
    GROUP BY ce.stay_id, ce.charttime
)
SELECT
    b.stay_id,
    g.charttime,
    ROUND((EXTRACT(EPOCH FROM (g.charttime - b.icu_intime)) / 3600.0)::NUMERIC, 4) AS hours_from_icu,
    FLOOR(EXTRACT(EPOCH FROM (g.charttime - b.icu_intime)) / 86400.0)::INT AS icu_day,
    (g.gcs_eyes + g.gcs_verbal + g.gcs_motor)::NUMERIC AS gcs_total
FROM sabd_base_cohort b
JOIN gcs_raw g
    ON b.stay_id = g.stay_id
WHERE g.gcs_eyes IS NOT NULL
  AND g.gcs_verbal IS NOT NULL
  AND g.gcs_motor IS NOT NULL
  AND (g.gcs_eyes + g.gcs_verbal + g.gcs_motor) BETWEEN 3 AND 15;

CREATE INDEX IF NOT EXISTS idx_sabd_gcs_long_stay_time ON sabd_gcs_long(stay_id, charttime);

/* GCS summary: 0-24h */
DROP TABLE IF EXISTS sabd_gcs_0_24h CASCADE;
CREATE TABLE sabd_gcs_0_24h AS
SELECT
    b.stay_id,
    MIN(g.gcs_total) AS gcs_min_0_24h,
    MAX(g.gcs_total) AS gcs_max_0_24h,
    COUNT(g.gcs_total) AS n_gcs_0_24h
FROM sabd_base_cohort b
LEFT JOIN sabd_gcs_long g
    ON b.stay_id = g.stay_id
   AND g.hours_from_icu >= 0
   AND g.hours_from_icu < 24
GROUP BY b.stay_id;

CREATE INDEX IF NOT EXISTS idx_sabd_gcs_0_24h_stay ON sabd_gcs_0_24h(stay_id);

/* GCS summary: 48-72h (for outcome) */
DROP TABLE IF EXISTS sabd_gcs_48_72h CASCADE;
CREATE TABLE sabd_gcs_48_72h AS
SELECT
    b.stay_id,
    MIN(g.gcs_total) AS gcs_min_48_72h,
    MAX(g.gcs_total) AS gcs_max_48_72h,
    COUNT(g.gcs_total) AS n_gcs_48_72h
FROM sabd_base_cohort b
LEFT JOIN sabd_gcs_long g
    ON b.stay_id = g.stay_id
   AND g.hours_from_icu >= 48
   AND g.hours_from_icu < 72
GROUP BY b.stay_id;

CREATE INDEX IF NOT EXISTS idx_sabd_gcs_48_72h_stay ON sabd_gcs_48_72h(stay_id);

/* =============================================================================
   04. First 24-h vital signs: heart rate, MAP
   ============================================================================= */
DROP TABLE IF EXISTS sabd_vitals_24h CASCADE;
CREATE TABLE sabd_vitals_24h AS
WITH vital_items AS (
    SELECT 'heart_rate'::TEXT AS vital_name, 220045::INT AS itemid, 0::NUMERIC AS lower_bound, 300::NUMERIC AS upper_bound
    UNION ALL SELECT 'map', 220052, 20, 300
    UNION ALL SELECT 'map', 220181, 20, 300
    UNION ALL SELECT 'map', 225312, 20, 300
), vital_data AS (
    SELECT
        b.stay_id,
        vi.vital_name,
        ce.valuenum::NUMERIC AS valuenum,
        ROW_NUMBER() OVER (
            PARTITION BY b.stay_id, vi.vital_name
            ORDER BY ce.charttime, ce.itemid
        ) AS rn_first
    FROM sabd_base_cohort b
    JOIN mimiciv_icu.chartevents ce
        ON b.stay_id = ce.stay_id
    JOIN vital_items vi
        ON ce.itemid = vi.itemid
    WHERE ce.valuenum IS NOT NULL
      AND ce.charttime >= b.icu_intime
      AND ce.charttime < LEAST(b.icu_outtime, b.icu_intime + INTERVAL '24 hours')
      AND ce.valuenum >= vi.lower_bound
      AND ce.valuenum <= vi.upper_bound
)
SELECT
    stay_id,
    MAX(CASE WHEN vital_name = 'heart_rate' THEN value_first_24h END) AS heart_rate_first_24h,
    MAX(CASE WHEN vital_name = 'heart_rate' THEN value_min_24h END) AS heart_rate_min_24h,
    MAX(CASE WHEN vital_name = 'heart_rate' THEN value_max_24h END) AS heart_rate_max_24h,
    MAX(CASE WHEN vital_name = 'map' THEN value_first_24h END) AS map_first_24h,
    MAX(CASE WHEN vital_name = 'map' THEN value_min_24h END) AS map_min_24h,
    MAX(CASE WHEN vital_name = 'map' THEN value_max_24h END) AS map_max_24h
FROM (
    SELECT
        stay_id,
        vital_name,
        MAX(CASE WHEN rn_first = 1 THEN valuenum END) AS value_first_24h,
        MIN(valuenum) AS value_min_24h,
        MAX(valuenum) AS value_max_24h
    FROM vital_data
    GROUP BY stay_id, vital_name
) sub
GROUP BY stay_id;

CREATE INDEX IF NOT EXISTS idx_sabd_vitals_stay ON sabd_vitals_24h(stay_id);

/* =============================================================================
   05. First 24-h laboratory values
   ============================================================================= */
DROP TABLE IF EXISTS sabd_labs_24h CASCADE;
CREATE TABLE sabd_labs_24h AS
WITH lab_items AS (
    SELECT 'creatinine'::TEXT AS lab_name, 50912::INT AS itemid, 0::NUMERIC AS lower_bound, 150::NUMERIC AS upper_bound
    UNION ALL SELECT 'creatinine', 52546, 0, 150
    UNION ALL SELECT 'sodium', 50983, 80, 200
    UNION ALL SELECT 'sodium', 52653, 80, 200
    UNION ALL SELECT 'glucose', 50931, 0, 10000
    UNION ALL SELECT 'glucose', 52569, 0, 10000
    UNION ALL SELECT 'lactate', 50813, 0, 50
    UNION ALL SELECT 'lactate', 52654, 0, 50
), lab_data AS (
    SELECT
        b.stay_id,
        li.lab_name,
        le.valuenum::NUMERIC AS valuenum,
        ROW_NUMBER() OVER (PARTITION BY b.stay_id, li.lab_name ORDER BY le.charttime, le.itemid) AS rn_first
    FROM sabd_base_cohort b
    JOIN mimiciv_hosp.labevents le
        ON b.hadm_id = le.hadm_id
    JOIN lab_items li
        ON le.itemid = li.itemid
    WHERE le.valuenum IS NOT NULL
      AND le.charttime >= b.icu_intime
      AND le.charttime < LEAST(b.icu_outtime, b.icu_intime + INTERVAL '24 hours')
      AND le.valuenum >= li.lower_bound
      AND le.valuenum <= li.upper_bound
)
SELECT
    stay_id,
    MAX(CASE WHEN lab_name = 'creatinine' AND rn_first = 1 THEN valuenum END) AS creatinine_first_24h,
    MAX(CASE WHEN lab_name = 'sodium'    AND rn_first = 1 THEN valuenum END) AS sodium_first_24h,
    MAX(CASE WHEN lab_name = 'glucose'   AND rn_first = 1 THEN valuenum END) AS glucose_first_24h,
    MAX(CASE WHEN lab_name = 'lactate'   AND rn_first = 1 THEN valuenum END) AS lactate_first_24h
FROM lab_data
GROUP BY stay_id;

CREATE INDEX IF NOT EXISTS idx_sabd_labs_stay ON sabd_labs_24h(stay_id);

/* =============================================================================
   06. Comorbidities: chronic kidney disease, respiratory failure
   ============================================================================= */
DROP TABLE IF EXISTS sabd_comorbidities CASCADE;
CREATE TABLE sabd_comorbidities AS
SELECT
    b.stay_id,
    COALESCE(ch.renal_disease, 0)::SMALLINT AS chronic_kidney_disease,
    COALESCE(ch.chronic_pulmonary_disease, 0)::SMALLINT AS chronic_pulmonary_disease
FROM sabd_base_cohort b
LEFT JOIN charlson ch
    ON b.hadm_id = ch.hadm_id;

/* Respiratory failure from diagnoses */
DROP TABLE IF EXISTS sabd_resp_failure CASCADE;
CREATE TABLE sabd_resp_failure AS
WITH dx AS (
    SELECT
        d.hadm_id,
        d.icd_version,
        REPLACE(UPPER(d.icd_code), '.', '') AS icd_code_clean,
        LOWER(COALESCE(dic.long_title, '')) AS long_title
    FROM mimiciv_hosp.diagnoses_icd d
    LEFT JOIN mimiciv_hosp.d_icd_diagnoses dic
        ON d.icd_code = dic.icd_code
       AND d.icd_version = dic.icd_version
)
SELECT
    b.hadm_id,
    MAX(CASE WHEN
        (dx.icd_version = 10 AND (
            SUBSTR(dx.icd_code_clean, 1, 3) IN ('J96','J80','J90','J91','J92','J93','J94','J95','J98','J99')
            OR dx.icd_code_clean LIKE 'J96%'
        ))
        OR (dx.icd_version = 9 AND (
            SUBSTR(dx.icd_code_clean, 1, 3) IN ('518','519')
            OR SUBSTR(dx.icd_code_clean, 1, 4) = '5188'
        ))
        OR dx.long_title ~ '(respiratory failure|acute respiratory failure|chronic respiratory failure|acute on chronic respiratory failure|hypercapnic respiratory failure|hypoxemic respiratory failure|ards|acute respiratory distress syndrome)'
    THEN 1 ELSE 0 END) AS respiratory_failure
FROM sabd_base_cohort b
LEFT JOIN dx
    ON b.hadm_id = dx.hadm_id
GROUP BY b.hadm_id;

CREATE INDEX IF NOT EXISTS idx_sabd_resp_fail_hadm ON sabd_resp_failure(hadm_id);

/* =============================================================================
   07. ICU treatments: invasive mechanical ventilation, dexmedetomidine, opioids
   ============================================================================= */
DROP TABLE IF EXISTS sabd_treatments_24h CASCADE;
CREATE TABLE sabd_treatments_24h AS
WITH vent AS (
    SELECT
        b.stay_id,
        MAX(CASE WHEN v.stay_id IS NOT NULL THEN 1 ELSE 0 END)::SMALLINT AS invasive_mechanical_ventilation_24h
    FROM sabd_base_cohort b
    LEFT JOIN ventilation v
        ON b.stay_id = v.stay_id
       AND v.ventilation_status = 'InvasiveVent'
       AND v.starttime < LEAST(b.icu_outtime, b.icu_intime + INTERVAL '24 hours')
       AND v.endtime >= b.icu_intime
    GROUP BY b.stay_id
), rx AS (
    SELECT
        b.stay_id,
        MAX(CASE WHEN LOWER(COALESCE(p.drug, '')) ~ '(dexmedetomidine|precedex)' THEN 1 ELSE 0 END)::SMALLINT AS dexmedetomidine_24h,
        MAX(CASE WHEN LOWER(COALESCE(p.drug, '')) ~ '(fentanyl|morphine|hydromorphone|oxycodone|hydrocodone|remifentanil|sufentanil|methadone)' THEN 1 ELSE 0 END)::SMALLINT AS opioid_24h
    FROM sabd_base_cohort b
    JOIN mimiciv_hosp.prescriptions p
        ON b.hadm_id = p.hadm_id
       AND p.starttime IS NOT NULL
       AND p.starttime < LEAST(b.icu_outtime, b.icu_intime + INTERVAL '24 hours')
       AND COALESCE(p.stoptime, p.starttime) >= b.icu_intime
       AND COALESCE(p.drug_type, '') <> 'BASE'
       AND COALESCE(p.route, '') NOT IN ('OU','OS','OD','AU','AS','AD','TP','TOP','TD')
    WHERE LOWER(COALESCE(p.drug, '')) ~ '(dexmedetomidine|precedex|fentanyl|morphine|hydromorphone|oxycodone|hydrocodone|remifentanil|sufentanil|methadone)'
    GROUP BY b.stay_id
), ie AS (
    SELECT
        b.stay_id,
        MAX(CASE WHEN LOWER(COALESCE(di.label, '')) ~ '(dexmedetomidine|precedex)' THEN 1 ELSE 0 END)::SMALLINT AS dexmedetomidine_infusion_24h,
        MAX(CASE WHEN LOWER(COALESCE(di.label, '')) ~ '(fentanyl|morphine|hydromorphone|remifentanil|sufentanil)' THEN 1 ELSE 0 END)::SMALLINT AS opioid_infusion_24h
    FROM sabd_base_cohort b
    JOIN mimiciv_icu.inputevents inp
        ON b.stay_id = inp.stay_id
       AND inp.starttime < LEAST(b.icu_outtime, b.icu_intime + INTERVAL '24 hours')
       AND COALESCE(inp.endtime, inp.starttime) >= b.icu_intime
    JOIN mimiciv_icu.d_items di
        ON inp.itemid = di.itemid
    WHERE LOWER(COALESCE(di.label, '')) ~ '(dexmedetomidine|precedex|fentanyl|morphine|hydromorphone|remifentanil|sufentanil)'
    GROUP BY b.stay_id
)
SELECT
    b.stay_id,
    COALESCE(v.invasive_mechanical_ventilation_24h, 0) AS invasive_mechanical_ventilation_24h,
    GREATEST(COALESCE(rx.dexmedetomidine_24h, 0), COALESCE(ie.dexmedetomidine_infusion_24h, 0)) AS dexmedetomidine_24h,
    GREATEST(COALESCE(rx.opioid_24h, 0), COALESCE(ie.opioid_infusion_24h, 0)) AS opioid_24h
FROM sabd_base_cohort b
LEFT JOIN vent v ON b.stay_id = v.stay_id
LEFT JOIN rx ON b.stay_id = rx.stay_id
LEFT JOIN ie ON b.stay_id = ie.stay_id;

CREATE INDEX IF NOT EXISTS idx_sabd_treatments_stay ON sabd_treatments_24h(stay_id);

/* =============================================================================
   08. Severity scores: OASIS and SOFA (from derived tables)
   ============================================================================= */
DROP TABLE IF EXISTS sabd_severity CASCADE;
CREATE TABLE sabd_severity AS
SELECT
    b.stay_id,
    fds.sofa AS sofa_24h,
    oa.oasis
FROM sabd_base_cohort b
LEFT JOIN first_day_sofa fds
    ON b.stay_id = fds.stay_id
LEFT JOIN oasis oa
    ON b.stay_id = oa.stay_id;

CREATE INDEX IF NOT EXISTS idx_sabd_severity_stay ON sabd_severity(stay_id);

/* =============================================================================
   09. Pre-ICU statin use
   ============================================================================= */
DROP TABLE IF EXISTS sabd_statin_exposure CASCADE;
CREATE TABLE sabd_statin_exposure AS
SELECT DISTINCT
    b.subject_id,
    b.hadm_id,
    b.stay_id,
    1 AS pre_icu_statin_use
FROM sabd_base_cohort b
JOIN mimiciv_hosp.prescriptions p
    ON b.hadm_id = p.hadm_id
WHERE p.starttime IS NOT NULL
  AND p.starttime < b.icu_intime
  AND COALESCE(p.drug_type, '') <> 'BASE'
  AND LOWER(COALESCE(p.drug, '')) ~ '(atorvastatin|simvastatin|lovastatin|pitavastatin|fluvastatin|pravastatin|rosuvastatin|lipitor|zocor|mevacor|crestor|pravachol|lescol|livalo)';

CREATE INDEX IF NOT EXISTS idx_sabd_statin_stay ON sabd_statin_exposure(stay_id);

/* =============================================================================
   10. Final analytic cohort
   ============================================================================= */
DROP TABLE IF EXISTS sabd_persistent_cohort CASCADE;
CREATE TABLE sabd_persistent_cohort AS
SELECT
    b.database_source,
    b.subject_id,
    b.hadm_id,
    b.stay_id,
    b.icu_intime,
    b.icu_outtime,
    b.icu_los_days,
    b.age,
    b.sex_male,
    b.race,

    /* GCS */
    g.gcs_min_0_24h AS gcs_min_first_24h,
    g.gcs_max_0_24h AS gcs_max_first_24h,
    g.n_gcs_0_24h,

    /* Vital signs */
    v.heart_rate_min_24h,
    v.heart_rate_max_24h,
    v.map_min_24h,
    v.map_max_24h,

    /* Laboratory */
    l.creatinine_first_24h,
    l.sodium_first_24h,
    l.glucose_first_24h,
    l.lactate_first_24h,

    /* Severity scores */
    sev.oasis,
    sev.sofa_24h AS sofa,

    /* Comorbidities */
    c.chronic_kidney_disease,
    COALESCE(rf.respiratory_failure, 0)::SMALLINT AS respiratory_failure,

    /* Treatments */
    t.invasive_mechanical_ventilation_24h,
    t.dexmedetomidine_24h,
    t.opioid_24h,

    /* Pre-ICU statin use */
    COALESCE(st.pre_icu_statin_use, 0) AS pre_icu_statin_use,

    /* Exclusion flags */
    ex.acute_brain_injury,
    ex.alcohol_abuse,

    /* Outcome: persistent SABD at ICU day 3 */
    CASE WHEN g48.gcs_min_48_72h IS NOT NULL AND g48.gcs_min_48_72h < 15 THEN 1
         WHEN g48.gcs_min_48_72h IS NOT NULL AND g48.gcs_min_48_72h >= 15 THEN 0
         ELSE NULL
    END::SMALLINT AS persistent_sabd_day3,
    g48.gcs_min_48_72h,
    g48.gcs_max_48_72h,
    g48.n_gcs_48_72h,

    /* Mortality */
    b.hosp_mort

FROM sabd_base_cohort b
INNER JOIN sabd_gcs_0_24h g
  ON b.stay_id = g.stay_id AND g.gcs_max_0_24h < 15
LEFT JOIN sabd_gcs_48_72h g48 ON b.stay_id = g48.stay_id
LEFT JOIN sabd_vitals_24h v ON b.stay_id = v.stay_id
LEFT JOIN sabd_labs_24h l ON b.stay_id = l.stay_id
LEFT JOIN sabd_comorbidities c ON b.stay_id = c.stay_id
LEFT JOIN sabd_resp_failure rf ON b.hadm_id = rf.hadm_id
LEFT JOIN sabd_treatments_24h t ON b.stay_id = t.stay_id
LEFT JOIN sabd_statin_exposure st ON b.stay_id = st.stay_id
LEFT JOIN sabd_exclusion_flags ex ON b.stay_id = ex.stay_id
LEFT JOIN sabd_severity sev ON b.stay_id = sev.stay_id;

CREATE INDEX IF NOT EXISTS idx_sabd_final_stay ON sabd_persistent_cohort(stay_id);

/* =============================================================================
   11. Quality control summaries
   ============================================================================= */
SELECT COUNT(*) AS total_cohort_size FROM sabd_persistent_cohort;

SELECT
    persistent_sabd_day3,
    COUNT(*) AS n,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM sabd_persistent_cohort
GROUP BY persistent_sabd_day3;

SELECT
    COUNT(*) AS n,
    ROUND(AVG(age)::NUMERIC, 1) AS mean_age,
    SUM(sex_male) AS male_n,
    ROUND(100.0 * SUM(sex_male) / COUNT(*), 1) AS male_pct
FROM sabd_persistent_cohort;

SELECT
    COUNT(*) AS n,
    SUM(pre_icu_statin_use) AS statin_use_n,
    SUM(invasive_mechanical_ventilation_24h) AS imv_n,
    SUM(dexmedetomidine_24h) AS dexmedetomidine_n,
    SUM(opioid_24h) AS opioid_n,
    SUM(chronic_kidney_disease) AS ckd_n,
    SUM(respiratory_failure) AS resp_failure_n
FROM sabd_persistent_cohort;
