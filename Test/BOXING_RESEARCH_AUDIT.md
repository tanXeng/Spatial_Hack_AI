# Boxing research and dataset audit

**Snapshot:** 8 August 2026
**Scope:** research used to define ShadowBox measurements, safety boundaries, coaching content, future sensors, and ML-data gates
**Product stage:** rules-based Apple Vision Pro fundamentals MVP; no evaluated Core ML model

This document corrects what the cited studies and supplied dataset catalog can support. It does not establish training efficacy, injury prevention, clinical validity, force measurement, full-body biomechanics, commercial rights, or physical-headset safety.

## Labels

- **[A] Authority:** official platform, safety, rule, or funding page.
- **[P] Primary study:** the linked paper reports the described experiment.
- **[E] Evidence:** directly stated by a source or observable in the supplied artifact.
- **[I] Inference:** a bounded product implication; not a measured result.
- **[D] Decision:** adopted, deferred, or rejected.
- **[X] Prohibited claim:** wording the current evidence cannot support.

## Executive correction

1. **[D]** The AVP-only product reports hand/device observations and conservative derivatives: hand path, comfortable reach, guard, response/recovery timing, and a headset-motion proxy. It does not report hip, foot, balance, ground reaction, impact, force, power, effective mass, or injury risk. Relative hand speed exists only as an internal diagnostic and is not surfaced.
2. **[D]** Pace is internal, unscored, undisplayed, and outside coaching and the current recommendation policy. Difficulty changes cue timing and visual/path-density guidance; it does not change fit, target size, thresholds, score weights, or safety.
3. **[D]** Current adaptive recommendations are deterministic rules over session-only aggregate evidence. No model is trained, no current user result is persisted, and “Core ML coach” remains a future evaluated gate.
4. **[D]** Headset motion is not a substitute for torso/pelvis measurement. A belt IMU can later add belt angular velocity; an iPhone camera can add visible body landmarks; pressure/force sensing is required for plantar or impact claims. These sources remain separately labelled until validation supports fusion.
5. **[D]** Device work is limited to stationary, controlled, submaximal movements. Physical bag striking, partner work, maximal-effort punches, fast footwork, and hooks/uppercuts are outside the current headset test scope.
6. **[D]** Current Defense code fails closed when headset displacement exceeds its controlled range during a cue or gap, then requires neutral plus explicit resume/fresh countdown. This is a software refusal state—not evidence that the range is biomechanically correct or that headset defense is safe.

## Source-by-source audit

### Apple movement safety

[Apple's Vision Pro safety guidance](https://support.apple.com/en-us/118519) tells users to clear obstacles and hazards, use a well-lit space, remain aware of people/pets/children, and not run or make sudden movements **[A]**. It also states that the device may not detect every object **[A]**.

**[I] Product implication:** passthrough, scene understanding, a guardian boundary, or a visually clear room cannot guarantee a strike envelope is safe. Boxing-like speed and reach amplify the consequence of a missed obstacle, headset movement, or bystander entry.

**[D] Adopt:** before any headset drill, require a clear stationary area and a positive safety acknowledgement; use mixed passthrough; keep Stop & Exit available; use slow-to-controlled, submaximal straight extensions; dissolve defensive cues before the headset; pause on tracking loss.

**[D] Reject:** maximal-effort punches, sudden attacks, live partner contact, physical bag contact, stepping/spinning drills, or a claim that the app/headset is protective equipment.

**[X]** “Safe for boxing,” “prevents collision,” “protects the user,” and “validated for full-speed punches” are prohibited without a formal product safety process and physical-device evidence. The conservative test protocol below is a risk control, not proof of safety.

### Lead jab versus rear cross

[Higher Values of Force and Acceleration in Rear Cross Than Lead Jab](https://www.mdpi.com/2076-3417/14/7/2830) studied 13 advanced male boxers performing controlled maximal straight punches with force-plate and segment-mounted IMU measurements **[P]**. The reported group means were higher for rear-cross ground reaction and several accelerations than for lead jab **[P]**.

**What it supports [I]:** stance and lead/rear identity matter; a research protocol should not pool jab and cross blindly. Reference timing/features must retain participant, stance, side, punch, and sensor placement.

**What it does not support:** a universal individual ratio, a causal rule that one segment “creates” force, an expected AVP speed target, or a diagnosis that a boxer failed to rotate. ShadowBox has neither the study's force plate nor its mounted segment IMUs **[E]**.

**[D] Adopt:** stance-aware jab/cross labels and within-user, within-hand calibration. **[D] Reject:** lab group averages as per-user scoring thresholds.

### Plantar pressure and lower-limb contribution

[Wearable Sensor-Based Analysis of Punch Acceleration and Plantar Pressure Distribution in Boxing](https://www.mdpi.com/1424-8220/26/9/2707) compared 24 collegiate boxers using glove IMUs and pressure insoles during controlled jab/cross trials **[P]**. It reported group differences and correlations between forefoot pressure and punch acceleration **[P]**.

**Critical correction:** correlation is not sensor substitution and does not establish a causal pathway. Fist acceleration cannot reconstruct plantar pressure, foot location, ground reaction, weight transfer, or balance. The study measured the variables with dedicated sensors; AVP hands do not **[E/I]**.

**[D] Adopt:** pressure insoles or a force platform are a possible future reference instrument. **[D] Defer:** an iPhone full-body view for non-scored foot-position research. **[D] Reject:** any AVP-only plantar-force, footwork-quality, weight-distribution, or lower-limb-contribution score.

### Effective mass and force transfer

[Biomechanics of Punching—The Impact of Effective Mass and Force Transfer on Strike Performance](https://www.mdpi.com/2076-3417/15/7/4008) studied 30 trained male boxers across jab, cross, lead hook, and rear hook using an AMTI force plate plus instrumented segment measurements **[P]**. In that protocol, effective mass was calculated from synchronized peak force and fist acceleration at impact **[P]**.

**Critical correction:** effective mass is a protocol/model-dependent derived quantity, not body mass and not obtainable from AVP hand velocity alone. Actual impact force also depends on contact dynamics; `F = ma` with a guessed mass does not recover it **[I]**.

**[D] Adopt:** use the paper to design a future validation experiment with instrumented contact and declared timing/filtering. **[D] Reject:** Newtons, joules, watts, “power,” “impact,” or “effective mass” from a virtual target intersection or relative hand speed.

### Elite versus junior segment sequencing

[Differences in Punching Technique Between Elite and Junior Boxers](https://www.frontiersin.org/journals/sports-and-active-living/articles/10.3389/fspor.2020.598861/full) compared 15 elite-potential and 8 junior boxers using a 17-IMU suit during standardized maximal cross, hook, and uppercut tasks **[P]**. Findings differed by punch and group; for example, velocity differences were not uniform across punch types, and reported segment contributions were not one universal chain **[P]**.

**What it supports [I]:** punch-specific and population-specific modeling; qualified review of instructional animation; caution against one “ideal” sequencing formula.

**What it does not support:** applying a full-suit model to AVP hands/device pose, scoring a universal hip-to-fist sequence, or assuming elite cohort means are safe/appropriate beginner targets.

**[D] Adopt:** sensor-source labels and punch-specific research hypotheses. **[D] Reject:** “professional biomechanics” or “elite-form score” in the AVP-only MVP.

### Dummy/load-cell force prediction

[Estimating Boxing Punch Force in a Realistic Scenario](https://commons.nmu.edu/isbs/vol42/iss1/164/) reports 2,040 punches analyzed with marker kinematics, head mass, an assumed/estimated effective mass, and a six-axis load cell in a dummy neck **[P]**. The abstract reports statistically significant prediction, not “near-perfect” accuracy **[E]**.

**Critical correction:** many punches do not necessarily mean many independent athletes; statistical significance does not establish low prediction error, external generalization, or equivalence to an AVP-only setup. ShadowBox has no marker system, physical target/load cell, or validated effective-mass input **[E/I]**.

**[D]** Use this only as a future research-method lead. **[X]** Do not cite it as validation for headset-derived force, near-perfect force prediction, or real-world contact accuracy.

## Measurement contract

| Quantity | Current evidence class | Current use | Required upgrade before a stronger claim |
|---|---|---|---|
| Left/right hand joints and tracking state | Direct ARKit observation | Tracking/quality input | Physical-device error and interruption characterization |
| Headset pose | Direct device observation | World frame and explicitly labelled head-motion proxy | Device/reference comparison; never relabel as head joint or torso |
| Fist centre, path, displacement | Derived from tracked hand joints | Aura/Board geometry | Named joint set, timestamp rules, filtering, invalid states, reference annotation |
| Relative hand speed | Derived, calibration-relative diagnostic | Internal only; not displayed, scored, coached, persisted, or used by the current recommendation policy | Reference timing study and a declared user decision before any surfaced use |
| Aura trajectory shape | Derived from a validated complete out-and-back trace | Separately labelled runtime diagnostic; session-only; excluded from coaching and overall score | Reference-path/device characterization and qualified content review before any technique claim |
| Response and guard-return time | Derived from logical cue/hand events | Drill feedback and optional next-level rules | Cue/event latency audit and censored-state reporting |
| Comfortable reach | User-performed functional calibration | Conservative target placement | Repetition spread and physical placement error on headset |
| Elbow, shoulder, torso | Shown reference or weak future estimate | Not scored | Independent body/reference sensing and validation |
| Waist/pelvis/hips/knees/feet | Unavailable AVP-only | Not reported | iPhone/full-body or dedicated sensing with common time/frame |
| Plantar pressure/ground reaction/balance | Unavailable | Not reported | Pressure insole/force platform and task-specific validation |
| Contact/force/effective mass/power | Unavailable | Not reported | Instrumented contact, synchronized acceleration, declared model, reference validation |

### Pace rule

**[D]** Presentation level may shorten/lengthen cue windows, rests, demonstration time, and Aura marker density. It must not move targets farther, reward hand speed, tighten technique thresholds, or encourage maximal motion. Board/Defense response time may support a user-visible *next presentation-level* suggestion; it is not a punch-quality score. Relative hand speed remains internal only.

## Controlled submaximal headset protocol

This is the maximum current validation envelope, not a consumer safety certification:

1. Adult participant; facilitator/spotter present; immediate verbal and in-app stop available.
2. Well-lit, dry, stationary area cleared beyond arm reach in every direction; remove people, pets, fans, cables, furniture edges, mirrors/glass hazards, and moving objects.
3. Check headset fit, comfort, visibility, app permissions, mixed passthrough, emergency exit, tracking state, and audio mute before movement.
4. Planted neutral stance only. No steps, pivots, spins, deep weaving, jumping, running, partner, physical target, or bag.
5. Guard/reach fitting begins slowly. Training uses controlled, submaximal jab/cross extensions and returns; never maximum speed or maximum effort.
6. New visual/defensive cues receive a no-score rehearsal; cues remain readable and dissolve before entering the personal/headset envelope.
7. Abort immediately for tracking loss, boundary/person entry, obstacle uncertainty, headset slip, pain, dizziness, nausea, visual discomfort, fear/startle, audio confusion, or participant request.
8. Do not resume until the area and system are rechecked; never convert an interrupted attempt into a miss or recommendation increase.
9. For a Defense safety-range pause, stop, return to calibrated neutral, and resume explicitly into a fresh countdown. Record it separately from tracking/system interruption and do not score the unsafe path.

## Supplied dataset-document audit

The supplied [`Boxing_ML_Datasets_and_Documentation.docx`](Boxing_ML_Datasets_and_Documentation.docx) is accepted as a **lead catalog**, not an approved training manifest **[D]**.

### Integrity problems

- **[E]** Some values/labels in the supplied research materials are corrupted, duplicated, or truncated. Exact numerical findings must be recovered from the original paper table, repository metadata, or deposited file—not copied from the summary.
- **[E]** Hyperlink labels in extracted prose do not preserve the URL relationship reliably; acquisition must follow the actual document relationship target and then verify the destination.
- **[I]** Counts can refer to frames, windows, clips, punches, files, or bouts rather than independent participants. Reporting them as participant `n` or model sample independence would be false.
- **[I]** Adjacent video frames and windows, augmented copies, mirrors, and derivatives can create near-duplicates. Olympic-derived clips, community forks, and repackaged annotations are not new independent data.
- **[I]** A paper license, repository code license, dataset license, source-media right, model-weight license, athlete consent, and redistribution right are separate layers.
- **[I]** Biomechanics records may share authors, cohorts, or protocols. Dataset IDs, participant IDs, session dates, and file hashes must be checked before counting studies as independent.

### Highest-value candidate records

| Candidate | Direct record | Defensible use now | Decision |
|---|---|---|---|
| Effective-mass laboratory release | [Zenodo concept](https://zenodo.org/records/14966350), [archived record](https://zenodo.org/records/14966351), [study](https://www.mdpi.com/2076-3417/15/7/4008) | Methodology and possible offline force/contact research after file, subject, and license audit | **Deferred.** Not a runtime AVP force model. Verify the formal record license and participant separation at acquisition. |
| Stance kinetics | [Zenodo 17186871](https://zenodo.org/records/17186871) | Stance/punch-specific sensor research after rights and cohort audit | **Deferred.** Controlled male laboratory data cannot set universal targets. |
| Straight-punch kinetics | [Zenodo 10729180](https://zenodo.org/records/10729180), [study](https://doi.org/10.3390/app14072830) | Reproducibility and future multimodal baseline | **Deferred.** Rights field was not established as a usable data license; article access does not license deposited files. |
| Bilateral wrist IMU | [Zenodo 14965635](https://zenodo.org/records/14965635), [paper](https://pmc.ncbi.nlm.nih.gov/articles/PMC12061147/) | Small controlled wearable-classification study | **Deferred.** No current runtime/shipped bilateral-model claim; verify data license, eight-athlete identity splits, and released-label structure. |
| Olympic Boxing video | [labelled data](https://www.kaggle.com/datasets/piotrstefaskiue/olympic-boxing-punch-classification-video-dataset), [paper](https://pmc.ncbi.nlm.nih.gov/articles/PMC11353713/), [code](https://github.com/piotr-stefanski/boxing-fight-video-analysis) | Research benchmarking under stated restrictions | **Rejected for current product training.** Broadcast/competition video and non-commercial terms do not match an unreviewed commercial pipeline. |
| BoxingWeb | [repository](https://github.com/gouba2333/BoxingWeb), [paper](https://arxiv.org/abs/2601.11492) | Event-schema inspiration | **Deferred.** No verified dataset reuse license; do not confuse the public subset with private/additional rounds. |
| BoxComm | [dataset](https://huggingface.co/datasets/gouba2333/BoxComm-Dataset), [project](https://gouba2333.github.io/BoxComm), [paper](https://arxiv.org/abs/2604.04419) | Commentary/task-schema research | **Rejected for the MVP.** Commentary generation is not the current user problem; metadata does not grant source-broadcast rights. |
| Community Roboflow/Kaggle/Hugging Face releases | [representative combat-sports set](https://universe.roboflow.com/combatsports/combatsports-merge-attempt/dataset/2), [Olympic derivative](https://huggingface.co/datasets/NealBeans/BoxingDataset) | Discovery only | **Rejected as clean ground truth.** Uploader labels do not establish underlying media rights or independence. |

### Dataset admission gate

No candidate becomes “training-ready” until all items pass:

1. immutable record/version, checksums, file inventory, schema, units, sensor placement, sampling clock, preprocessing, and missing-data rules;
2. verified rights for data, annotations, source media, code, and any published weights; commercial use and redistribution explicitly resolved;
3. participant consent/ethics scope compatible with the new use, plus privacy, deletion, and access controls;
4. participant/session/bout identifiers sufficient for leakage-free splits;
5. duplicate and lineage audit across frames, clips, augmentations, forks, and related deposits;
6. label ontology mapped to stance, side, punch, contact, task, and uncertainty; qualified boxing review where “technique” appears;
7. representative capture compared with ShadowBox's AVP inputs; laboratory or broadcast domain shift documented;
8. fixed and rules-based baselines, participant-held-out evaluation, calibration/abstention, subgroup analysis, and worst-case errors;
9. no current-user model control until shadow-mode evaluation beats the rules baseline on a predeclared outcome.

## Rules-based MVP versus future Core ML

| Current rules-based advisor | Future evaluated Core ML |
|---|---|
| Explicit thresholds over complete, session-only aggregate evidence | A versioned model trained on consented, documented data |
| Holds on tracking interruption/insufficient evidence | Must explicitly abstain on uncertainty, domain shift, and missing sensors |
| At most one adjacent presentation-level proposal | Must be compared against fixed-level and rule-based baselines |
| User must apply the recommendation | Starts in shadow mode; user control and deterministic fallback remain |
| No learning, cloud model, user embedding, or technique diagnosis | Participant-separated test, calibration, subgroup and safety results required |

**[X]** Until that gate passes, use “rules-based adaptive recommendation,” not “AI-personalized coach,” “learns your style,” or “Core ML-powered training.”

## Funding correction

The official [Singapore Sport Science and Technology Research Grant page](https://www.sportsingapore.gov.sg/our-work/high-performance-sport-institute/science-and-technology/singapore-sport-science-and-technology-research-grant/) exposes a **2017 call marked closed** **[A/E]**. Its historical eligibility, deadline, and award amount are not evidence of a currently available grant.

**[D]** Do not put SSSTRG funding, availability, or timing in the product roadmap or pitch. If funding is pursued, contact the High Performance Sport Institute for a current written route and cite that current source.

## Prohibited claims

- AVP measures pelvis/waist/hip/knee/foot/plantar pressure/ground reaction/balance.
- Headset yaw is torso yaw, or hand speed reveals lower-limb contribution.
- A correlation proves causation or allows one missing sensor to be inferred from another.
- Virtual contact measures physical impact, force, impulse, effective mass, power, damage, or protection.
- The dummy study proves near-perfect force prediction.
- Cohort means are universal targets or evidence that ShadowBox teaches elite/professional technique.
- A large number of frames/windows/punches is a large independent participant sample.
- Publicly downloadable, open-access, or MIT-licensed code makes associated media/data/weights commercially reusable.
- The current app has a trained model, a learned trajectory model, coach-validated technique grading, or a validated bilateral biomechanics pipeline. The source-wired geometric trajectory diagnostic and repeatability-gated bilateral fit do not support those claims.
- SSSTRG is currently open or available.
- Controlled submaximal test instructions prove Apple Vision Pro boxing is safe.

## Validation boundary

**[V]** This audit records the final-source boundary—27 application Swift files
and 13 test Swift files after the in-place Defense/accessibility slice. The
quiet 05:38 snapshot passed 111/111 tests and clean generic Simulator/unsigned
arm64 builds; that is software evidence, not biomechanics validation.
Bilateral two-repetition-per-hand fit, the
separate trajectory-shape diagnostic, tracking-gated Aura start, and fail-closed
Defense range/neutral-resume path are runtime-wired in source; signed
installation,
physical-headset behavior, measurement error, audio playback/latency, comfort,
and safety remain unverified. This does not replace coach content review,
institutional ethics review, rights clearance, reference-sensor validation, or a
physical Apple Vision Pro safety/comfort study.
