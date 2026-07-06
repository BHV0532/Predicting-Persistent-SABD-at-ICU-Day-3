# Predicting Persistent Sepsis-Associated Brain Dysfunction at ICU Day 3

SQL extraction scripts for cohort identification and variable extraction from two critical care databases: the eICU Collaborative Research Database (eICU-CRD) and the Medical Information Mart for Intensive Care IV (MIMIC-IV).

These scripts support the study: *"Predicting Persistent Sepsis-Associated Brain Dysfunction at ICU Day 3: Development and External Validation of an Interpretable Machine Learning Model."*

## Overview

This repository provides streamlined SQL scripts to:
1. Identify adult sepsis patients with early sepsis-associated brain dysfunction (SABD)
2. Extract the core predictors used in the final gradient boosting machine (GBM) model
3. Define the outcome: persistent SABD at ICU day 3 (GCS < 15 during hours 48-72)

## Database Access

Both databases require credentialed access through PhysioNet:

- **eICU-CRD v2.0**: [https://eicu-crd.mit.edu/](https://eicu-crd.mit.edu/)
- **MIMIC-IV v2.2**: [https://mimic.mit.edu/](https://mimic.mit.edu/)

Users must complete the CITI training course and sign the data use agreement before accessing the data.

## Directory Structure

```
sabd-persistent-prediction/
├── README.md
├── eicu/
│   └── cohort_extraction.sql    # eICU-CRD extraction script
└── mimic/
    └── cohort_extraction.sql    # MIMIC-IV extraction script
```

## Requirements

- PostgreSQL (both databases are hosted on PostgreSQL)
- eICU-CRD v2.0 installed in the `public` schema
- MIMIC-IV v2.2 with derived concepts installed (`mimiciv_derived` schema)
  - Required derived tables: `sepsis3`, `first_day_sofa`, `oasis`, `charlson`, `ventilation`

## Cohort Definition

| Criterion | Definition |
|-----------|-----------|
| Age | >= 18 years |
| ICU stay | First ICU admission |
| Sepsis | eICU: APACHE admission diagnosis or diagnosis table; MIMIC: Sepsis-3 |
| Early SABD | GCS < 15 within first 24 hours of ICU admission |
| Exclusions | Acute brain injury, major neurologic disease, alcohol abuse (flagged, not excluded from main cohort) |

## Outcome

**Persistent SABD at ICU day 3**: Peak GCS < 15 during the 48-72 hour window after ICU admission.

## Predictors

All predictors are extracted from the first 24 hours of ICU admission:

| Predictor | Source |
|-----------|--------|
| Peak GCS (0-24h) | Nurse charting / chartevents |
| OASIS score | Calculated from vital signs, GCS, ventilation |
| SOFA score | eICU: approximate; MIMIC: derived table |
| Age | Patient demographics |
| Heart rate | Vital signs |
| Mean arterial pressure | Vital signs |
| Blood lactate | Laboratory |
| Serum creatinine | Laboratory |
| Serum sodium | Laboratory |
| Serum glucose | Laboratory |
| Invasive mechanical ventilation | Treatment / ventilation table |
| Dexmedetomidine use | Medication / inputevents |
| Opioid use | Medication / inputevents |
| Chronic kidney disease | Comorbidities (pasthistory / ICD codes) |
| Respiratory failure | Comorbidities (diagnosis table / ICD codes) |
| Pre-ICU statin use | Admission drug / prescriptions |

## Usage

### eICU-CRD

```sql
-- Set the search path
SET search_path TO public;

-- Run the extraction script
\i eicu/cohort_extraction.sql

-- Query the final cohort
SELECT COUNT(*) FROM sabd_persistent_cohort;
SELECT persistent_sabd_day3, COUNT(*) FROM sabd_persistent_cohort GROUP BY persistent_sabd_day3;
```

### MIMIC-IV

```sql
-- Set the search path
SET search_path TO mimiciv_derived, mimiciv_icu, mimiciv_hosp, public;

-- Run the extraction script
\i mimic/cohort_extraction.sql

-- Query the final cohort
SELECT COUNT(*) FROM sabd_persistent_cohort;
SELECT persistent_sabd_day3, COUNT(*) FROM sabd_persistent_cohort GROUP BY persistent_sabd_day3;
```

## Output Tables

Both scripts produce a final table named `sabd_persistent_cohort` with the following key columns:

| Column | Description |
|--------|-------------|
| `database_source` | "eICU-CRD" or "MIMIC-IV" |
| `patientunitstayid` / `stay_id` | Unique ICU stay identifier |
| `age` | Patient age in years |
| `sex_male` | 1 = male, 0 = female |
| `gcs_min_first_24h` | Minimum GCS in first 24 hours |
| `gcs_max_first_24h` | Maximum (peak) GCS in first 24 hours |
| `oasis` | OASIS severity score |
| `sofa` | SOFA severity score |
| `heart_rate_min_24h` | Minimum heart rate |
| `heart_rate_max_24h` | Maximum heart rate |
| `map_min_24h` | Minimum mean arterial pressure |
| `map_max_24h` | Maximum mean arterial pressure |
| `lactate_first_24h` | First blood lactate value |
| `creatinine_first_24h` | First serum creatinine value |
| `sodium_first_24h` | First serum sodium value |
| `glucose_first_24h` | First serum glucose value |
| `invasive_mechanical_ventilation_24h` | 1 = received IMV |
| `dexmedetomidine_24h` | 1 = received dexmedetomidine |
| `opioid_24h` | 1 = received opioids |
| `chronic_kidney_disease` | 1 = comorbidity present |
| `respiratory_failure` | 1 = comorbidity present |
| `pre_icu_statin_use` | 1 = pre-ICU statin use |
| `persistent_sabd_day3` | **Outcome**: 1 = persistent SABD, 0 = resolved |
| `hosp_mort` | Hospital mortality indicator |

## Limitations

1. **eICU SOFA**: The cardiovascular component is approximate due to lack of harmonized vasopressor dosing in the standard eICU tables.
2. **GCS availability**: Not all patients have GCS recorded during the 48-72 hour window; these cases will have `NULL` for the outcome.
3. **Pre-ICU statin use**: eICU `admissionDrug` is sparsely populated; pre-ICU statin exposure may be under-recorded.
4. **Delirium assessment**: eICU uses nurse-charted delirium records, not CAM-ICU. MIMIC uses CAM-ICU features from chartevents.
5. **Single-center validation**: MIMIC-IV is from a single US hospital center; generalizability to other healthcare systems requires further testing.

## Citation

If you use these scripts in your research, please cite:

> [Author names]. Predicting Persistent Sepsis-Associated Brain Dysfunction at ICU Day 3: Development and External Validation of an Interpretable Machine Learning Model. [Journal name, year]. DOI: [to be added].

## License

These scripts are provided for research purposes. Users must comply with the PhysioNet Credentialed Health Data License for both eICU-CRD and MIMIC-IV.

## Contact

For questions or issues, please open a GitHub issue or contact the corresponding author.
