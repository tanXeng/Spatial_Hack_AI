# ShadowBox product strategy

**Market snapshot:** 8 August 2026
**Product state evaluated:** current local visionOS MVP (product title: **ShadowBox**; in-app category header: **Boxing Trainer**)
**Positioning discipline:** a spatial skill-rehearsal product, not a force meter, full-body biomechanics system, sparring simulator, or replacement for a qualified coach.

## Decision in one sentence

Proceed as a **premium, controller-free spatial boxing technique lab for Apple Vision Pro owners and coached demos**, centered on personalized reach, visible hand-path guidance, reaction practice, and trustworthy feedback. Do not position the MVP as a mass-market fitness subscription or an elite-performance analyzer until retention, headset comfort, and physical-device accuracy are demonstrated.

## Evidence legend and research standard

- **[E] External evidence:** a claim supported by a linked Apple, App Store, or vendor source current at the snapshot date. Vendor efficacy and usage figures are vendor claims, not independent validation.
- **[B] Source evidence:** behavior visible in the local source at the snapshot date. Test-file presence is not a passing test result; current builds/tests and signed physical Apple Vision Pro validation remain separate gates.
- **[H] Hypothesis:** a user, market, pricing, retention, or future-moat proposition that must be tested; it is not presented as fact.

The attached research was used as a systems map. Its critical platform claims were cross-checked against Apple's current documentation: standard visionOS apps can use [ARKit hand and world tracking](https://developer.apple.com/documentation/arkit/arkit-in-visionos), while forward-facing [main-camera access is an enterprise entitlement](https://developer.apple.com/documentation/visionos/accessing-the-main-camera) for eligible business use. This consumer MVP therefore makes no raw-camera, whole-body, footwork, hip, torso, bag-tracking, or computer-vision claim. Apple's guidance also favors [mixed immersion for experiences involving movement](https://developer.apple.com/design/human-interface-guidelines/immersive-experiences/), which supports the product's passthrough-first design.

**[B] Software gate:** the reconciled final-source snapshot contains 27 app
Swift files and 13 test Swift files; the in-place final Defense/accessibility
slice did not change the counts. Its final recursive suite passed 111/111, and
fresh generic Simulator/unsigned
arm64 builds succeeded with zero reported errors or warnings at the quiet 05:38
snapshot. Each xcresult's analyzer-warning field is 0; a standalone Xcode
Analyze action was not run. The older release-candidate result is
historical and must not be presented as current. No signed install, live-
headset acceptance, or
on-device spatial-audio verification has been performed, so device precision,
comfort, audio latency/localization, and training efficacy remain unvalidated.

## User and market fit audit

### Primary user

**[H] Curious beginner or fitness-oriented Apple Vision Pro owner** who wants to learn where a straight punch should travel, practice short drills at home, and receive immediate understandable feedback without mounting lights, wearing controllers, filming a video, or hitting equipment.

Jobs to be done:

1. “Fit the drill to my body so targets are not arbitrarily too near or too far.”
2. “Show me the path before asking me to perform it.”
3. “Tell me immediately whether my hand path, extension, timing, and guard return improved.”
4. “Give me a short reaction and stationary head-movement drill while I can still see my room.”
5. “Be honest about what was and was not measured.”

### Secondary users

- **[H] Boxing coaches and small gyms with access to Vision Pro:** a memorable, repeatable onboarding or fundamentals station—not an automated replacement for coach observation.
- **[H] Spatial-computing educators, demo spaces, and sports-technology partners:** a legible demonstration of personalized spatial interaction and deterministic motion feedback.
- **[H] Rehabilitation or clinical users are explicitly not a target** until medical design, evidence, and regulatory review exist.

### Poor-fit users for this MVP

- Competitive fighters seeking validated footwork, hip rotation, balance, punch impact, or tactical sparring analysis.
- Users whose core job is hitting a real heavy bag and measuring impact.
- Buyers choosing primarily on hardware price: Apple Vision Pro starts at [$3,499 in the U.S.](https://www.apple.com/newsroom/2025/10/apple-vision-pro-upgraded-with-the-m5-chip-and-dual-knit-band/), so the reachable consumer segment is narrow.
- Users seeking long workout libraries, licensed music, multiplayer competition, or caloric coaching today.

### Fit verdict

| Dimension | Verdict | Reason |
|---|---|---|
| Problem fit | **Promising, unvalidated** | Generic targets and delayed video review leave room for an embodied “show me, then score me” loop. User interviews are still required. |
| Solution fit | **Strong hackathon fit; conditional product fit** | The three-pillar flow makes personalization visibly affect coaching. Physical-device precision, comfort, and repeat use are not yet proven. |
| Platform fit | **Good for spatial differentiation; weak for mass reach** | Native hand/world tracking and passthrough enable the experience; headset price and exercise ergonomics constrain distribution. |
| Competitive fit | **Differentiated wedge, not feature leadership** | The MVP can win on calibration, immediacy, transparency, and privacy. It loses on content depth, impact sensing, full-body visibility, and multiplayer. |
| Commercial fit | **Unknown** | No retention, conversion, willingness-to-pay, or acquisition evidence exists yet. |

## The value proposition

> **ShadowBox turns the user's own reach into a spatial training coordinate system: first fit the coach to the boxer, then show the hand path in the room, then test it with immediate, explainable feedback—without recording video or pretending to measure force.**

The product loop is the proposition:

1. **Fit — Anthropometry.** **[B]** The user configures height, arm span, arm lengths, shoulder width, stance, and dominant hand as local scalar data, then performs a session-scoped guard plus two controlled functional-reach repetitions per hand. Each hand is checked independently and the minimum accepted left/right scalar is conservative.
2. **Learn — Aura Punch.** **[B]** An original procedural ghost glove and path markers demonstrate a jab or cross; three repetitions score path, extension, and other-hand guard. A separate speed-independent, arc-length-density-normalized trajectory-shape diagnostic appears only when every trace passes validation; it is session-only and excluded from coaching and overall scoring. Execution pace remains internal, unscored, and undisplayed.
3. **React — Reactive Strike.** **[B]** A six-pad jab/cross board tests cue response. A separate stationary defense drill uses headset position only as a head-position proxy for slips and ducks; excessive range during cues or gaps fails closed and requires neutral plus explicit resume/fresh countdown.
4. **Trust — Measurement contract.** **[B]** Metrics and next-level suggestions are deterministic and explainable, not ML. The UI states that feet, legs, hips, torso, posture, impact, force, medical status, real-bag alignment, and protection are not measured.

One locally persisted level 1–5 control changes only presentation pace and Aura
path density. An opt-in rule may propose one adjacent level after a complete
set, but the user must apply it. Five original spatial-audio WAVs and an in-space
mute control are wired in source; physical-headset playback/localization remain
pending and there are no native AVP haptics.

Aura start is gated on both hands being tracked. Defense visual and spatial-
audio cues share one calibrated user-relative basis and results distinguish
tracking/system interruptions from safety-range pauses. A flexible/resizable
window, scroll-safe accessibility-size cards, and key pause/fatal/completion
announcements are present in source; physical-headset accessibility acceptance
is still pending.

The physical-bag mode is **[B] a static, non-contact preview only**. It must remain visually and verbally separated from scored drills. The user must not strike a physical bag while wearing the headset.

The current hand-calibration and board geometry still contain world-axis assumptions. The user-facing safety card therefore instructs the boxer to choose one forward direction before calibration and keep facing it for that session. Orientation-independent placement is not a current claim.

## Competitive landscape

Public product claims were reviewed on **8 August 2026**. “Not stated” means the reviewed public page did not advertise that capability; it does not prove the product lacks it.

| Category / product | Publicly stated strength **[E]** | Where it wins | Honest ShadowBox position |
|---|---|---|---|
| Vision Pro — [Boxing Trainer: Punch Master](https://apps.apple.com/us/app/boxing-trainer-punch-master/id6743240378) | Hand-tracked physics heavy bag, combo cues, timed challenges, AI sparring, progress HUD, audio, and an immersive gym. | More game content, bag spectacle, sparring fantasy, progression, and audiovisual polish. | Do not compete on simulated impact or gym fantasy. Win on reach/guard personalization, visible teaching before testing, mixed-room grounding, and separate metric components. Its public page does not state equivalent anthropometric calibration. |
| Vision Pro — [Beat Punch](https://apps.apple.com/us/app/beat-punch-fun-fitness/id6478818247) | Rhythm boxing, music maps, fitness tracking, leaderboards, SharePlay, and subscription content. | Retention mechanics, music, social play, and cardio entertainment. | ShadowBox is deliberate practice, not a rhythm game. Add content only after the coaching loop is reliable; do not chase licensed-music scope in the MVP. |
| Vision Pro — [Rhythm Punch](https://apps.apple.com/us/app/rhythm-punch-fighting-games/id6477375218) | Controller-free hand tracking, music, courses, data analysis, and virtual/real-world blending. | Existing no-controller spatial fitness experience and scene variety. | Passthrough and hand tracking are not unique. Differentiation must come from calibration-driven geometry and transparent technique feedback. |
| VR boxing — [The Thrill of the Fight 2](https://www.thethrillofthefight2.com/) | Physics-oriented boxing, career mode, online multiplayer, matchmaking, avatars, and arenas; the vendor says the franchise has served more than one million players. | Combat simulation, competition, content, and an established audience. | Do not claim to be a fight simulator. ShadowBox teaches a narrow motion before asking for a response; it currently lacks opponents, footwork, and damage/impact modeling. |
| VR fitness — [FitXR](https://fitxr.com/pages/meta-quest) and [Supernatural Boxing](https://www.getsupernatural.com/faq?clean=true) | Large coached workout catalogs, multiple exercise modalities, music, progression, and performance scores. | Workout breadth, instructor energy, habit formation, and production maturity. | ShadowBox's edge is individual spatial fit plus explicit technique components. It cannot match their library or proven retention loop yet. |
| Reaction hardware — [BlazePod](https://www.blazepod.com/) | Durable touch-sensitive light pods, hundreds of drills, live reaction data, analytics, and multi-setting use; the vendor reports over one million pods sold. | Physical touch confirmation, portability, team/coach workflows, and mature drill depth. | The six-pad board removes extra setup for someone who already owns Vision Pro and can resize to reach, but it provides no tactile strike or independently validated millisecond hardware timing. |
| Connected boxing — [FightCamp](https://joinfightcamp.com/work/technology) | Wrist trackers classify punches and report count, type, speed, timestamp, and a proprietary output metric; its [All-Access membership](https://meals.joinfightcamp.com/work/memberships) advertises thousands of guided workouts. | Real bag use, dedicated sensors, long-term training history, and a deep coaching catalog. | ShadowBox requires no wrist sensors but cannot measure bag contact or actual impact and does not persist training history. The bag preview is not a substitute. |
| Smart bag — [BHOUT](https://www.bhout.com/bag) | Bag sensors plus computer vision, strike location/type, power-oriented data, gamification, lights, and physical impact. | Instrumented contact, full-body strike variety, tactile experience, and equipment moat. | Entirely different job and cost structure. ShadowBox's advantage is software-only spatial rehearsal; its disadvantage is no contact truth. |
| Phone camera — [Punch AI](https://apps.apple.com/us/app/punch-ai-boxing-coach/id6761316809) | Real-time body/hand computer vision, offense/defense drills, footwork-related drills, uploads, post-session coaching, social features, and a much cheaper device path. | Full-body field of view, accessibility, sharable video, and lower platform cost. | ShadowBox gives in-head, world-space guidance without a tripod or recorded footage, but sees only hands plus a headset-position proxy. Never imply equivalent body analysis. |
| Video technique — [FighterLab](https://fighterlab.app/) | 30–60 second shadowboxing, bag, or mitt video analysis with ranked issues and corrective drills. | Coach-like post-session explanation, body-level visual context, and phone reach. | ShadowBox closes the loop during movement and keeps motion processing local, but its coaching vocabulary and body evidence are much narrower. |
| Combat analytics — [Jabbr DeepStrike](https://jabbr.ai/deepstrike) | Computer-vision fight analytics: punch counts, stance/balance, distance, combinations, impact categories, and predicted scoring. | Fight footage, two-athlete analytics, broadcasting, and a data/model lead. | Not a direct consumer drill competitor. It demonstrates the value—and complexity—of video-based whole-fight analysis that this consumer visionOS app cannot honestly claim. |

### Competitive scorecard for the current MVP

| Dimension | ShadowBox status | Competitive interpretation |
|---|---|---|
| Personal reach/guard affects target geometry | **[B] Present** | Strongest visible wedge; demonstrate it, do not bury it in settings. |
| Real-time “show path, then perform” loop | **[B] Present for jab/cross hands only** | More instruction-oriented than rhythm targets; narrower than a human coach or full-body video. |
| Explainable component metrics | **[B] Present** | Trust advantage over a single opaque “AI score,” but thresholds still need expert validation. |
| Mixed passthrough | **[B] Present** | Safety-appropriate, but not unique among spatial competitors. |
| External sensors/controllers required | **[B] No, beyond Vision Pro** | Low incremental setup for headset owners; total platform cost remains high. |
| Raw video upload | **[B] None** | Clear privacy and immediacy benefit; prevents whole-body analysis and replay. |
| Physical impact/tactile confirmation | **[B] Absent** | Major disadvantage versus reaction pods and connected bags. |
| Footwork/hips/torso/balance | **[B] Absent** | Major disadvantage versus camera coaching; must remain prominent in product language. |
| Content, social, progression, history | **[B] Minimal/absent** | Largest retention gap after device reliability. |
| Device validation | **[B] Pending** | Blocks credible accuracy or safety-performance claims. |

## Why now

- **[E] Platform capability:** ARKit provides native hand positions/joints and device/world tracking without consumer main-camera access. That is enough for a truthful hand/head spatial coach, though not full-body biomechanics.
- **[E] Platform maturity:** Apple's M5 Vision Pro and visionOS 26 improve performance and comfort, and Apple reports more than one million compatible apps and thousands of games. This supports better demos, not proof of a large fitness audience.
- **[E] Category validation:** Vision Pro already has multiple boxing/rhythm products, while VR boxing, reaction pods, connected bags, and camera coaches demonstrate demand for engaging feedback. Their existence validates the problem space and raises the quality bar.
- **[H] Timing wedge:** Most reviewed offerings optimize either entertainment, instrumented impact, or analysis after the motion. A compact, private, in-the-moment spatial teaching loop may occupy a useful middle position.

## Defensibility: what is real and what must be earned

### Present edge

1. **[B] One calibration drives several experiences.** The saved stance maps lead/rear hands; bilateral live reach/guard calibration affects guidance and target placement, making personalization observable rather than decorative. Aura can transfer directly to Board in the same immersive space without discarding that calibration. Entered height and limb lengths do not drive spatial geometry in this MVP.
2. **[B] Closed-loop learning design.** Anthropometry → Aura → Board/Defense creates a coherent progression instead of a menu of unrelated mini-games.
3. **[B] Explainable deterministic scoring.** Component measures can be tested with synthetic traces and discussed honestly with coaches.
4. **[B] Privacy-minimal architecture.** Current code has no networking path. Validated boxer/bag profiles and explicit difficulty/sound/recommendation-opt-in preferences persist locally; evidence, recommendation instances, joint samples, room/world transforms, motion traces, and results are not persisted or uploaded. Apple's platform requires permission for hand structure/movement and says hand setup measurements remain on device in its [Eyes, Hands & Privacy notice](https://www.apple.com/legal/privacy/data/en/eyes-hands/).

### Not a moat

- SwiftUI/RealityKit UI, ARKit hand tracking, target collisions, and passthrough are platform capabilities available to competitors.
- “AI boxing coach” wording is not defensibility and would weaken credibility because the MVP is deterministic.
- A three-mode demo without content, expert validation, retention, or proprietary data is reproducible.

### Moat to earn **[H]**

1. Coach-reviewed reference trajectories and error taxonomies for specific punches.
2. Repeated-measure reliability across users, stances, reach ranges, lighting, and device fits.
3. An opt-in, consented, privacy-preserving dataset linking tracked hand/head features to expert labels; no such dataset or flywheel exists today.
4. Adaptive drills based on longitudinal performance, only after persistence and consent are redesigned.
5. A reusable spatial-motion engine for other hand-led sports, only after boxing produces genuine user value.

## Judge-winning demo narrative

The “wow” moment is not a claim about AI. It is watching a procedural guide and
board **reshape around the boxer**, teach one observable motion in the physical
room, and reuse the same fit for reaction practice.

### Four-minute path

1. **0:00 — State the problem.** “Most digital boxing tools either give everyone the same target, require extra hardware, or analyze video after the round. ShadowBox fits the training space to the person and coaches during the movement.”
2. **0:20 — Show the contract.** Open the three-card home: Anthropometry, Aura Punch, Reactive Strike. Point out mixed passthrough, local profile, and “no force claims.” This earns trust early.
3. **0:40 — Personalization reveal.** Enter Anthropometry, hold guard, then complete two controlled, submaximal extensions per hand. Show the per-hand repeatability result and conservative bilateral value. This is the differentiating moment.
4. **1:20 — Teach with Aura.** Select jab. Let the procedural ghost glove/path demonstrate; perform three controlled reps. Reveal path, extension, guard, and the separately labelled trajectory diagnostic—not a mysterious verdict or pace reward.
5. **2:20 — Transfer to reaction.** Use **Continue to Punch Board** without closing the mixed space. Show that the six-pad board reuses the same live fit and then show response-time/guard feedback.
6. **3:20 — Close the loop.** “Fit. Learn. React. Local rules, local preferences, session-only motion evidence, and no force fiction.” Use Defense only as an optional rehearsed extension and label it a headset-motion proxy.

### Demo controls and failure plan

- **[H]** Use a trained presenter and a marked clear zone; complete fresh live calibration before the scored drill.
- **[H]** Keep a short device-captured backup video of the same uninterrupted flow. Label it as recorded, never simulate a live result.
- If hand tracking degrades, demonstrate the safe pause/hidden targets and recovery instead of concealing it; this turns a platform failure into safety evidence.
- Do not demo the bag preview as a headline. It is a roadmap visualization and weakens the proof if mistaken for physical-bag tracking.
- Follow [JUDGE_DEMO.md](JUDGE_DEMO.md) for exact four-minute timing, audio
  mute, physical-device/Simulator fallback labels, and fail-safe abort points.

## Adoption and monetization hypotheses

These are experiments, not forecasts.

| Hypothesis | Cheapest test | Pass signal |
|---|---|---|
| **[H1]** Vision Pro owners value technique guidance more than another rhythm workout. | Moderated A/B concept test: current calibrated Aura loop vs. generic fixed targets, 12–20 target users. | ≥65% prefer calibrated guidance and can explain why without prompting. |
| **[H2]** The three-step loop creates repeat intent. | Let 10+ target users complete Fit → Aura → Board, then offer an unscheduled return session within seven days. | ≥50% voluntarily return or book another session; do not rely on stated intent alone. |
| **[H3]** Coaches see it as a fundamentals aid, not a threat or toy. | Five coach interviews plus supervised trials; ask them to identify appropriate and inappropriate uses. | Three request a second pilot and can name one drill they would prescribe. |
| **[H4]** A one-time consumer price fits the early product better than a subscription. | Price-sensitivity test at US$19.99 / $39.99 / $59.99 after a hands-on demo; no preorders until device validation. | ≥30% credible purchase intent at one tier, followed by actual conversion in a TestFlight/App Store pilot. |
| **[H5]** A studio/demo license can work before mass consumer scale. | Two paid or letter-of-intent pilots with gyms, schools, or spatial demo venues using one supervised headset station. | Repeat weekly use and a named budget owner; novelty-only events do not count. |
| **[H6]** Users will pay recurring only for continuing value. | Do not launch a subscription. First prototype coach-authored drill packs and longitudinal progress; test after four-week retention. | ≥40% four-week retention among activated users and explicit demand for new programs. |

Recommended sequence: free supervised pilot → one-time paid early-access app → optional paid drill packs. A subscription is justified only by demonstrated recurring content and retention. Hardware integration, social competition, cloud accounts, and bag tracking are later businesses, not MVP monetization decorations.

## Measurable MVP success criteria

### Gate 1 — Device truth and safety

- Ten consecutive headset sessions complete without crash, stuck immersion, or loss of the Stop/Exit path.
- Tracking loss always pauses scoring and hides unsafe active targets; recovery never manufactures a hit.
- 100% of test users complete a clear-space acknowledgement and can exit without coaching.
- No target appears outside the intended forward arm-reach zone during the test matrix.
- No participant strikes a real object, reports collision, or believes the headset is protective equipment.

### Gate 2 — Reliability

- Fresh guard/reach calibration completes within 60 seconds for ≥90% of supported testers.
- Synthetic trace tests remain deterministic: identical input produces identical cue and score output.
- Same-user repeated calibration places comparable straight-punch targets within a predeclared tolerance chosen before testing; report the measured distribution rather than selecting a favorable threshold afterward.
- Device testing records tracking interruptions, false hits, missed obvious hits, and recovery time by mode. “Felt accurate” is not sufficient.

### Gate 3 — User value

- ≥80% of first-time testers complete Fit → Aura → one Reactive drill without developer intervention.
- ≥70% correctly describe at least two measured metrics after the session.
- **Comprehension safety:** 100% correctly state that force, impact, feet, hips, torso, balance, and real-bag alignment were not measured.
- Median System Usability Scale target: ≥80 after physical-device stabilization.
- ≥60% say the live spatial guide helped them understand the intended hand path better than a fixed 2D instruction; verify with a counterbalanced comparison.
- Internal path/guard scores improve across repeated sets only as a product-learning signal, never as proof of better boxing technique without expert validation.

### Gate 4 — Market signal

- At least 12 target-user sessions, five coach interviews, and two supervised venue trials.
- ≥50% observed seven-day return among users with continuing headset access.
- At least three coaches request a repeat trial or provide a concrete drill they would use.
- At least one paid pilot or ten actual consumer purchases before expanding scope beyond reliability and content.

### Stop or pivot conditions

- Most users experience discomfort before completing a five-minute loop.
- Obvious punches cannot be detected consistently across supported hand shapes, stances, and device fits.
- Users value only rhythm/cardio and do not perceive incremental value from calibration or Aura guidance.
- Coaches consistently say hand-only metrics create unsafe confidence even with prominent boundaries.
- Demand centers on real impact or whole-body analysis; in that case, pivot to an external-sensor/camera companion rather than disguising the platform limitation.

## Product and communication guardrails

### Say

- “Hand-path, extension, timing, and guard feedback, plus a separately labelled trajectory-shape diagnostic.”
- “Stationary head-movement cues using headset position as a proxy.”
- “Stance mapping comes from your saved profile; target geometry comes from live guard/reach calibration.”
- “Local processing; no session video or motion trace upload in this build.”
- “A practice aid for fundamentals and reaction—not professional evaluation.”

### Never say in this MVP

- “Measures punch force/power,” “prevents injury,” “correct biomechanics,” or “professional-grade technique.”
- “Tracks footwork, hips, torso, balance, posture, or a physical bag.”
- “AI coach” or “learns your style”; no ML model is in the current feedback loop.
- “Validated accuracy” until the physical test protocol and results exist.
- “Private by Apple” as a substitute for the app's own data disclosure; state exactly what the app stores and does not store.

## Product priorities after the hackathon

1. Physical headset reliability and safety evidence.
2. Coach review of the jab/cross guide geometry, metrics, language, and thresholds.
3. A short onboarding that proves why profile + live calibration changes the experience.
4. Session history for scalar summaries only, with explicit consent and retention controls.
5. More coach-authored hand-only drills and progressive difficulty.
6. Physical-headset accessibility, spatial-audio playback/localization, mute,
   and comfort testing; audio is already source-wired, not a new feature claim.
7. Only then evaluate external iPhone camera or wearable/bag sensors for full-body or impact evidence; these are separate consent, architecture, and validation programs.

The product can compete by presenting the most convincing **evidence-backed spatial feedback loop**, not by listing the most future features. Its competitive advantage is the combination of personalization, embodied instruction, immediate transfer, privacy, and scientific restraint—and its credibility depends on keeping every limitation and pending device gate visible.
