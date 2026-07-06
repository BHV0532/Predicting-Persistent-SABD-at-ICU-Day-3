/*
================================================================================
eICU-CRD Cohort Extraction for Persistent Sepsis-Associated Brain Dysfunction
Prediction Model

Database: eICU Collaborative Research Database v2.0
Environment: PostgreSQL
Final output table: sabd_persistent_cohort

Cohort definition:
  - Adult patients (age >= 18)
  - First ICU stay (unitvisitnumber = 1)
  - Diagnosed sepsis (APACHE admission diagnosis or diagnosis table)
  - SABD within first 24 hours (GCS < 15)

Outcome:
  - Persistent SABD at ICU day 3: peak GCS < 15 during 48-72 hours

Predictors extracted (all within first 24 hours of ICU admission):
  - Neurological: peak GCS (0-24h)
  - Severity scores: OASIS, SOFA (approximate)
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

SET search_path TO public;

/* Helper function for regex matching */
CREATE OR REPLACE FUNCTION REGEXP_CONTAINS(str TEXT, pattern TEXT) RETURNS BOOL AS $$
BEGIN
  RETURN str ~ pattern;
END; $$ LANGUAGE PLPGSQL;

/* =============================================================================
   01. Base cohort: adult, first ICU stay
   ============================================================================= */
DROP TABLE IF EXISTS sabd_base_cohort CASCADE;
CREATE TABLE sabd_base_cohort AS
SELECT
    p.uniquepid,
    p.patienthealthsystemstayid,
    p.patientunitstayid,
    p.unitvisitnumber,
    p.hospitalid,
    p.unittype,
    p.apacheadmissiondx,
    p.hospitaladmitoffset,
    p.unitdischargeoffset,
    CASE
      WHEN p.age = '> 89' THEN 91
      WHEN p.age ~ '^[0-9]+$' THEN p.age::INT
      ELSE NULL
    END AS age,
    CASE
      WHEN LOWER(p.gender) LIKE '%female%' THEN 0
      WHEN LOWER(p.gender) LIKE '%male%'   THEN 1
      ELSE NULL
    END AS sex_male,
    p.gender AS sex_raw,
    p.ethnicity AS race,
    CASE
      WHEN LOWER(p.hospitaldischargestatus) LIKE '%expired%' THEN 1
      WHEN LOWER(p.hospitaldischargestatus) LIKE '%alive%'   THEN 0
      ELSE NULL
    END AS hosp_mort,
    CASE
      WHEN LOWER(p.unitdischargestatus) LIKE '%expired%' THEN 1
      WHEN LOWER(p.unitdischargestatus) LIKE '%alive%'   THEN 0
      ELSE NULL
    END AS icu_mort,
    p.admissionheight,
    p.admissionweight
FROM patient p
WHERE p.unitvisitnumber = 1
  AND (
    CASE
      WHEN p.age = '> 89' THEN 91
      WHEN p.age ~ '^[0-9]+$' THEN p.age::INT
      ELSE NULL
    END
  ) >= 18;

CREATE INDEX IF NOT EXISTS idx_sabd_base_patientunitstayid
ON sabd_base_cohort(patientunitstayid);

/* =============================================================================
   02. Sepsis flag: APACHE admission diagnosis or diagnosis table
   ============================================================================= */
DROP TABLE IF EXISTS sabd_sepsis_flag CASCADE;
CREATE TABLE sabd_sepsis_flag AS
SELECT
    b.patientunitstayid,
    MAX(
      CASE
        WHEN LOWER(COALESCE(b.apacheadmissiondx, '')) LIKE '%sepsis%'
          OR (
              (LOWER(COALESCE(d.diagnosisstring, '')) LIKE '%sepsis%'
                OR LOWER(COALESCE(d.diagnosisstring, '')) LIKE '%septic%')
              AND LOWER(COALESCE(d.diagnosisstring, '')) !~ '(rule out|r/o|history of|hx of|past history|family history|screening)'
             )
          OR COALESCE(d.icd9code, '') ~ '(^|,| )995\.9[12]($|,| )'
          OR COALESCE(d.icd9code, '') ~ '(^|,| )785\.52($|,| )'
          OR COALESCE(d.icd9code, '') ~ '(^|,| )038'
        THEN 1 ELSE 0 END
    ) AS sepsis
FROM sabd_base_cohort b
LEFT JOIN diagnosis d
  ON b.patientunitstayid = d.patientunitstayid
GROUP BY b.patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_sabd_sepsis_patientunitstayid
ON sabd_sepsis_flag(patientunitstayid);

/* =============================================================================
   03. Exclusion flags: acute brain injury and alcohol abuse
   ============================================================================= */
DROP TABLE IF EXISTS sabd_exclusion_flags CASCADE;
CREATE TABLE sabd_exclusion_flags AS
SELECT
    b.patientunitstayid,
    MAX(CASE
      WHEN LOWER(COALESCE(d.diagnosisstring, '')) ~
           '(meningitis|encephalitis|status epilepticus|traumatic brain injury|head trauma|cerebrovascular accident|stroke|intracranial hemorrhage|subarachnoid hemorrhage|subdural|epidural|brain injury|brain abscess|anoxic brain)'
        OR LOWER(COALESCE(b.apacheadmissiondx, '')) ~
           '(cva|stroke|intracranial|subarachnoid|head.*trauma|traumatic brain injury|seizures|status epilepticus|meningitis|encephalitis|brain abscess|nontraumatic coma due to anoxia|anoxia/ischemia)'
        OR LOWER(COALESCE(ph.pasthistorypath, '')) ~
           '(stroke|cva|subarachnoid|intracranial|traumatic brain injury|meningitis|encephalitis|seizure|epilepsy)'
      THEN 1 ELSE 0 END) AS acute_brain_injury_or_major_neuro,
    MAX(CASE
      WHEN LOWER(COALESCE(d.diagnosisstring, '')) ~ '(alcohol abuse|alcohol dependence|alcohol withdrawal|alcohol intoxication|alcoholism)'
        OR LOWER(COALESCE(ph.pasthistorypath, '')) ~ '(alcohol abuse|alcohol dependence|alcohol withdrawal|alcoholism)'
        OR LOWER(COALESCE(b.apacheadmissiondx, '')) ~ '(overdose, alcohol|alcohol)'
      THEN 1 ELSE 0 END) AS alcohol_abuse
FROM sabd_base_cohort b
LEFT JOIN diagnosis d
  ON b.patientunitstayid = d.patientunitstayid
LEFT JOIN pasthistory ph
  ON b.patientunitstayid = ph.patientunitstayid
GROUP BY b.patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_sabd_excl_patientunitstayid
ON sabd_exclusion_flags(patientunitstayid);

/* =============================================================================
   04. GCS extraction: first 24 hours and 48-72 hours
   ============================================================================= */
DROP TABLE IF EXISTS sabd_gcs_0_24h CASCADE;
CREATE TABLE sabd_gcs_0_24h AS
WITH nc AS (
  SELECT
      patientunitstayid,
      nursingchartoffset AS chartoffset,
      MIN(CASE
        WHEN nursingchartcelltypevallabel = 'Glasgow coma score'
         AND nursingchartcelltypevalname = 'GCS Total'
         AND REGEXP_CONTAINS(nursingchartvalue, '^[-]?[0-9]+[.]?[0-9]*$')
         AND nursingchartvalue NOT IN ('-', '.')
          THEN CAST(nursingchartvalue AS NUMERIC)
        WHEN nursingchartcelltypevallabel = 'Score (Glasgow Coma Scale)'
         AND nursingchartcelltypevalname = 'Value'
         AND REGEXP_CONTAINS(nursingchartvalue, '^[-]?[0-9]+[.]?[0-9]*$')
         AND nursingchartvalue NOT IN ('-', '.')
          THEN CAST(nursingchartvalue AS NUMERIC)
        ELSE NULL END) AS gcs
  FROM nursecharting
  WHERE nursingchartcelltypecat IN ('Scores', 'Other Vital Signs and Infusions')
    AND nursingchartoffset BETWEEN 0 AND 1440
  GROUP BY patientunitstayid, nursingchartoffset
), valid AS (
  SELECT patientunitstayid, chartoffset, gcs
  FROM nc
  WHERE gcs > 2 AND gcs < 16
)
SELECT
    patientunitstayid,
    MIN(gcs) AS gcs_min_0_24h,
    MAX(gcs) AS gcs_max_0_24h,
    MIN(chartoffset) AS first_gcs_offset
FROM valid
GROUP BY patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_sabd_gcs_0_24h_patientunitstayid
ON sabd_gcs_0_24h(patientunitstayid);

/* GCS during 48-72 hours for outcome definition */
DROP TABLE IF EXISTS sabd_gcs_48_72h CASCADE;
CREATE TABLE sabd_gcs_48_72h AS
WITH nc AS (
  SELECT
      patientunitstayid,
      nursingchartoffset AS chartoffset,
      MIN(CASE
        WHEN nursingchartcelltypevallabel = 'Glasgow coma score'
         AND nursingchartcelltypevalname = 'GCS Total'
         AND REGEXP_CONTAINS(nursingchartvalue, '^[-]?[0-9]+[.]?[0-9]*$')
         AND nursingchartvalue NOT IN ('-', '.')
          THEN CAST(nursingchartvalue AS NUMERIC)
        WHEN nursingchartcelltypevallabel = 'Score (Glasgow Coma Scale)'
         AND nursingchartcelltypevalname = 'Value'
         AND REGEXP_CONTAINS(nursingchartvalue, '^[-]?[0-9]+[.]?[0-9]*$')
         AND nursingchartvalue NOT IN ('-', '.')
          THEN CAST(nursingchartvalue AS NUMERIC)
        ELSE NULL END) AS gcs
  FROM nursecharting
  WHERE nursingchartcelltypecat IN ('Scores', 'Other Vital Signs and Infusions')
    AND nursingchartoffset BETWEEN 2880 AND 4320
  GROUP BY patientunitstayid, nursingchartoffset
), valid AS (
  SELECT patientunitstayid, chartoffset, gcs
  FROM nc
  WHERE gcs > 2 AND gcs < 16
)
SELECT
    patientunitstayid,
    MIN(gcs) AS gcs_min_48_72h,
    MAX(gcs) AS gcs_max_48_72h,
    COUNT(*) AS n_gcs_48_72h
FROM valid
GROUP BY patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_sabd_gcs_48_72h_patientunitstayid
ON sabd_gcs_48_72h(patientunitstayid);

/* =============================================================================
   05. First 24-h vital signs: heart rate, MAP
   ============================================================================= */
DROP TABLE IF EXISTS sabd_vitals_24h CASCADE;
CREATE TABLE sabd_vitals_24h AS
WITH vitals_long AS (
  SELECT patientunitstayid, observationoffset AS chartoffset,
         SAFE_TO_NUMERIC(heartrate::TEXT) AS heartrate,
         SAFE_TO_NUMERIC(noninvasivemean::TEXT) AS map_nibp
  FROM vitalperiodic
  WHERE observationoffset BETWEEN 0 AND 1440

  UNION ALL

  SELECT
      patientunitstayid,
      nursingchartoffset AS chartoffset,
      CASE WHEN nursingchartcelltypevallabel = 'Heart Rate'
             AND nursingchartcelltypevalname = 'Heart Rate'
             AND nursingchartvalue ~ '^[-]?[0-9]+[.]?[0-9]*$'
           THEN nursingchartvalue::NUMERIC ELSE NULL END AS heartrate,
      CASE WHEN (
                (nursingchartcelltypevallabel = 'Invasive BP' AND nursingchartcelltypevalname = 'Invasive BP Mean')
             OR (nursingchartcelltypevallabel = 'Non-Invasive BP' AND nursingchartcelltypevalname = 'Non-Invasive BP Mean')
             OR (nursingchartcelltypevallabel IN ('MAP (mmHg)', 'Arterial Line MAP (mmHg)') AND nursingchartcelltypevalname = 'Value')
           )
             AND nursingchartvalue ~ '^[-]?[0-9]+[.]?[0-9]*$'
           THEN nursingchartvalue::NUMERIC ELSE NULL END AS map_chart
  FROM nursecharting
  WHERE nursingchartoffset BETWEEN 0 AND 1440
    AND nursingchartcelltypecat IN ('Vital Signs','Scores','Other Vital Signs and Infusions')
), clean AS (
  SELECT
      patientunitstayid,
      CASE WHEN heartrate BETWEEN 25 AND 225 THEN heartrate END AS heartrate,
      CASE WHEN map_nibp BETWEEN 1 AND 250 THEN map_nibp
           WHEN map_chart BETWEEN 1 AND 250 THEN map_chart END AS map
  FROM vitals_long
)
SELECT
    patientunitstayid,
    MIN(heartrate) AS heart_rate_min_24h,
    MAX(heartrate) AS heart_rate_max_24h,
    MIN(map) AS map_min_24h,
    MAX(map) AS map_max_24h
FROM clean
GROUP BY patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_sabd_vitals_patientunitstayid
ON sabd_vitals_24h(patientunitstayid);

/* =============================================================================
   06. First 24-h laboratory values
   ============================================================================= */
DROP TABLE IF EXISTS sabd_labs_24h CASCADE;
CREATE TABLE sabd_labs_24h AS
WITH lab_clean AS (
  SELECT
      l.patientunitstayid,
      LOWER(l.labname) AS labname,
      l.labresultoffset,
      CASE
        WHEN LOWER(l.labname) = 'creatinine'       AND l.labresult > 150   THEN NULL
        WHEN LOWER(l.labname) = 'sodium'           AND l.labresult > 200   THEN NULL
        WHEN LOWER(l.labname) = 'glucose'          AND l.labresult > 10000 THEN NULL
        WHEN LOWER(l.labname) = 'lactate'          AND l.labresult > 50    THEN NULL
        ELSE l.labresult
      END AS labresult
  FROM lab l
  WHERE l.labresultoffset BETWEEN 0 AND 1440
    AND l.labresult IS NOT NULL
    AND l.labresult > 0
    AND LOWER(l.labname) IN ('creatinine', 'sodium', 'glucose', 'lactate')
), ranked AS (
  SELECT
      patientunitstayid,
      labname,
      labresult,
      ROW_NUMBER() OVER (
        PARTITION BY patientunitstayid, labname
        ORDER BY labresultoffset ASC
      ) AS rn_first
  FROM lab_clean
  WHERE labresult IS NOT NULL
)
SELECT
    patientunitstayid,
    MAX(CASE WHEN labname = 'creatinine' AND rn_first = 1 THEN labresult END) AS creatinine_first_24h,
    MAX(CASE WHEN labname = 'sodium'    AND rn_first = 1 THEN labresult END) AS sodium_first_24h,
    MAX(CASE WHEN labname = 'glucose'   AND rn_first = 1 THEN labresult END) AS glucose_first_24h,
    MAX(CASE WHEN labname = 'lactate'   AND rn_first = 1 THEN labresult END) AS lactate_first_24h
FROM ranked
GROUP BY patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_sabd_labs_patientunitstayid
ON sabd_labs_24h(patientunitstayid);

/* =============================================================================
   07. Comorbidities: chronic kidney disease, respiratory failure
   ============================================================================= */
DROP TABLE IF EXISTS sabd_comorbidities CASCADE;
CREATE TABLE sabd_comorbidities AS
SELECT
    b.patientunitstayid,
    MAX(CASE
      WHEN LOWER(COALESCE(d.diagnosisstring, '')) ~ '(chronic kidney disease|chronic renal failure|end stage renal disease|esrd|hemodialysis|peritoneal dialysis|ckd)'
        OR LOWER(COALESCE(ph.pasthistorypath, '')) ~ '(chronic kidney disease|chronic renal failure|end stage renal disease|esrd|hemodialysis|peritoneal dialysis|ckd|renal failure|renal insufficiency)'
      THEN 1 ELSE 0 END) AS chronic_kidney_disease,
    MAX(CASE
      WHEN LOWER(COALESCE(d.diagnosisstring, '')) ~ '(respiratory failure|acute respiratory failure|chronic respiratory failure|acute on chronic respiratory failure|hypercapnic respiratory failure|hypoxemic respiratory failure|ards|acute respiratory distress syndrome)'
        OR LOWER(COALESCE(b.apacheadmissiondx, '')) ~ '(respiratory failure|ards|acute respiratory distress)'
      THEN 1 ELSE 0 END) AS respiratory_failure
FROM sabd_base_cohort b
LEFT JOIN diagnosis d
  ON b.patientunitstayid = d.patientunitstayid
LEFT JOIN pasthistory ph
  ON b.patientunitstayid = ph.patientunitstayid
GROUP BY b.patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_sabd_comorb_patientunitstayid
ON sabd_comorbidities(patientunitstayid);

/* =============================================================================
   08. ICU treatments: invasive mechanical ventilation, dexmedetomidine, opioids
   ============================================================================= */
DROP TABLE IF EXISTS sabd_treatments_24h CASCADE;
CREATE TABLE sabd_treatments_24h AS
WITH med AS (
  SELECT
      m.patientunitstayid,
      LOWER(COALESCE(m.drugname, '')) AS drugname,
      COALESCE(m.drugstartoffset, m.drugorderoffset) AS startoffset
  FROM medication m
  WHERE COALESCE(m.drugordercancelled, 'No') = 'No'
), infusion AS (
  SELECT patientunitstayid, LOWER(COALESCE(drugname, '')) AS drugname, infusionoffset AS startoffset
  FROM infusiondrug
), treatment_flags AS (
  SELECT
      patientunitstayid,
      MAX(CASE WHEN treatmentoffset BETWEEN 0 AND 1440
                AND LOWER(COALESCE(treatmentstring, '')) ~ '(mechanical ventilation|ventilator|intubation|endotracheal|invasive ventilation)'
               THEN 1 ELSE 0 END) AS invasive_vent_treatment
  FROM treatment
  GROUP BY patientunitstayid
), vent_flags AS (
  SELECT patientunitstayid, MAX(vent) AS invasive_mechanical_ventilation
  FROM (
      SELECT patientunitstayid, 1 AS vent
      FROM respiratorycharting
      WHERE respchartoffset BETWEEN 0 AND 1440
        AND respchartvaluelabel IN ('PEEP', 'Total RR', 'Vent Rate', 'Tidal Volume (set)', 'TV/kg IBW', 'Mean Airway Pressure', 'Peak Insp. Pressure')
      UNION ALL
      SELECT patientunitstayid, 1 AS vent
      FROM respiratorycare
      WHERE respcarestatusoffset BETWEEN 0 AND 1440
        AND (airwaytype IS NOT NULL OR airwaysize IS NOT NULL OR airwayposition IS NOT NULL OR cuffpressure IS NOT NULL OR setapneatv IS NOT NULL)
      UNION ALL
      SELECT patientunitstayid, 1 AS vent
      FROM apacheapsvar
      WHERE intubated = 1
      UNION ALL
      SELECT patientunitstayid, 1 AS vent
      FROM apachepredvar
      WHERE oobintubday1 = 1
  ) v
  GROUP BY patientunitstayid
), med_flags AS (
  SELECT
      patientunitstayid,
      MAX(CASE WHEN startoffset BETWEEN 0 AND 1440
                AND drugname ~ '(dexmedetomidine|precedex)'
               THEN 1 ELSE 0 END) AS dexmedetomidine_24h,
      MAX(CASE WHEN startoffset BETWEEN 0 AND 1440
                AND drugname ~ '(fentanyl|morphine|hydromorphone|oxycodone|hydrocodone|remifentanil|sufentanil|methadone)'
               THEN 1 ELSE 0 END) AS opioid_24h
  FROM med
  GROUP BY patientunitstayid
), infusion_flags AS (
  SELECT
      patientunitstayid,
      MAX(CASE WHEN startoffset BETWEEN 0 AND 1440
                AND drugname ~ '(dexmedetomidine|precedex)'
               THEN 1 ELSE 0 END) AS dexmedetomidine_infusion_24h,
      MAX(CASE WHEN startoffset BETWEEN 0 AND 1440
                AND drugname ~ '(fentanyl|morphine|hydromorphone|remifentanil|sufentanil)'
               THEN 1 ELSE 0 END) AS opioid_infusion_24h
  FROM infusion
  GROUP BY patientunitstayid
)
SELECT
    b.patientunitstayid,
    CASE WHEN COALESCE(v.invasive_mechanical_ventilation,0)=1 OR COALESCE(t.invasive_vent_treatment,0)=1 THEN 1 ELSE 0 END AS invasive_mechanical_ventilation_24h,
    CASE WHEN COALESCE(m.dexmedetomidine_24h,0)=1 OR COALESCE(i.dexmedetomidine_infusion_24h,0)=1 THEN 1 ELSE 0 END AS dexmedetomidine_24h,
    CASE WHEN COALESCE(m.opioid_24h,0)=1 OR COALESCE(i.opioid_infusion_24h,0)=1 THEN 1 ELSE 0 END AS opioid_24h
FROM sabd_base_cohort b
LEFT JOIN med_flags m ON b.patientunitstayid = m.patientunitstayid
LEFT JOIN infusion_flags i ON b.patientunitstayid = i.patientunitstayid
LEFT JOIN treatment_flags t ON b.patientunitstayid = t.patientunitstayid
LEFT JOIN vent_flags v ON b.patientunitstayid = v.patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_sabd_treatments_patientunitstayid
ON sabd_treatments_24h(patientunitstayid);

/* =============================================================================
   09. OASIS score
   ============================================================================= */
DROP TABLE IF EXISTS sabd_oasis CASCADE;
CREATE TABLE sabd_oasis AS
WITH elective AS (
  SELECT
      b.patientunitstayid,
      CASE
        WHEN apv.electivesurgery = 0 THEN 6
        WHEN apv.electivesurgery IS NULL THEN 6
        WHEN b.unitadmitsource = 'Emergency Department' THEN 6
        ELSE 0
      END AS electivesurgery_oasis
  FROM sabd_base_cohort b
  LEFT JOIN apachepredvar apv
    ON b.patientunitstayid = apv.patientunitstayid
), components AS (
  SELECT
      b.patientunitstayid,
      CASE
        WHEN b.hospitaladmitoffset::NUMERIC > (-0.17 * 60) THEN 5
        WHEN b.hospitaladmitoffset::NUMERIC >= (-4.94 * 60) AND b.hospitaladmitoffset::NUMERIC <= (-0.17 * 60) THEN 3
        WHEN b.hospitaladmitoffset >= (-24 * 60) AND b.hospitaladmitoffset::NUMERIC <= (-4.94 * 60) THEN 0
        WHEN b.hospitaladmitoffset::NUMERIC >= (-311.80 * 60) AND b.hospitaladmitoffset::NUMERIC <= (-24.0 * 60) THEN 2
        WHEN b.hospitaladmitoffset::NUMERIC < (-311.80 * 60) THEN 1
        ELSE 0
      END AS pre_icu_los_oasis,
      CASE
        WHEN b.age < 24 THEN 0
        WHEN b.age BETWEEN 24 AND 53 THEN 3
        WHEN b.age BETWEEN 54 AND 77 THEN 6
        WHEN b.age BETWEEN 78 AND 89 THEN 9
        WHEN b.age > 89 THEN 7
        ELSE 0
      END AS age_oasis,
      CASE
        WHEN g.gcs_min_0_24h IS NULL THEN 0
        WHEN g.gcs_min_0_24h < 8 THEN 10
        WHEN g.gcs_min_0_24h BETWEEN 8 AND 13 THEN 4
        WHEN g.gcs_min_0_24h = 14 THEN 3
        WHEN g.gcs_min_0_24h = 15 THEN 0
        ELSE 0
      END AS gcs_oasis,
      CASE
        WHEN v.heart_rate_min_24h < 33 THEN 4
        WHEN v.heart_rate_max_24h BETWEEN 33 AND 88 THEN 0
        WHEN v.heart_rate_max_24h BETWEEN 89 AND 106 THEN 1
        WHEN v.heart_rate_max_24h BETWEEN 107 AND 125 THEN 3
        WHEN v.heart_rate_max_24h > 125 THEN 6
        ELSE 0
      END AS heartrate_oasis,
      CASE
        WHEN v.map_min_24h < 20.65 THEN 4
        WHEN v.map_min_24h BETWEEN 20.65 AND 50.99 THEN 3
        WHEN v.map_min_24h BETWEEN 51 AND 61.32 THEN 2
        WHEN v.map_min_24h BETWEEN 61.33 AND 143.44 THEN 0
        WHEN v.map_max_24h > 143.44 THEN 3
        ELSE 0
      END AS map_oasis,
      CASE WHEN COALESCE(t.invasive_mechanical_ventilation_24h,0)=1 THEN 9 ELSE 0 END AS vent_oasis,
      e.electivesurgery_oasis
  FROM sabd_base_cohort b
  LEFT JOIN sabd_gcs_0_24h g ON b.patientunitstayid = g.patientunitstayid
  LEFT JOIN sabd_vitals_24h v ON b.patientunitstayid = v.patientunitstayid
  LEFT JOIN sabd_treatments_24h t ON b.patientunitstayid = t.patientunitstayid
  LEFT JOIN elective e ON b.patientunitstayid = e.patientunitstayid
)
SELECT
    patientunitstayid,
    pre_icu_los_oasis + age_oasis + gcs_oasis + heartrate_oasis + map_oasis + vent_oasis + electivesurgery_oasis AS oasis
FROM components;

CREATE INDEX IF NOT EXISTS idx_sabd_oasis_patientunitstayid
ON sabd_oasis(patientunitstayid);

/* =============================================================================
   10. Approximate SOFA score (first 24 hours)
   ============================================================================= */
DROP TABLE IF EXISTS sabd_sofa_approx CASCADE;
CREATE TABLE sabd_sofa_approx AS
WITH bg AS (
  SELECT
      patientunitstayid,
      MIN(CASE
            WHEN LOWER(labname) = 'fio2' AND labresult BETWEEN 20 AND 100 THEN labresult/100.0
            WHEN LOWER(labname) = 'fio2' AND labresult BETWEEN 0.2 AND 1.0 THEN labresult
            ELSE NULL
          END) AS fio2_min,
      MIN(CASE WHEN LOWER(labname) = 'pao2' AND labresult BETWEEN 15 AND 720 THEN labresult END) AS pao2_min
  FROM lab
  WHERE labresultoffset BETWEEN 0 AND 1440
    AND LOWER(labname) IN ('fio2','pao2')
  GROUP BY patientunitstayid
), pf AS (
  SELECT
      patientunitstayid,
      CASE WHEN fio2_min IS NOT NULL AND fio2_min > 0 THEN pao2_min / fio2_min ELSE NULL END AS pf_ratio
  FROM bg
), platelets AS (
  SELECT
      patientunitstayid,
      MIN(CASE WHEN labresult > 0 AND labresult < 10000 THEN labresult END) AS platelet_min
  FROM lab
  WHERE labresultoffset BETWEEN 0 AND 1440
    AND LOWER(labname) = 'platelets x 1000'
  GROUP BY patientunitstayid
), bilirubin AS (
  SELECT
      patientunitstayid,
      MAX(CASE WHEN labresult > 0 AND labresult < 150 THEN labresult END) AS bilirubin_max
  FROM lab
  WHERE labresultoffset BETWEEN 0 AND 1440
    AND LOWER(labname) = 'total bilirubin'
  GROUP BY patientunitstayid
), creat AS (
  SELECT
      patientunitstayid,
      MAX(CASE WHEN labresult > 0 AND labresult < 150 THEN labresult END) AS creatinine_max
  FROM lab
  WHERE labresultoffset BETWEEN 0 AND 1440
    AND LOWER(labname) = 'creatinine'
  GROUP BY patientunitstayid
)
SELECT
    b.patientunitstayid,
    /* Respiratory */
    CASE
      WHEN pf.pf_ratio IS NULL THEN 0
      WHEN pf.pf_ratio < 100 AND COALESCE(t.invasive_mechanical_ventilation_24h,0)=1 THEN 4
      WHEN pf.pf_ratio < 200 AND COALESCE(t.invasive_mechanical_ventilation_24h,0)=1 THEN 3
      WHEN pf.pf_ratio < 300 THEN 2
      WHEN pf.pf_ratio < 400 THEN 1
      ELSE 0
    END AS sofa_respiration,
    /* Coagulation */
    CASE
      WHEN pl.platelet_min IS NULL THEN 0
      WHEN pl.platelet_min < 20  THEN 4
      WHEN pl.platelet_min < 50  THEN 3
      WHEN pl.platelet_min < 100 THEN 2
      WHEN pl.platelet_min < 150 THEN 1
      ELSE 0
    END AS sofa_coagulation,
    /* Liver */
    CASE
      WHEN bi.bilirubin_max IS NULL THEN 0
      WHEN bi.bilirubin_max >= 12.0 THEN 4
      WHEN bi.bilirubin_max >= 6.0  THEN 3
      WHEN bi.bilirubin_max >= 2.0  THEN 2
      WHEN bi.bilirubin_max >= 1.2  THEN 1
      ELSE 0
    END AS sofa_liver,
    /* Cardiovascular (approximate) */
    CASE
      WHEN COALESCE(t.invasive_mechanical_ventilation_24h,0)=0 AND COALESCE(v.map_min_24h,0)=0 THEN 0
      WHEN COALESCE(t.invasive_mechanical_ventilation_24h,0)=1 OR COALESCE(t2.vasoactive_agents_24h,0)=1 THEN 2
      WHEN v.map_min_24h IS NOT NULL AND v.map_min_24h < 70 THEN 1
      ELSE 0
    END AS sofa_cardiovascular_approx,
    /* CNS */
    CASE
      WHEN g.gcs_min_0_24h IS NULL THEN 0
      WHEN g.gcs_min_0_24h < 6  THEN 4
      WHEN g.gcs_min_0_24h < 10 THEN 3
      WHEN g.gcs_min_0_24h < 13 THEN 2
      WHEN g.gcs_min_0_24h < 15 THEN 1
      ELSE 0
    END AS sofa_cns,
    /* Renal */
    CASE
      WHEN cr.creatinine_max IS NULL THEN 0
      WHEN cr.creatinine_max >= 5.0 THEN 4
      WHEN cr.creatinine_max >= 3.5 THEN 3
      WHEN cr.creatinine_max >= 2.0 THEN 2
      WHEN cr.creatinine_max >= 1.2 THEN 1
      ELSE 0
    END AS sofa_renal
FROM sabd_base_cohort b
LEFT JOIN pf ON b.patientunitstayid = pf.patientunitstayid
LEFT JOIN platelets pl ON b.patientunitstayid = pl.patientunitstayid
LEFT JOIN bilirubin bi ON b.patientunitstayid = bi.patientunitstayid
LEFT JOIN creat cr ON b.patientunitstayid = cr.patientunitstayid
LEFT JOIN sabd_vitals_24h v ON b.patientunitstayid = v.patientunitstayid
LEFT JOIN sabd_gcs_0_24h g ON b.patientunitstayid = g.patientunitstayid
LEFT JOIN sabd_treatments_24h t ON b.patientunitstayid = t.patientunitstayid
LEFT JOIN sabd_treatments_24h t2 ON b.patientunitstayid = t2.patientunitstayid;

/* Compute total SOFA */
DROP TABLE IF EXISTS sabd_sofa_total CASCADE;
CREATE TABLE sabd_sofa_total AS
SELECT
    patientunitstayid,
    sofa_respiration + sofa_coagulation + sofa_liver + sofa_cardiovascular_approx + sofa_cns + sofa_renal AS sofa_24h_approx
FROM sabd_sofa_approx;

CREATE INDEX IF NOT EXISTS idx_sabd_sofa_patientunitstayid
ON sabd_sofa_total(patientunitstayid);

/* =============================================================================
   11. Pre-ICU statin use
   ============================================================================= */
DROP TABLE IF EXISTS sabd_statin_exposure CASCADE;
CREATE TABLE sabd_statin_exposure AS
SELECT DISTINCT
    a.patientunitstayid,
    1 AS pre_statin
FROM admissiondrug a
WHERE LOWER(COALESCE(a.drugname, '')) ~ '(atorvastatin|simvastatin|lovastatin|pitavastatin|fluvastatin|pravastatin|rosuvastatin|lipitor|zocor|mevacor|crestor|pravachol|lescol|livalo)';

CREATE INDEX IF NOT EXISTS idx_sabd_statin_patientunitstayid
ON sabd_statin_exposure(patientunitstayid);

/* =============================================================================
   12. Final analytic cohort
   ============================================================================= */
DROP TABLE IF EXISTS sabd_persistent_cohort CASCADE;
CREATE TABLE sabd_persistent_cohort AS
SELECT
    'eICU-CRD'::TEXT AS database_source,
    b.patientunitstayid,
    b.uniquepid,
    b.hospitalid,
    b.region,
    b.unittype,
    b.age,
    b.sex_male,
    b.race,

    /* GCS */
    g.gcs_min_0_24h AS gcs_min_first_24h,
    g.gcs_max_0_24h AS gcs_max_first_24h,

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
    o.oasis,
    s.sofa_24h_approx AS sofa,

    /* Comorbidities */
    c.chronic_kidney_disease,
    c.respiratory_failure,

    /* Treatments */
    t.invasive_mechanical_ventilation_24h,
    t.dexmedetomidine_24h,
    t.opioid_24h,

    /* Pre-ICU statin use */
    COALESCE(st.pre_statin, 0) AS pre_icu_statin_use,

    /* Exclusion flags */
    ex.acute_brain_injury_or_major_neuro,
    ex.alcohol_abuse,

    /* Outcome: persistent SABD at ICU day 3 */
    CASE WHEN g48.gcs_min_48_72h IS NOT NULL AND g48.gcs_min_48_72h < 15 THEN 1
         WHEN g48.gcs_min_48_72h IS NOT NULL AND g48.gcs_min_48_72h >= 15 THEN 0
         ELSE NULL
    END::SMALLINT AS persistent_sabd_day3,
    g48.gcs_min_48_72h AS gcs_min_48_72h,
    g48.gcs_max_48_72h AS gcs_max_48_72h,
    g48.n_gcs_48_72h,

    /* Mortality */
    b.hosp_mort,
    b.icu_mort,
    CASE WHEN b.unitdischargeoffset IS NOT NULL THEN ROUND((b.unitdischargeoffset::NUMERIC / 1440.0), 4) END AS icu_los_days

FROM sabd_base_cohort b
INNER JOIN sabd_sepsis_flag sp
  ON b.patientunitstayid = sp.patientunitstayid AND sp.sepsis = 1
INNER JOIN sabd_gcs_0_24h g
  ON b.patientunitstayid = g.patientunitstayid AND g.gcs_max_0_24h < 15
LEFT JOIN sabd_gcs_48_72h g48 ON b.patientunitstayid = g48.patientunitstayid
LEFT JOIN sabd_vitals_24h v ON b.patientunitstayid = v.patientunitstayid
LEFT JOIN sabd_labs_24h l ON b.patientunitstayid = l.patientunitstayid
LEFT JOIN sabd_comorbidities c ON b.patientunitstayid = c.patientunitstayid
LEFT JOIN sabd_treatments_24h t ON b.patientunitstayid = t.patientunitstayid
LEFT JOIN sabd_statin_exposure st ON b.patientunitstayid = st.patientunitstayid
LEFT JOIN sabd_exclusion_flags ex ON b.patientunitstayid = ex.patientunitstayid
LEFT JOIN sabd_oasis o ON b.patientunitstayid = o.patientunitstayid
LEFT JOIN sabd_sofa_total s ON b.patientunitstayid = s.patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_sabd_final_patientunitstayid
ON sabd_persistent_cohort(patientunitstayid);

/* =============================================================================
   13. Quality control summaries
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
