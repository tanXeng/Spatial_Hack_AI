# ShadowBox research and evidence-led roadmap

**Research snapshot:** 8 August 2026
**Scope:** Apple Vision Pro boxing fundamentals MVP, companion-device options, and a staged path to evaluated adaptive training
**Product contract:** fit the drill to the boxer, demonstrate an observable movement, let the boxer practise it, and explain only what the available sensors actually measured.

This document turns platform evidence, public product claims, user feedback, the current source tree, and relevant measurement research into build decisions. It does not claim market size, clinical benefit, injury prevention, professional coaching equivalence, or training efficacy.

Supporting provenance audits: [`REFERENCE_REPOSITORY_AUDIT.md`](REFERENCE_REPOSITORY_AUDIT.md) separates inspiration from licensed/reusable material, and [`BOXING_RESEARCH_AUDIT.md`](BOXING_RESEARCH_AUDIT.md) records study, dataset, safety, and claim corrections.

## Evidence and status legend

- **[A] Platform authority:** Apple documentation or Human Interface Guidelines. Use for capability and platform-boundary claims.
- **[R] Research:** peer-reviewed or indexed measurement research. Use as design evidence, not proof that ShadowBox has the same validity.
- **[P] Product evidence:** a first-party product or App Store page. It proves a public feature or rating at the snapshot date, not efficacy.
- **[U] User signal:** an individual App Store review or public discussion. It is qualitative demand or pain evidence, not representative prevalence.
- **[B] Build evidence:** behavior visible in the local source tree. It is not physical-device validation.
- **[S] Source provenance:** a pinned external repository/branch or supplied artifact. It supports comparison and provenance, not reuse rights or product validation.
- **[H] Hypothesis:** a proposition that requires interviews, usability work, device trials, or a controlled evaluation.

“As built” below means present in the reconciled final-source snapshot. That
snapshot contains **27 application Swift files and 13 test Swift files**; the
in-place Defense/accessibility slice changed no file counts. At the quiet 05:38
snapshot, 111/111 tests passed and generic Simulator/unsigned arm64 visionOS
builds succeeded, all with zero reported errors or warnings. Each xcresult's
analyzer-warning field is 0; a standalone Xcode Analyze action was not run.
Signed install and physical-headset/audio/accessibility acceptance remain open.
Software evidence does **not** mean signed, installed,
safe, accurate, comfortable, or effective on a physical Apple Vision Pro.

### Reference-repository checkpoint

The default [`Spatial_Hack_AI` main snapshot is `b570f2e31b638e97fe59110f9909bcd20228bbc7`](https://github.com/tanXeng/Spatial_Hack_AI/tree/b570f2e31b638e97fe59110f9909bcd20228bbc7). The much larger [`feat/aura-punch` commit `037e0ae0f1854638ace79b72a2a2996d5475548a`](https://github.com/tanXeng/Spatial_Hack_AI/tree/037e0ae0f1854638ace79b72a2a2996d5475548a) is an **unmerged direct child** (`+3,148/-57`, 15 files); [`aurapunch-ian` at `f500724f1550a7b58a9531fd6ab3157e82954174`](https://github.com/tanXeng/Spatial_Hack_AI/tree/f500724f1550a7b58a9531fd6ab3157e82954174) is an orphan line **[S]**. [Main-to-feature comparison](https://github.com/tanXeng/Spatial_Hack_AI/compare/b570f2e31b638e97fe59110f9909bcd20228bbc7...037e0ae0f1854638ace79b72a2a2996d5475548a)

The repository has no verified root license/SPDX or asset-attribution register. ShadowBox therefore adopts only independently implemented concepts; it does not copy source or assets. The branch's procedural guide, constrained-DTW, deterministic-feedback, and JSON-seam ideas are useful, while head-yaw-as-torso, inferred elbow/torso scoring, unreviewed hooks/uppercuts, stale-pose polling, embedded network keys, and unattributed assets are rejected or deferred. See the audit for the exact decisions.

## Product decision

ShadowBox should be a **controller-free spatial fundamentals lab**, not a simulated fight and not a software-only biomechanics laboratory.

The coherent loop is:

1. **Fit:** establish stance, manual measurement consistency, guard, comfortable reach, and a stable forward frame.
2. **Learn:** show a slow, legible reference motion and state which body segments are instructional rather than observed.
3. **React:** vary cues without moving targets outside the fitted safe envelope.
4. **Reflect:** report a small set of traceable metrics, tracking quality, and the reason for any next-level suggestion.

The competitive wedge is not “AI sparring” alone. [Boxing Trainer: Punch Master](https://apps.apple.com/us/app/boxing-trainer-punch-master/id6743240378) already advertises an AI sparring partner, defensive targets, spatial audio, Apple Watch workout data, progression, and a physics bag **[P]**. ShadowBox can be more credible by making calibration visibly affect the lesson, separating demonstration from assessment, pausing when evidence is weak, and refusing to convert a headset proxy into a fabricated hip or force number.

## What consumers are asking for

Public feedback is directional, not a substitute for ShadowBox interviews.

| Signal | Evidence | Build consequence |
|---|---|---|
| People can return frequently when spatial fitness is fun. | A Beat Punch reviewer reported daily one-hour use; the US App Store page showed 4.6/5 from 275 ratings at the snapshot **[U/P]**. [Source](https://apps.apple.com/us/app/beat-punch-fun-fitness/id6478818247?platform=vision&see-all=reviews) | Optimize a short repeatable loop and fast restart before building a large content library. Track repeat use in ShadowBox rather than borrowing a competitor’s traction. |
| Difficulty and preferences must respect the user. | The same review asked for a preferred difficulty, playlists, streaks, and Health integration because the app reset to easy and activity estimates disagreed with Apple Watch **[U]**. [Source](https://apps.apple.com/us/app/beat-punch-fun-fitness/id6478818247?platform=vision&see-all=reviews) | Make the level explicit, lock it during a set, explain recommendations, persist explicit UI preferences locally and reversibly, keep evidence/results session-only, and never invent calories. |
| Adjustable pace, southpaw support, voice, and custom combinations have durable value. | Precision Boxing Coach users highlighted many difficulty settings, travel-friendly solo practice, and southpaw support **[U]**; Callout advertises pace, coach voice, Health, southpaw, and custom combination controls **[P]**. [Precision](https://apps.apple.com/us/app/precision-boxing-coach-pro/id702519995?platform=iphone&see-all=reviews), [Callout](https://apps.apple.com/us/app/callout-the-boxing-app/id1473350118) | Treat stance, cadence, cue vocabulary, and voice as first-class settings. Do not encode orthodox-only combinations. |
| Fitness spectacle can teach implausible mechanics. | Beat Punch reviews objected to simultaneous double punches, backhand-like actions, and combinations that did not resemble jab/cross fundamentals **[U]**. [Source](https://apps.apple.com/us/app/beat-punch-fun-fitness/id6478818247?platform=vision&see-all=reviews) | A qualified boxing coach must sign off each cue, animation, expected hand, recovery, and defensive response before it becomes scored content. |
| Tracking failures become frustration very quickly. | Hand Physics Lab reviews praised novelty but described failed hand tracking, finger-driven menus, repetitive levels, and reset friction **[U]**. [Source](https://apps.apple.com/us/app/hand-physics-lab/id6752609486?platform=vision&see-all=reviews) | Pause scoring on stale/lost tracking; never grade missing data; keep setup and recovery on standard gaze-and-pinch controls; make resume one action. |
| Users need to know why a hit did or did not count. | VR boxing discussions report unclear hit registration and robotic opponents; users also distinguish cardio/reflex practice from real sparring **[U]**. [AI difficulty](https://www.reddit.com/r/ThrillOfTheFight/comments/1p6mbbg/the_ai_is_hard_to_beat/), [transfer limits](https://www.reddit.com/r/ThrillOfTheFight/comments/1pnpu2a/does_vr_boxing_skill_reflect_reality/) | Show target, expected hand, timing window, path/contact result, and tracking state. Position the experience as enhanced shadowboxing, not combat readiness. |
| A harder opponent is not automatically a better opponent. | Thrill of the Fight feedback criticizes predictable templates, superhuman reactions, identical styles, and difficulty implemented mostly as stat changes **[U]**. [Predictability](https://www.reddit.com/r/ThrillOfTheFight/comments/1v6w92e/for_brothers_with_boxing_experience_is_the_ai_in/), [personality and variation](https://www.reddit.com/r/ThrillOfTheFight/comments/1qq3k7c/not_feeling_the_ai_opponents_sorry/) | Difficulty must change readable decision pressure, not remove reaction time or create impossible defense. Vary tactics within bounded authored states and disclose what changed. |
| Hardware can add truth but also setup, price, and trust costs. | A FightCamp user described useful at-home workouts but punch-registration problems and expensive trackers plus subscription **[U]**. [Source](https://www.reddit.com/r/MuayThai/comments/1ra9w1q/fightcamp_or_body_action_reviews/) | Keep sensors optional, show connection and quality status, degrade gracefully, and prove an accessory adds a decision-relevant metric before requiring it. |

### What this evidence does not prove

- App Store ratings and selected reviews do not establish total addressable market, retention, willingness to pay, or training benefit.
- Competitor feature lists do not prove their accuracy.
- Enthusiastic VR-fitness reports do not establish transfer to boxing skill.
- Sensor validation in another device or population does not validate ShadowBox.

## Apple Vision Pro capability boundary

Apple’s [`HandTrackingProvider`](https://developer.apple.com/documentation/arkit/handtrackingprovider/) supplies tracked hands and hand joints, while [`WorldTrackingProvider` and `DeviceAnchor`](https://developer.apple.com/documentation/arkit/deviceanchor) supply the headset’s pose **[A]**. ARKit data is permission-gated and available in a Full Space; an app must handle denial and later loss of access **[A]**. [Authorization guidance](https://developer.apple.com/documentation/visionos/setting-up-access-to-arkit-data)

Standard consumer visionOS distribution does not provide a general forward-camera body-analysis feed. Apple documents main-camera access as an enterprise entitlement for eligible business apps **[A]**. [Main-camera boundary](https://developer.apple.com/documentation/visionos/accessing-the-main-camera)

Apple also tells Vision Pro users to clear hazards, use a well-lit space, and **not run or make sudden movements** **[A]**. [Vision Pro safety guidance](https://support.apple.com/en-us/118519) The current headset scope is therefore stationary, controlled, submaximal jab/cross extension and planted defense rehearsal only—not full-speed/maximal punches, hooks/uppercuts, physical-bag contact, partner work, or footwork. This conservative boundary reduces risk; it does not establish that boxing in Vision Pro is safe.

### Measurement taxonomy

| Quantity | AVP-only status | Correct product label |
|---|---|---|
| Left/right hand joint positions and tracking state | **Direct ARKit observation** | “Tracked hand joints” |
| Vision Pro position and orientation | **Direct ARKit observation** | “Headset pose” |
| Fist center | **Derived** from several tracked knuckles | “Estimated fist centre” |
| Fist path and displacement | **Derived** from timestamped fist estimates | “Hand path”; never impact power |
| Execution pace / relative hand speed | **Derived internal diagnostic** from timestamped fist estimates | Not displayed, scored, coached, or used by the current recommendation policy; never impact power |
| Aura trajectory shape | **Derived diagnostic** from a complete validated out-and-back trace | “Trajectory shape · diagnostic”; session-only and separate from coaching/overall score |
| Guard position and comfortable reach | **Derived from a user-performed calibration** | “Session-calibrated guard/reach” |
| Cue response and guard recovery time | **Derived** from logical cue time and observed hand events | “Observed response/recovery time” with tracking interruptions shown |
| Head translation and orientation | **Proxy** from the headset | “Headset-motion proxy”; not neck, balance, or defense quality |
| Shoulder centre/axis and upper-torso yaw | **Possible weak estimate**, not a native joint | “Estimated upper-body rotation contribution,” confidence-gated and not yet built |
| Pelvis, waist, hips, knees, ankles, feet, ground reaction, plantar pressure, balance | **Unavailable natively** | Do not report |
| Elbow and shoulder joint angles | **Unavailable as validated body joints in the current baseline** | The coach may *show* reference angles but the app must not claim to have observed them |
| Bag contact, impact force, effective mass, punch power | **Unavailable** without instrumented contact; the cited effective-mass protocol required synchronized impact force and fist acceleration | Do not report |
| Consumer-app camera body pose from Vision Pro passthrough | **Unavailable under the normal consumer entitlement model** | Use an explicit iPhone/iPad companion if body video is required |

Apple’s hand skeleton includes wrist/forearm-related hand joints, but that is not a license to relabel them as a validated shoulder, elbow, torso, or full-body model. Every derived metric needs a named input set, a confidence rule, an invalid state, and physical-device error characterization.

Controlled studies can guide an experiment without filling missing sensors. A [lead-jab/rear-cross force-plate and IMU study](https://www.mdpi.com/2076-3417/14/7/2830) supports keeping stance/hand labels, not imposing its group means as individual targets **[R]**. A [glove-IMU and pressure-insole study](https://www.mdpi.com/1424-8220/26/9/2707) found associations between acceleration and forefoot pressure; correlation does not let AVP infer plantar force or causation **[R]**. An [effective-mass study](https://www.mdpi.com/2076-3417/15/7/4008) used force/contact and acceleration instrumentation; hand velocity alone cannot produce effective mass, force, or power **[R]**. Detailed corrections and dataset gates are in the boxing audit.

## Feature-by-feature blueprint

### 1. Anthropometry

**User job:** “Place the lesson and targets where my controlled range actually is, and tell me if my setup is questionable.”

**As built [B]**

- Metric/imperial height, arm span, left/right arm length, shoulder width, stance, and dominant hand are validated and stored as local scalar profile data.
- The UI includes a repeat-measurement protocol and transparent internal-consistency checks: arm-span closure, left/right difference, broad proportion bands, a conservative reach, and a heuristic uncertainty allowance.
- The working source wires a live two-hand guard plus two controlled straight-reach repetitions per hand; only the minimum accepted left/right scalar can be added to the profile, while per-hand repetitions and world coordinates remain session-only. The final aggregate software verification passed; physical-headset runtime acceptance remains pending.
- The UI states that manual measurements do not improve ARKit tracking accuracy.

The quality panel catches inconsistent entry; it is not a clinical assessment or a statistical confidence interval. Anthropometric quality-assurance literature supports standardized landmarks and repeated measurements rather than one supposedly precise entry **[R]**. [Quality-assurance review](https://pmc.ncbi.nlm.nih.gov/articles/PMC4799648/)

**Next AVP-only slice**

1. Capture three guarded reach repetitions per side, reject stale/low-joint-count samples, show the spread, and use the median of accepted repetitions.
2. Store measurement provenance separately: manual, live AVP, or companion-camera. Never silently overwrite one source with another.
3. Create a boxer-relative coordinate frame from headset heading plus both hands at neutral guard. Recheck it before every set and after recentering; stop using fixed world X/Z assumptions.
4. Show a “fit preview” before immersion: expected target distance, board width, and reachable envelope. Let the user reduce reach for comfort; never let difficulty extend it.
5. Reuse an accepted calibration across Fit → Aura → Board within one uninterrupted immersive session, while exposing a visible Recalibrate action and invalidating on tracking reset or large drift.
6. Keep setup on standard gaze-and-pinch controls. Apple warns that sustained direct gestures and repeated raised-arm interaction can fatigue users **[A]**. [Gesture guidance](https://developer.apple.com/design/human-interface-guidelines/gestures)

**Companion-camera option**

An iPhone or iPad can run Apple Vision body-pose requests. Apple documents 17 3D body points, including shoulders, hips, knees, ankles, wrists, and elbows; depth improves the estimate, and measured body height has additional LiDAR/capture conditions **[A]**. [3D body pose](https://developer.apple.com/documentation/vision/identifying-3d-human-body-poses-in-images)

Use this only as an explicit guided scan:

- show whole-body framing and per-joint confidence;
- capture a calibration reference with a known physical size;
- take multiple neutral frames, reject occlusion, and retain a source/quality record;
- transmit landmarks or summary measurements by default, not raw video;
- compare camera reach to live comfortable reach and ask the user to resolve material disagreement;
- never represent Vision’s output as medical-grade or automatically more accurate than a careful manual/live capture.

A waist IMU does not improve arm-length measurement. It belongs to rotation analysis, not Anthropometry.

**Success gates**

- ≥95% guided-calibration completion in supervised target-user trials.
- Median time from entering Fit to accepted calibration below 90 seconds after first use.
- Test–retest comfortable-reach spread and target-placement error reported in centimetres on a physical headset; thresholds set only after pilot data.
- Zero cases in which low tracking confidence produces a valid-looking calibration.

### 2. Aura Punch

**User job:** “Show me one movement clearly, let me reproduce it, and identify the observable part that changed.”

**As built [B]**

- Jab/cross selection, an original locally authored procedural ghost glove with cuff, path markers, three controlled repetitions, and deterministic path, extension, other-hand guard, and guard-return feedback. The overall score is path 45%, extension 30%, and other-hand guard 25%.
- A separately labelled **Trajectory shape · diagnostic** is runtime-wired. It validates a complete out-and-back trace, translates by captured guard, normalizes by reach, resamples at equal cumulative arc length, applies constrained comparison, and fails closed. It appears only when every repetition is valid; it is session-only and excluded from coaching and the overall score.
- Five presentation levels alter demonstration time and path-marker density; geometry, thresholds, score weights, and safety remain fixed. Execution pace remains internal, unscored, undisplayed, and outside the recommendation policy.
- Aura start is refused unless both hands are currently tracked; its start and resume controls expose that unavailable state rather than beginning with missing evidence.
- After the three Aura repetitions, an in-immersion **Continue to Punch Board** action starts the Board with the same live calibration and selected level. Calibration still expires when the immersive session closes.
- Hooks, uppercuts, elbow/shoulder/torso/hip/footwork scoring, force, and professional technique validation are absent.

**Next AVP-only slice**

1. Retain the original procedural ghost glove as the low-risk guide and evaluate a **separately licensed/authored custom rigged coach model** alongside it. RealityKit supports skeletal poses, character control, and inverse kinematics **[A]**. [Character animation APIs](https://developer.apple.com/documentation/realitykit/game-development-character-skeletons)
2. Offer front, mirrored, and 30-degree side demonstrations, stance-aware jab/cross, pause/scrub, and one concise cue at a time.
3. Render shoulder/elbow/torso motion as **reference animation only**. Use a separate visual treatment and label it “shown, not tracked.” Score only hand evidence until another sensor observes those segments.
4. Physically verify the current spatial cue/result audio and in-space mute first. Add independent voice/earcon controls only when a voice channel genuinely exists; keep instruction quiet during the repetition so it does not mask breathing or tracking feedback.
5. Add a “why this score” breakdown using path deviation, extension, non-punch-hand guard, return, and tracking quality. Do not collapse these into an unexplained technique grade.
6. Have a qualified coach approve each animation, cue phrase, stance mapping, and failure correction before shipping it as instruction.

**Success gates**

- Users can identify the expected hand, direction, and return point after one demonstration.
- Blinded coach review shows that the authored reference represents the intended fundamental; this validates content, not automated scoring.
- Path and guard metrics improve across a short fixed lesson in a pilot, with a fixed-difficulty control before making a learning claim.
- Tracking loss always pauses or clears a partial repetition.

### 3. Reactive Punch Board

**User job:** “Give me a clear target at the right reach, count only the intended punch, and tell me why an attempt failed.”

**As built [B]**

- Six calibration-fitted pads, one logical cue at a time, jab/cross labeling in addition to colour, swept-segment contact geometry, wrong-hand/miss/timeout handling, response time, and guard-return reporting. Execution pace remains internal and is not shown or rewarded.
- Difficulty changes cue and feedback timing only. Target radius, reach, detector thresholds, scoring, and safety do not become stricter.

**Next AVP-only slice**

1. Anchor the board to the boxer-relative forward frame and run a brief drift check before the countdown.
2. Add spatial cue audio and a redundant shape/pulse label; the cue’s logical time remains scoring truth even if a visual frame is late.
3. Build coach-approved sets: alternating straights, repeat lead/rear, call-and-response, accuracy-first, and guard-return-first. Do not add strange combinations merely for novelty.
4. Show a compact attempt ledger: expected punch, observed hand, response, contact/miss reason, guard return, and tracking status.
5. Separate **presentation pace** from future **complexity**. The current slider changes cue timing and guidance while score weights remain fixed; measured execution pace remains an internal diagnostic, not UI, coaching, scoring, or recommendation evidence.
6. Keep the currently persisted preferred level local and reversible; add an explicit Reset to Balanced and explain that attempt evidence/results are not retained.

**Success gates**

- Physical-device video adjudication establishes false-hit and false-miss rates by level and hand.
- Cue-to-audio and cue-to-visual latency are measured; neither can alter the underlying score.
- Wrong-hand, timeout, and tracking-pause explanations are correctly understood in usability testing.
- No target is placed beyond the user-confirmed comfortable envelope.

### 4. Defense and object dodging

**User job:** “Practise recognizing and moving away from a readable threat without believing the headset measured footwork or real defensive competence.”

**As built [B]**

- Six-cue planted-feet slip/duck drills use Vision Pro position as a head-motion proxy.
- Excessive displacement during either an active cue or the inter-cue gap cancels evidence and pauses. Resume is refused away from calibrated neutral and requires an explicit user action followed by a fresh countdown/cue; the unsafe return path cannot score.
- Results distinguish tracking/system interruptions from safety-range pauses. Rendered and spatial-audio cues use the same calibrated user-relative horizontal basis.
- The experience states that feet, hips, knees, balance, and professional dodge technique are not scored.
- Cues are visual prompts, not physical punches, and the boxer is told not to step, spin, or move backward.

**Next AVP-only slice**

1. Use a coach/avatar glove or soft object with a clearly telegraphed lane, then dissolve it before the headset. Never simulate collision or claim protection.
2. Physically characterize the current neutral zone, displacement ceiling, return radius, pause/resume behavior, and cue basis against synchronized reference video. Tune only from declared comfort/error criteria; source guards are not safety validation.
3. Add orientation only as a separate headset-orientation observation; do not translate it into cervical, torso, or hip mechanics.
4. Let difficulty alter telegraph duration, inter-cue rest, sequence length, and distractor probability inside tested comfort limits. It must not create superhuman attacks.
5. Alternate slip and duck patterns only after isolated movements are understood. Add a no-score rehearsal before every new pattern.
6. Keep mixed passthrough visible. Apple recommends choosing immersion for the movement required and avoiding excessive movement beyond the Full Space boundary **[A]**. [Immersive-experience guidance](https://developer.apple.com/design/human-interface-guidelines/immersive-experiences)

**Footwork boundary**

Headset translation is not foot position. Apple Vision Pro alone cannot establish stance width, steps, pivots, ankle/knee angles, weight distribution, or balance. A full-body iPhone camera view is the first practical optional layer; it must show joint confidence and fail closed when feet leave frame. Even then, it does not measure ground reaction forces.

**Success gates**

- No cue requires stepping in the AVP-only mode.
- No object reaches the headset or encourages contact.
- Head-proxy false positives/negatives are characterized against manually annotated device video and headset logs.
- Participants report the cue as readable and non-startling; adverse symptoms and boundary interruptions are recorded.

### 5. Physical bag

**User job:** “Place useful targets on the bag I already own without trusting an overlay that has lost alignment.”

**As built [B]**

- A saved bag name/type/size/layout and a stationary non-contact visual proxy.
- No scan, shared coordinate alignment, physical-bag detection, bag motion, contact, impact, force, or scoring.
- The current experience explicitly says not to strike a physical bag while wearing Vision Pro.

**Safe staged path**

1. **Alignment preview:** place a high-contrast rigid reference marker on the bag mount or floor, not on a deforming strike surface. visionOS image anchors expose tracked state, pose, and estimated scale **[A]**. [Image-anchor reference](https://developer.apple.com/documentation/arkit/imageanchor/referenceimage)
2. **Confidence contract:** show Tracking / Degraded / Lost; extinguish targets immediately on degraded alignment; require a user-confirmed recheck after movement.
3. **Companion scan:** use iPhone/iPad to estimate bag bounds and stream only the alignment transform/quality where possible. A common visible marker establishes the camera-to-AVP frame.
4. **Motion truth:** if the bag moves, add a rigid mounted IMU or tracked accessory and validate latency, drift, occlusion, and transform updates. A static world anchor is not a moving-bag tracker.
5. **Contact truth:** use an instrumented bag, pressure/impact sensor, or externally validated contact event. Hand-to-overlay intersection is not physical impact.
6. **Supervised safety gate:** do not enable physical striking in the product merely because alignment code compiles. Require device testing, bag-swing envelope analysis, headset retention/comfort evaluation, emergency stop, and an explicit reviewed safety decision.

Until those gates pass, the bag remains a non-contact preview. The fastest credible near-term bag value may be an iPhone/iPad companion workout while the user is **not** wearing Vision Pro.

### 6. Difficulty and the Adaptive Coach

**User job:** “Let me choose the challenge, then suggest one explainable next step from clean evidence without taking control away.”

**As built [B]**

- A five-position presentation-level preference—Guided, Steady, Balanced, Sharp, Peak—is stored locally and locked while the immersive space is active. Per-set evidence, recommendations, and results remain session-only.
- Level changes Aura demonstration duration/path density and Board/Defense cue/rest presentation timing.
- Reach, target size, motion thresholds, score weights, and safety stay fixed.
- An opt-in, deterministic `TrainingIntensityAdvisor` evaluates aggregate complete-set evidence. It holds after tracking interruption or insufficient evidence, proposes at most one adjacent level, explains the reason, and requires the user to apply it.
- This is an **explainable rules-based adaptive MVP**. It is not Core ML, does not learn from the boxer, and must not be marketed as a trained AI model.

This design directly addresses the feedback that preferences should not reset and that “harder AI” should not mean unreadable or superhuman behavior. Difficulty, recommendation opt-in, and sound are explicit local preferences; aggregate evidence, recommendation instances, attempt results, and motion traces remain memory-only. Applying a recommendation changes the local preferred level only after the user acts.

**Next rule-based slice**

- Add a tracking-quality eligibility flag and show which aggregate fields were used.
- Add fatigue-aware *hold* logic only after a validated signal exists; lower hand speed alone is not enough to diagnose fatigue.
- Apply a cooldown so recommendations cannot oscillate every set.
- Split future difficulty into visible dimensions—pace, combo complexity, assistance, and opponent initiative—while retaining one beginner-friendly master slider.
- Let advanced users expand those dimensions, save a preset, and reset to Balanced.
- Never change difficulty mid-set without an explicit user action and safe transition.

**Future evaluated Core ML—not a rename of the rules**

Core ML becomes justified only if a learned model outperforms the rules on a defined user outcome. Required sequence:

1. Define the prediction target: for example, the next level most likely to produce controlled completion within a target challenge band. Do not train on an undefined “boxing quality” label.
2. Obtain explicit consent and a data specification. Prefer aggregate/feature data; avoid raw spatial traces unless necessary and separately consented.
3. Establish coach/user labels and inter-rater agreement where technique labels are used.
4. Split train/validation/test by participant and session to prevent the same boxer leaking across sets.
5. Compare against the fixed-level and current rule-based baselines.
6. Report calibration, subgroup performance, abstention, tracking-loss behavior, and worst-case errors—not accuracy alone.
7. Run the model in shadow mode first. It may propose but not control a session.
8. Version the model and feature schema, expose the reason category, preserve a deterministic fallback, and support deletion/export of user data where applicable.

Until those steps are complete, use “adaptive recommendation” rather than “AI coach.”

**Success gates**

- Recommendation acceptance rate, reversal rate, and level oscillation are measured.
- Accepted recommendations keep the next set in a predeclared challenge band without reducing control/safety metrics.
- Tracking-interrupted sets never trigger an increase.
- A learned model must beat the rule baseline on held-out users before it can influence the product.

### 7. 3D coach and sparring partner

**Terminology boundary**

Apple spatial Personas represent real SharePlay participants who choose to appear using their Persona; the system arranges them in a shared activity **[A]**. [Spatial Persona support](https://developer.apple.com/documentation/groupactivities/adding-spatial-persona-support-to-an-activity) A system Persona is therefore not the correct technology or name for a developer-controlled AI opponent.

Use these distinct product concepts:

- **Custom 3D coach:** an authored RealityKit character that demonstrates, calls cues, holds virtual pads, and explains results.
- **Custom sparring avatar:** an authored non-player character driven by a bounded state machine.
- **Remote human coach:** a later SharePlay participant who may appear as a spatial Persona.

**As built [B]**

- No rigged 3D character, opponent state machine, conversational model, pad-holder, or remote coach.
- Aura’s original procedural ghost glove/path is the current demonstrator.

**MVP coach interaction**

1. The character stands at the calibrated target distance and never invades the personal safety envelope.
2. Standard gaze-and-pinch controls select lesson, stance, side, speed, pause, replay, and stop. Training hand motion is reserved for the drill, avoiding ambiguous finger menus.
3. The coach uses authored animation states: idle, demonstrate, ready, cue, acknowledge, correct-one-thing, recover, pause-on-tracking-loss.
4. Spoken feedback is short and paired with text/visual state. The user can independently mute voice, earcons, and ambience.
5. The coach corrects only observable components. Example: “Return your right hand to the captured guard,” not “rotate your hip more” in AVP-only mode.

**MVP sparring interaction**

- Start as a **defensive pattern partner**, not a fight simulator: single telegraphed jab/cross lanes and bounded two-action patterns.
- Difficulty changes telegraph time, recovery, initiative, and sequence complexity within tested ranges. It never changes the user’s body fit or makes reactions physiologically impossible.
- Use several coach-reviewed styles later, each with declared tendencies and stochastic choices. Avoid one predictable template with inflated speed/health.
- Never model damage, concussion, pain, clinch, impact, or combat readiness.
- Acknowledge successful movement with audiovisual feedback; do not imply an avatar “hit” the user.

**Success gates**

- Users can predict what the level slider will change before starting.
- Opponent actions remain readable at every released level.
- Pattern diversity improves engagement without reducing defensive-form scores or increasing safety events.
- Remote-human coaching is evaluated separately from NPC behavior.

### 8. Audio and haptics

**Platform truth**

RealityKit supports spatial audio attached to entities and recommends mono source material to avoid spatial mixdown artifacts **[A]**. [Spatial audio](https://developer.apple.com/documentation/realitykit/spatialaudiocomponent) Apple explicitly lists Apple Vision Pro among devices that do not support Core Haptics **[A]**. [Core Haptics support check](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics)

**As built [B]**

- The working tree contains five original WAV resources—`coach-cue.wav`, `clean-hit.wav`, `miss.wav`, `paused.wav`, and `set-complete.wav`—a scene-owned `SpatialFeedbackPlayer`, and a sound-feedback toggle.
- `ImmersiveView` now routes Aura, Board, and Defense cue/success/miss/pause/completion events to the player and positions cue emitters at relevant guide, target, or defense locations.
- Sound can be muted from the window and from the in-space safety controls; only the preference persists.
- This is **wired final-source behavior included in the clean aggregate software build, but still pending physical-headset playback/latency/localization verification**; it is not an on-device acceptance result.
- Native headset haptics do not exist.

**Verification and next slice**

1. Complete the aggregate build/test pass and verify that every bundled resource loads on Simulator and device.
2. Measure event-to-playback latency and spatial localization on a physical headset; playback failure must never affect scoring.
3. Verify that rapid state changes do not clip or overlap samples in a confusing way and that system/coach announcements remain comprehensible.
4. Keep the currently honored sound toggle local and reversible. Split voice, earcon, and ambience controls only when those channels genuinely exist, then persist each explicit preference separately.
5. Keep every important sound paired with visual/text status and maintain accessibility announcements.
6. Never describe audio vibration as haptic feedback.

**Optional external haptics**

An Apple Watch companion can play supported watch haptic patterns while its app is active **[A]**. [Watch haptic API](https://developer.apple.com/documentation/watchkit/wkinterfacedevice) This is an accessory path, not AVP haptics. It requires a watchOS target, explicit pairing/status UI, end-to-end latency measurement, and a fallback when the watch is absent. Haptics should reinforce discrete cue/success states, never carry the only safety information.

## Waist and footwork: honest sensor-fusion architecture

### AVP-only baseline

```text
HandTrackingProvider                         WorldTrackingProvider
  left/right joints + capture times           DeviceAnchor pose + time
              |                                         |
              +------------ quality gates --------------+
                                  |
                       Boxer-relative frame
                                  |
                 fist path / guard / head proxy
                                  |
        confidence-gated upper-body contribution estimate
```

The first AVP-only torso estimator should expose:

- estimated shoulder centre and horizontal axis from neutral headset/hand geometry;
- estimated upper-torso yaw change and angular velocity;
- lateral headset displacement;
- hand onset, peak hand speed, extension, and return;
- a confidence state based on both hands, device tracking, plausible geometry, and recency.

It must output **unavailable** when inputs are inadequate. It must not emit waist or pelvis coordinates. A transparent unvalidated training index may combine normalized observable terms, for example:

```text
upperBodyContribution =
    w1 * upperTorsoYawChange
  + w2 * peakUpperTorsoAngularSpeed
  + w3 * peakHandSpeed
  + w4 * sequenceTimingQuality
```

Weights must be versioned and coach-reviewed. The UI should report the components and label the result “upper-body contribution,” not “hip rotation.”

### Optional companion layers

```text
Apple Watch Core Motion / HealthKit
              |
       WatchConnectivity
              v
     +-------------------+       Multipeer / local transport       +------------------+
     | iPhone companion  | --------------------------------------> | Vision Pro app   |
     |                   |                                         |                  |
     | Vision body pose  |                                         | AVP hand/device  |
     | belt IMU over BLE |                                         | tracking         |
     | clock sync + QC   |                                         | fusion + UI      |
     +-------------------+                                         +------------------+
              ^
              |
       belt-mounted IMU
  accelerometer / gyroscope / optional magnetometer
```

Apple’s Vision framework can provide camera-relative full-body landmarks on iPhone **[A]**. Core Motion provides acceleration, attitude, rotation-rate, and magnetic-field data on supported Apple devices **[A]**. [Core Motion](https://developer.apple.com/documentation/coremotion/) Watch Connectivity exchanges data between a watchOS app and its paired iOS companion **[A]**, so the robust Watch route is Watch → paired iPhone → local Vision Pro session, not an assumed direct Watch-to-visionOS channel. [Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity) Nearby device transport can use message/stream exchange such as Multipeer Connectivity, subject to local-network permissions and measured latency **[A]**. [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity)

### Sensor roles

| Source | Adds | Does not add |
|---|---|---|
| AVP hands | Precise in-experience hand paths, guard, reach, relative timing | Pelvis, feet, impact, force |
| AVP device pose | Headset translation/orientation and world frame | Head joint, neck mechanics, balance, foot placement |
| iPhone camera | Visible shoulders/hips/knees/ankles and full-body pose confidence when framed | Ground reaction, hidden joints, guaranteed metric accuracy, AVP camera access |
| Belt IMU | Sensor angular velocity/acceleration near the belt; useful yaw-rate evidence after alignment | True pelvis position, footwork, impact force; magnetometer is not assumed trustworthy indoors |
| Apple Watch | Heart-rate/workout context; one wrist’s motion; optional haptic endpoint | Waist/hip truth, both hands, direct Vision Pro haptics |
| Instrumented bag | Contact/motion/impact evidence according to its validated sensors | Whole-body technique by itself |

Wearable boxing research shows that IMU systems can be reliable in specific validated setups, but results depend on placement, range, filtering, event detection, population, and reference method **[R]**. One 2026 study aligned an IMU system with optical motion capture using explicit synchronization; a separate validation compared inertial and contact systems with laboratory references. [IMU vs motion capture](https://pmc.ncbi.nlm.nih.gov/articles/PMC12963049/), [boxing monitoring validation](https://pmc.ncbi.nlm.nih.gov/articles/PMC8588074/) These studies justify validation work; they do not transfer their accuracy to a new belt sensor or algorithm.

### Fusion requirements

1. **Common time:** run ping/response clock-offset estimation, track drift, timestamp at capture, resample within a declared window, and reject stale streams. Arrival time is not capture time.
2. **Common coordinates:** define AVP boxer-forward at neutral. Use a known visual reference seen by both iPhone and AVP to solve camera-to-world alignment. Align belt sensor axes in a guided neutral/rotation step.
3. **No IMU position integration:** do not double-integrate belt acceleration into waist coordinates for the product. Drift will produce plausible-looking fiction.
4. **Per-source quality:** include tracked state, joint confidence, packet age/loss, calibration residual, and sensor saturation.
5. **Fail closed:** if a source degrades, remove dependent metrics and continue only with valid lower-tier features.
6. **Source-labelled output:** “belt angular speed,” “camera-estimated hip angle,” and “AVP-estimated upper-body rotation” remain distinct until a validated fusion model supports another claim.
7. **Sequence metric:** with a belt sensor, compare onset/peak timing of belt yaw rate, camera upper-torso rotation, and AVP fist velocity. Call this a sensor-derived sequencing metric, not proof of kinetic energy transfer.

### Footwork recommendation

Do not add another sensor for the first AVP demo. Keep the user planted and perfect hand/device evidence. For a footwork prototype, add an iPhone full-body view before adding shoe IMUs. Advance only if feet remain visible, joint confidence is reliable, and the shared frame is stable. Waist IMU data improves rotation evidence; it does not solve foot placement.

## Experience rules that apply everywhere

- **Mixed passthrough first:** Apple advises the minimum necessary immersion and cautions against excessive movement in immersive experiences **[A]**. [Designing for visionOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos)
- **One active sensing owner:** one ARKit session and one sample-routing owner; feature engines consume plain timestamped values.
- **Logical events are truth:** scoring follows the logical cue and capture timestamps, not a rendered frame or sound completion.
- **Tracking loss is a state:** pause, explain, clear partial recognition, and resume without a punitive miss.
- **Safety-range loss is distinct:** Defense excessive motion cancels evidence and requires neutral plus explicit resume/fresh countdown; report it separately from tracking/system interruptions.
- **Controls and training do not compete:** configure with standard gaze/pinch before movement; keep Stop & Exit continuously available.
- **Difficulty never changes body fit or safety:** only presentation pressure, assistance, and authored complexity vary.
- **One correction at a time:** prioritize the highest-confidence actionable component.
- **Local by default:** store only explicit scalar profiles and UI preferences. Keep evidence, recommendation instances, attempt results, world transforms, and traces session-only; any future history/video/trace capture requires a separate product decision and explicit consent.
- **Accessibility is multimodal:** the current source has a content-minimum resizable window, scroll-safe accessibility-size home/detail layouts, and important state announcements. Combine shape, colour, text, spatial audio, and announcements; never make haptics or colour the only channel. Physical VoiceOver/focus acceptance remains pending.

## Failure patterns to avoid

| Failed pattern | Why it fails | ShadowBox rule |
|---|---|---|
| Calling every heuristic “AI” | Creates an unverifiable promise and hides logic. | Name the current system rules-based; earn the ML label through evaluation. |
| Fabricated hip, power, calories, or impact | The baseline sensors do not observe the required quantity. | Report direct/derived/proxy status beside the metric. |
| Harder means faster-than-readable | Produces frustration, unsafe motion, and game exploitation. | Bound telegraph/pace through device and comfort tests; add complexity and initiative gradually. |
| One robotic opponent with inflated stats | Becomes predictable without becoming instructive. | Coach-authored states, several tendencies, constrained randomness, and explicit level effects. |
| Hand-only menus while hands are punching | Tracking ambiguity and fatigue undermine setup. | Standard gaze/pinch UI for controls; reserve hand motion for training. |
| Treating tracking loss as a miss | Punishes the user for missing evidence. | Pause and invalidate partial attempts. |
| Resetting level/calibration without explanation | Adds repetitive setup and breaks trust. | Preserve appropriate session state, show provenance, and offer deliberate reset/recalibration. |
| Novel but biomechanically implausible combos | Can reward habits that conflict with the training promise. | Coach review and stance-aware content before scoring. |
| Mandatory accessory or opaque subscription | Adds cost and support burden before value is proven. | Optional sensor tiers, visible added metric, graceful AVP-only mode, transparent pricing. |
| Native AVP haptic claims | Apple Vision Pro has no Core Haptics support. | Use audiovisual feedback or an explicitly paired Watch/controller endpoint. |
| “Persona” used for an NPC | Confuses an Apple SharePlay identity feature with a custom character. | Call it a 3D coach/avatar; reserve Persona for real participants. |
| Enabling real-bag striking after visual alignment only | A stable-looking overlay does not prove bag motion, contact, clearance, or headset safety. | Keep preview-only until every alignment, motion, contact, and safety gate passes. |

## Sequenced delivery roadmap

### Gate 0 — trust and device acceptance

- Preserve the achieved clean software gate: 111/111 tests, clean generic
  Simulator/unsigned arm64 builds, and bundles containing `Assets.car`,
  `PrivacyInfo.xcprivacy`, and all five WAVs. Any source change requires a fresh
  aggregate run.
- Signed install on a physical Vision Pro; verify permissions, denial, interruption, recentering, thermal behavior, tracking loss, and emergency exit.
- Characterize current hand/head proxy latency and false recognition with synchronized reference video.
- Verify the wired spatial-audio resources, localization, mute state, and latency; do not advertise the feature before end-to-end playback works on device.
- Retain explicit non-contact bag and planted-feet defense boundaries.

### Gate 1 — coherent AVP-only product

- Boxer-relative frame and reusable session calibration.
- Three-capture Anthropometry/reach quality flow.
- Persistent, reversible local preferences for level/recommendation opt-in/audio; evidence, recommendations, and results remain session-only.
- Complete attempt explanations and physically verified spatial earcons.
- Coach-reviewed jab/cross content and a reliable Fit → Learn → React → Reflect demo.

### Gate 2 — custom 3D coach

- Licensed/authored rigged model and coach-approved jab/cross/guard/defense animations.
- Demonstrator and pad-holder state machine before any sparring avatar.
- Defensive pattern partner with bounded telegraphs, recovery, and difficulty mapping.
- Usability, comfort, performance, occlusion, and animation-content acceptance on device.

### Gate 3 — iPhone/iPad companion

- Explicit nearby pairing, time synchronization, shared reference marker, and confidence UI.
- Guided full-body Anthropometry/pose capture and a non-scored footwork research mode.
- Bag alignment preview with immediate target suppression on tracking degradation.
- HealthKit/Watch workout integration only with permission and without independent calorie invention.

### Gate 4 — belt IMU and instrumented bag research

- Select sensor range/rate and rigid placement; calibration, saturation, drift, and packet-loss tests.
- Validate belt angular velocity against a reference system before calling it pelvis/hip motion.
- Fuse belt, camera torso, and AVP hand timing for an explicitly versioned sequencing score.
- Instrumented bag contact/motion only after alignment and safety validation.

### Gate 5 — evaluated ML

- Consent and data governance; participant-separated dataset and labels.
- Fixed and rule-based baselines; held-out calibration and subgroup results.
- Shadow-mode recommendations and abstention on uncertain data.
- Promote to Core ML-assisted recommendation only if it improves the predeclared outcome without weakening safety, control, or trust.

## Product and research scorecard

Define targets before each study; do not choose thresholds after seeing results.

| Area | Primary measures | Required evidence |
|---|---|---|
| Reliability | crash-free sets, permission recovery, tracking interruptions, stale-sample rejection, resume success | device logs plus observed test protocol |
| Fit | calibration completion/time, repeated-reach spread, target-placement error, recalibration rate | physical AVP trials; camera/reference measurement where applicable |
| Aura | path/guard change at fixed level, completion, correction comprehension | engine records plus blinded coach/user review |
| Board | hit/miss precision and recall, wrong-hand classification, response-time error, guard-return censoring | synchronized reference annotation |
| Defense | head-proxy event precision/recall, cue readability, boundary interruptions, adverse symptoms | physical-device safety study |
| Adaptive rules | acceptance, reversal, oscillation, next-set challenge band, hold behavior after bad tracking | prospective comparison with fixed level |
| 3D coach | instruction comprehension, presence, comfort, animation credibility, opponent predictability | target-user and qualified-coach sessions |
| Audio | cue-to-play latency, localization comprehension, mute/accessibility success | on-device instrumentation and accessibility review |
| Sensor fusion | clock residual, transform residual, packet loss, drift, source availability, reference error | laboratory/reference protocol by sensor tier |
| User fit | task success, UMUX-Lite/SUS, preference vs timer/video alternative, repeat intent, interview themes | observed target-user study; not competitor reviews |
| Market fit | repeat sessions, D1/D7 return in a pilot, willingness to pay, accessory attach interest, cancellation reasons | ShadowBox cohort data only |
| Safety | near misses, stop success, discomfort, nausea, headset movement, bag alignment loss | incident log and reviewed acceptance criteria |

No “traction” claim should appear in a pitch until it comes from ShadowBox usage with a declared sample, time window, denominator, and definition of active use.

**Funding boundary:** the official [Singapore Sport Science and Technology Research Grant page](https://www.sportsingapore.gov.sg/our-work/high-performance-sport-institute/science-and-technology/singapore-sport-science-and-technology-research-grant/) lists a 2017 call marked closed. ShadowBox makes no claim that SSSTRG is currently open or available; any funding path requires current written confirmation **[A]**.

## Claim boundary for UI, pitch, and judges

### Defensible now, subject to physical-device validation

- “Controller-free hand-tracked jab/cross fundamentals.”
- “Targets fitted to a captured guard and comfortable reach.”
- “Deterministic path, extension, target response, and guard-return feedback; measured execution pace remains internal and does not affect the score.”
- “A separately labelled, fail-closed trajectory-shape diagnostic is source-wired and excluded from coaching and the overall score.”
- “Headset-motion proxy for stationary slip/duck drills.”
- “Defense fails closed on excessive range, separates safety-range from tracking/system pauses, and requires neutral plus explicit resume/fresh countdown.”
- “Five user-controlled presentation levels with explainable rules-based next-set suggestions.”
- “Local scalar profile data; no raw camera feed or cloud model in the MVP.”

### Conditional after the named gate

- “Spatial audio feedback” only after immersive playback and latency verification.
- “3D coach” after an authored character is integrated and content-reviewed.
- “Full-body camera-assisted cues” after the companion camera and confidence contract work.
- “Belt angular-velocity and sequence metrics” after sensor/reference validation.
- “ML-assisted recommendation” after held-out evaluation against the rules baseline.
- “Real-bag targets/contact” only after alignment, motion, contact, and safety gates.

### Prohibited without new evidence

- Full-body, pelvis, hip, knee, footwork, balance, or professional-technique tracking from AVP alone.
- Plantar pressure, ground reaction, weight transfer, or causal lower-limb contribution inferred from hand motion.
- Punch force, effective mass, impact power, damage, protection, concussion, injury prevention, or medical guidance.
- A spatial Persona as an AI NPC.
- Native Apple Vision Pro haptics.
- Real sparring, fight IQ, combat readiness, or replacement for a qualified coach.
- “AI-personalized” for the current deterministic advisor.
- Training effectiveness, commercial traction, retention, or market leadership inferred from competitor reviews.

## Source register

### Apple capability and design sources [A]

- [Using Apple Vision Pro safely](https://support.apple.com/en-us/118519)
- [HandTrackingProvider](https://developer.apple.com/documentation/arkit/handtrackingprovider/)
- [DeviceAnchor and WorldTrackingProvider](https://developer.apple.com/documentation/arkit/deviceanchor)
- [Setting up access to ARKit data](https://developer.apple.com/documentation/visionos/setting-up-access-to-arkit-data)
- [Accessing the main camera](https://developer.apple.com/documentation/visionos/accessing-the-main-camera)
- [3D human body poses with Vision](https://developer.apple.com/documentation/vision/identifying-3d-human-body-poses-in-images)
- [ImageAnchor reference image and tracking state](https://developer.apple.com/documentation/arkit/imageanchor/referenceimage)
- [RealityKit character control, skeletons, and inverse kinematics](https://developer.apple.com/documentation/realitykit/game-development-character-skeletons)
- [RealityKit spatial audio](https://developer.apple.com/documentation/realitykit/spatialaudiocomponent)
- [Core Haptics device support](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics)
- [Spatial Personas in SharePlay](https://developer.apple.com/documentation/groupactivities/adding-spatial-persona-support-to-an-activity)
- [Core Motion](https://developer.apple.com/documentation/coremotion/)
- [Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity)
- [Apple Watch haptic endpoint](https://developer.apple.com/documentation/watchkit/wkinterfacedevice)
- [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity)
- [visionOS gesture guidance](https://developer.apple.com/design/human-interface-guidelines/gestures)
- [visionOS immersive-experience guidance](https://developer.apple.com/design/human-interface-guidelines/immersive-experiences)

### Measurement research [R]

- [Quality assurance for anthropometric measurements](https://pmc.ncbi.nlm.nih.gov/articles/PMC4799648/)
- [Lead-jab versus rear-cross force/acceleration study](https://www.mdpi.com/2076-3417/14/7/2830)
- [Punch acceleration and plantar-pressure study](https://www.mdpi.com/1424-8220/26/9/2707)
- [Effective-mass and force-transfer study](https://www.mdpi.com/2076-3417/15/7/4008)
- [Elite versus junior punch-technique study](https://www.frontiersin.org/journals/sports-and-active-living/articles/10.3389/fspor.2020.598861/full)
- [Dummy/load-cell force-estimation paper](https://commons.nmu.edu/isbs/vol42/iss1/164/)
- [Reliability and validity of an IMU boxing punch system against optical motion capture](https://pmc.ncbi.nlm.nih.gov/articles/PMC12963049/)
- [Validation of a boxing monitoring system](https://pmc.ncbi.nlm.nih.gov/articles/PMC8588074/)
- [Concurrent validity and reliability of punch measurement devices](https://pubmed.ncbi.nlm.nih.gov/29112053/)

### Product and user signals [P/U]

- [Boxing Trainer: Punch Master](https://apps.apple.com/us/app/boxing-trainer-punch-master/id6743240378)
- [Beat Punch ratings and reviews](https://apps.apple.com/us/app/beat-punch-fun-fitness/id6478818247?platform=vision&see-all=reviews)
- [Hand Physics Lab ratings and reviews](https://apps.apple.com/us/app/hand-physics-lab/id6752609486?platform=vision&see-all=reviews)
- [Precision Boxing Coach reviews](https://apps.apple.com/us/app/precision-boxing-coach-pro/id702519995?platform=iphone&see-all=reviews)
- [Callout boxing app](https://apps.apple.com/us/app/callout-the-boxing-app/id1473350118)
- [FightCamp registration/cost discussion](https://www.reddit.com/r/MuayThai/comments/1ra9w1q/fightcamp_or_body_action_reviews/)
- [VR boxing transfer and haptic limitations discussion](https://www.reddit.com/r/ThrillOfTheFight/comments/1pnpu2a/does_vr_boxing_skill_reflect_reality/)
- [AI difficulty and unclear hit feedback discussion](https://www.reddit.com/r/ThrillOfTheFight/comments/1p6mbbg/the_ai_is_hard_to_beat/)
- [AI predictability discussion](https://www.reddit.com/r/ThrillOfTheFight/comments/1v6w92e/for_brothers_with_boxing_experience_is_the_ai_in/)
