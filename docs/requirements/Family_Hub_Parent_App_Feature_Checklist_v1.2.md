# Family Hub — Parent App Feature Checklist
## Version 1.2 · User review applied · Codex-ready

**Purpose:** This checklist is the simple-language, reviewable source for the Parent App. It preserves all features from the prior checklist except where the product owner has explicitly changed or deferred them. It is aligned to the approved local-first School ERP architecture.

**Status:** Review decisions applied; implementation and legal/store-policy validation remain separate release gates.

### Priority key
- **P0 — Required:** Needed for the app to be safe and useful at launch.
- **P1 — Important:** Include when the core app is stable and integrated.
- **P2 — Optional/advanced:** Keep in the product design, but defer activation until approved.

### Decisions now applied
1. **Free access with ads:** Parents who do not buy the Parent App subscription can continue using the app in an ad-supported mode. Ads are displayed in the Parent App, not the future Student App.
2. **Ad placements:** Support (a) Google AdMob App Open ads on eligible app starts/resumes, subject to frequency controls, and (b) an eligible ad transition when a free parent opens or downloads certificates/report cards/other approved documents. Ads never get embedded inside a document or impersonate school content. Do not stack an App Open ad directly next to another ad.
3. **Growth features:** On every fresh entry to Child Development, Portfolio and Analysis, a non-subscribed parent is shown a clear choice between the paid entitlement and an ad-supported visit. A subscribed parent bypasses the choice. Do not show another choice for every tap within the same open section.
4. **Drive backup:** Google Drive backup is optional, explicitly enabled by the parent, scoped to that parent's own app data, encrypted before upload, and restorable after sign-in on a replacement phone. It does not replace the school's authoritative database.
5. **Courses:** Course discovery and purchase are currently **disabled and invisible to parents**. A PHP/backend feature flag can enable them later. Once enabled, the parent buys the course for a selected child; the entitlement is intended to activate in the Student App when that app is available. Do not build or expose incomplete student-app activation UI now.
6. **Transport and AI:** Both are disabled and invisible by default, controlled by backend feature flags. The optional AI assistant is a paid value-added service when enabled.
7. **Parent verification:** Use automated matching against school-recorded guardian contact details, OTP/passkey where appropriate, and automatic linking of records that confidently match. Route ambiguous cases to school approval. An admission number alone is not proof of guardian identity.
8. **UI/UX:** Preserve the current good component library and colour palette. Reduce the oversized logo, add persistent bottom navigation, make the interface calm and readable, and minimise taps for frequent tasks.
9. **External certificates:** Parents cannot upload external certificates or achievements. They can view school-published, school-verified achievements and the official leaderboard if the school chooses to publish it.
10. **School fees vs platform sales:** School-fee payment records are for transparency and reconciliation. The school is the payee/merchant for school fees; the platform does not hold those funds or claim to be a party to the school's fee transaction. Platform subscriptions and course purchases are direct sales from the platform to the parent/teacher, and the platform provides customer support for those services.
11. **Cancellation/refund preference:** For completed, one-time fixed-term app access or course purchases, the intended default is no voluntary cancellation/refund after activation, subject to applicable law, mandatory payment-network/store rules, error correction and chargeback requirements. Do not implement “no cancellation” for an auto-renewing store subscription if the applicable store requires a cancellation path. Prefer non-auto-renewing fixed-term access if the product owner wants renewals to require a new purchase. Final terms require legal and storefront review.
12. **Child-data safeguard:** Ads are shown in the adult-facing Parent App, not to children in the Student App. However, that alone does not remove privacy duties for the child data processed by the app. Never use a child's grades, attendance, messages, health/support data, behaviour, transport/location data, or child profile to target ads. Obtain a qualified privacy review before launch.

---

# 1. Login, account and child linking

- [ ] **1.1 (P0)** Parents can sign in using a verified phone number or email.
- [ ] **1.2 (P0)** Parent identity can be verified through OTP, a school-issued invitation/QR, passkey or another approved low-friction method.
- [ ] **1.3 (P0)** If a verified phone/email matches an authorised guardian record, the system automatically links the eligible child/children without asking for repeated manual codes.
- [ ] **1.4 (P0)** If a match is uncertain, duplicated or disputed, the app requests school verification rather than revealing any child's information.
- [ ] **1.5 (P0)** An admission number, roll number or date of birth alone cannot prove that a person is a guardian.
- [ ] **1.6 (P0)** One parent account can securely access multiple linked children.
- [ ] **1.7 (P0)** Each child clearly shows the name, school, class/grade and link status.
- [ ] **1.8 (P0)** Each adult has a separate account and audit trail; parents are not encouraged to share passwords.
- [ ] **1.9 (P0)** The school controls what each parent, fee payer or caregiver may see or do for each child.
- [ ] **1.10 (P1)** An authorised grandparent or caregiver can receive restricted access, such as timetable-only access, where school policy allows it.
- [ ] **1.11 (P0)** Parents can verify/update their own contact information and submit corrections to official student information.
- [ ] **1.12 (P0)** Parents can review active sessions and revoke a lost device or log out all devices.
- [ ] **1.13 (P1)** Transfer, graduation and withdrawal update the parent's access while preserving records that must remain available.
- [ ] **1.14 (P0)** After the first successful login, an already trusted device may use a secure local session for offline viewing of permitted cached data; new sign-in and sensitive changes still require appropriate verification.

# 2. Home screen and daily overview

- [ ] **2.1 (P0)** The Home screen shows a summary card for every linked child.
- [ ] **2.2 (P0)** Parents can see the day’s timetable, attendance status, homework, upcoming tests and important notices.
- [ ] **2.3 (P0)** The screen highlights actions that need attention, such as a permission form, deadline or fee due.
- [ ] **2.4 (P0)** Urgent safety and school updates always outrank commercial content.
- [ ] **2.5 (P0)** Parents can open the original record by tapping a summary card.
- [ ] **2.6 (P1)** Parents can view a combined family calendar for all linked children.
- [ ] **2.7 (P1)** Parents can rearrange or hide non-critical Home cards; essential notices, payment status and security options remain discoverable.
- [ ] **2.8 (P0)** The app shows when information was last updated.
- [ ] **2.9 (P0)** Offline or stale information is visibly labelled; the app never pretends old information is live.

# 3. Timetable and school calendar

- [ ] **3.1 (P0)** Parents can view a child's daily and weekly timetable.
- [ ] **3.2 (P0)** Available class details include subject, start/end time, room/link and approved teacher information.
- [ ] **3.3 (P0)** Parents are notified when a material class or timetable change is published.
- [ ] **3.4 (P0)** Exams, tests, school holidays, trips, events, deadlines and parent meetings can appear in a calendar/list.
- [ ] **3.5 (P0)** School closures and significant changes are clearly distinguished from routine notices.
- [ ] **3.6 (P1)** Parents can set local reminders and add eligible events to their phone calendar.
- [ ] **3.7 (P1)** A recent timetable remains available offline with its last-sync time.
- [ ] **3.8 (P0)** Duplicate source events do not create duplicate alerts.

# 4. Homework and assignments

- [ ] **4.1 (P0)** Parents can see homework/assignments published for each child.
- [ ] **4.2 (P0)** An assignment shows the title, subject, teacher, instructions, assigned date and due date/time.
- [ ] **4.3 (P0)** Parents can open or download allowed attachments and teacher-provided learning resources.
- [ ] **4.4 (P0)** The app shows the status supplied by the school, such as assigned, submitted, evaluated, returned or overdue.
- [ ] **4.5 (P0)** Parents can filter work by due date, subject and status and set reminders.
- [ ] **4.6 (P1)** Published marks, rubric feedback and teacher comments can be viewed when the school releases them.
- [ ] **4.7 (P1)** Parents can ask the responsible teacher a question where school policy permits.
- [ ] **4.8 (P0)** Opening/downloading an assignment never falsely marks it as submitted.

# 5. Exams, marks and report cards

- [ ] **5.1 (P0)** Parents can see exam dates, subjects, instructions and available syllabus/topics.
- [ ] **5.2 (P0)** Parents can view published marks and grades with maximum marks, scale and term context when available.
- [ ] **5.3 (P0)** Official report cards can be viewed and downloaded as PDF when released by the school.
- [ ] **5.4 (P0)** Parents receive a notice when a result is published for their child.
- [ ] **5.5 (P0)** Unpublished, withheld or restricted results stay hidden everywhere, including APIs, notifications, cache and file links.
- [ ] **5.6 (P1)** Parents can compare results across terms/assessments when the scales are comparable.
- [ ] **5.7 (P1)** Parents can ask about a published result or request a teacher meeting.
- [ ] **5.8 (P0)** Free parents retain a path to view and download official core school records. An eligible ad may appear at the document transition, but an ad failure, network error or lack of inventory must not permanently block the record.

# 6. Attendance and leave requests

- [ ] **6.1 (P0)** Parents can view daily and, where available, period attendance: present, absent, late or other school-defined status.
- [ ] **6.2 (P0)** Attendance history can be filtered by date range.
- [ ] **6.3 (P0)** Absence alerts follow the school's chosen confirmation rules and avoid duplicates.
- [ ] **6.4 (P0)** Corrections are reflected clearly and the app can show that the record was updated.
- [ ] **6.5 (P1)** Parents can submit a leave request/absence explanation with dates, reason and permitted attachments.
- [ ] **6.6 (P1)** Parents can see if a request is pending, approved, rejected or needs more information.
- [ ] **6.7 (P1)** Parents can report an attendance mistake and track the school's resolution.
- [ ] **6.8 (P1)** Attendance totals and school-defined thresholds can be shown with calculation context.
- [ ] **6.9 (P0)** A leave request does not automatically change the official attendance status.
- [ ] **6.10 (P0)** Medical/wellbeing records appear only to authorised guardians and never feed advertising targeting.

# 7. Child Development, Portfolio and Analysis

- [ ] **7.1 (P0)** A child-specific growth view can bring together published results, teacher feedback, portfolios and verified achievements where the school supplies them.
- [ ] **7.2 (P0)** Subject trends can be shown in simple charts with links to the source assessments and dates.
- [ ] **7.3 (P1)** Approved teacher observations may describe strengths and next steps in supportive language.
- [ ] **7.4 (P0)** The school can publish photos, videos, projects, certificates and other learning artefacts for the authorised family.
- [ ] **7.5 (P0)** School-verified sports, arts, competition and extracurricular achievements can be displayed.
- [ ] **7.6 (P0)** Parents can download school-issued certificates and achievement records.
- [ ] **7.7 (P0)** Parents **cannot submit external certificates or achievements** for inclusion.
- [ ] **7.8 (P0)** If the school publishes an official leaderboard, parents can view that official leaderboard subject to the school's permissions. The app must not invent a ranking or create an unapproved public leaderboard.
- [ ] **7.9 (P0)** There is no automatic harmful labelling, diagnosis, prediction or default peer ranking of children.
- [ ] **7.10 (P0)** For a non-subscribed parent, every fresh entry to this value-added section opens a clear access choice: paid entitlement or ad-supported access for that visit.
- [ ] **7.11 (P0)** A parent who chooses the ad-supported path sees a clearly identified, policy-compliant ad experience; once the section is open, ordinary in-section navigation does not repeatedly prompt for ads.
- [ ] **7.12 (P0)** A subscribed parent skips the ad/upgrade choice and sees the section directly.
- [ ] **7.13 (P0)** If an ad cannot load, the UI handles the no-fill/offline case explicitly and does not crash or loop. Core school records remain available outside this value-added module.
- [ ] **7.14 (P0)** The monetisation choice is controlled by the platform entitlement/feature configuration and is not inferred from a child's academic or sensitive data.

# 8. Notices, messages and school communication

- [ ] **8.1 (P0)** Parents can see official notices with sender, publish date/time, audience, priority, expiry, attachments and required action where relevant.
- [ ] **8.2 (P0)** Notices remain searchable in an archive according to school retention policy.
- [ ] **8.3 (P1)** The school can require read acknowledgements; delivered, opened and acknowledged are shown as different states.
- [ ] **8.4 (P0)** Parents can have secure, permission-checked conversations with approved teachers or school staff.
- [ ] **8.5 (P1)** Messages show expected reply windows, teacher availability and school quiet hours where configured.
- [ ] **8.6 (P1)** Parent-selected languages and translation can be supported, with the original message retained and machine translations clearly labelled.
- [ ] **8.7 (P1)** Parents can review and respond to consent forms, event RSVPs and meeting invitations.
- [ ] **8.8 (P1)** Parents can view authorised school contacts and book available teacher meeting slots.
- [ ] **8.9 (P0)** Parents can report abuse, a mistaken recipient, account compromise, a privacy concern or school-service issue and track a ticket.
- [ ] **8.10 (P0)** Push payloads contain minimal sensitive information and open the correct child/record only after app access checks.

# 9. School fees and payment records

- [ ] **9.1 (P0)** Parents can view itemised school fees for each child, including period, due date, discounts/concessions, late fees if applicable, amount paid and balance.
- [ ] **9.2 (P0)** Upcoming, overdue, partially paid, waived and disputed items are distinguished using the school's source records.
- [ ] **9.3 (P0)** Eligible school payments can be initiated through the school's configured gateway or documented payment route.
- [ ] **9.4 (P0)** Before a payment, the app shows the school/payee, child allocation, fee heads and total.
- [ ] **9.5 (P0)** Payment statuses distinguish initiated, pending, paid, failed, cancelled, refunded, partially refunded and under review where supported.
- [ ] **9.6 (P0)** A payment-app return screen by itself never marks school fees as paid; the app waits for verified gateway/school reconciliation.
- [ ] **9.7 (P0)** Parents can view payment history and download school-issued receipts/invoices when available.
- [ ] **9.8 (P1)** A family-level summary can show fees across multiple children; a combined checkout is allowed only if supported and each child/fee line is reconciled separately.
- [ ] **9.9 (P0)** Parents can report a missing receipt, duplicate debit or mismatch and receive a ticket/reference.
- [ ] **9.10 (P0)** The school is clearly named as the fee payee/merchant. The app/platform does not hold school-fee funds or present itself as the party providing the school's education service.
- [ ] **9.11 (P0)** The platform's role is limited to the software workflow, records, status display and technical support for platform defects/synchronisation. School fee rules, fee balances, payee decisions and school-side disputes remain with the school; payment processing belongs to the configured provider. Contract wording must be reviewed before launch.
- [ ] **9.12 (P0)** A parent-paid platform subscription or course purchase is not mixed into the school fee ledger and does not receive a school-fee receipt.
- [ ] **9.13 (P2)** Voluntary recurring payment mandates are not enabled unless separately approved and supported by provider rules.

# 10. Documents and certificates

- [ ] **10.1 (P0)** Parents have one searchable place for report cards, certificates, circulars, receipts, invoices and school letters.
- [ ] **10.2 (P0)** Documents can be filtered by child, type, academic year and date where metadata exists.
- [ ] **10.3 (P0)** A permitted parent can securely view, download and share official files using the device's share sheet.
- [ ] **10.4 (P0)** Private document links expire or are checked for current authorisation; copied URLs do not bypass access revocation.
- [ ] **10.5 (P1)** Corrected/replaced documents show the current official version and preserve required audit history.
- [ ] **10.6 (P1)** Expiring passes/consents show their validity period and expired state.
- [ ] **10.7 (P0)** For free parents, eligible document-entry ad placements can run before opening or after returning from a document flow, never inside the document itself.
- [ ] **10.8 (P0)** Document ads are frequency-capped, do not appear immediately before/after an App Open ad, and are skipped if unavailable so essential records remain usable.
- [ ] **10.9 (P0)** The app never places ads over emergency instructions, a payment confirmation, private consent content or sensitive health/support documents.

# 11. Course store — built but disabled until launch is approved

- [ ] **11.1 (P0 for architecture; inactive at launch)** Course catalogue, purchase, order and entitlement capability is designed behind a server-controlled feature flag.
- [ ] **11.2 (P0)** The default setting is disabled; course entry points, catalogues and purchase APIs are invisible/unavailable to parents while disabled.
- [ ] **11.3 (P1)** When enabled, parents can browse free/paid mini-courses by grade, board, subject, topic, language, difficulty and duration.
- [ ] **11.4 (P1)** Course details show outcomes, syllabus, instructor/provider, preview, price, access period, device/data needs and applicable terms.
- [ ] **11.5 (P1)** Before purchase, the parent explicitly selects the child who will receive the course.
- [ ] **11.6 (P1)** Payment is verified before a purchase entitlement is recorded.
- [ ] **11.7 (P1)** The purchased course entitlement is intended for activation in the **Student App**, which will be built later. The Parent App must not pretend the course is activated for the child until the Student App integration confirms it.
- [ ] **11.8 (P1)** The backend can store a pending entitlement with a stable purchase reference until Student App activation exists.
- [ ] **11.9 (P1)** The course library, progress, quizzes, bookmarks and certificates can be added when the Student App/course player is ready.
- [ ] **11.10 (P0 when commerce launches)** Merchant identity, app-store/payment rules, support ownership and purchase terms are shown before purchase.
- [ ] **11.11 (P0 when commerce launches)** Default commercial policy for a completed one-time purchase is no voluntary cancellation/refund after activation, subject to applicable law, mandatory store/provider rules, duplicate/incorrect charges and payment dispute obligations. Final wording must be legally reviewed.
- [ ] **11.12 (P0 when commerce launches)** The checkout must use the payment method required by the relevant mobile storefront's rules for digital content; this is a launch gate, not an assumption.

# 12. Parent subscription, ads and monetisation

- [ ] **12.1 (P0)** A parent who does not pay can still use the essential school app through a free ad-supported experience.
- [ ] **12.2 (P0)** Parents who have an active platform-paid entitlement get the benefits defined for that entitlement and do not see ads covered by that entitlement.
- [ ] **12.3 (P0)** Parent subscription price, duration, benefits, payment provider and storefront billing route are configurable; do not guess a price not yet approved for the Parent App.
- [ ] **12.4 (P0)** Subscription checkout clearly discloses price, duration, whether it renews automatically, what is included and where terms apply.
- [ ] **12.5 (P0)** The platform supports Google AdMob integration for the Parent App only; the future Student App is not to show these Parent App ads.
- [ ] **12.6 (P0)** App Open ads can appear on eligible app starts/resumes, using Google's intended loading-screen placement and a configurable frequency cap.
- [ ] **12.7 (P0)** Report-card/certificate/document ads use an approved transition placement, never the document canvas itself.
- [ ] **12.8 (P0)** Child Development/Portfolio/Analysis offers an explicit “paid access” or “ad-supported for this visit” choice on each fresh section entry for a non-subscribed parent.
- [ ] **12.9 (P0)** Do not stack an App Open ad immediately before/after a document or section-entry ad. Use global timing/frequency controls.
- [ ] **12.10 (P0)** Never show ads in emergency alerts, private message threads, report-card/document content, payment checkout/receipt, consent forms, security screens or sensitive records.
- [ ] **12.11 (P0)** Ads are clearly labelled and visually distinct from official school content. They cannot imitate school messages, system notices or buttons.
- [ ] **12.12 (P0)** No ad targeting may use grades, attendance, health/disability/wellbeing information, private messages, school/transport location or behavioural profiles of children.
- [ ] **12.13 (P0)** Store the ad consent/preference state separately from essential school-service settings; apply the appropriate consent/privacy controls for launch markets.
- [ ] **12.14 (P0)** Use Google's test ad IDs in development/QA. Never test with live production ad clicks.
- [ ] **12.15 (P0)** If an ad fails to load or the device is offline, handle the failure gracefully. Do not crash, spin forever or block essential school records.
- [ ] **12.16 (P0)** Define paid access as either a one-time fixed-term entitlement or a subscription with a compliant cancellation path. If auto-renewing subscriptions are sold through Google Play, do not remove the required online cancellation mechanism.
- [ ] **12.17 (P0)** Platform preference: no voluntary refund/cancellation for completed one-time fixed-term access, subject to mandatory legal, app-store, payment-provider and chargeback requirements. Do not state “no refunds under any circumstances.”
- [ ] **12.18 (P0)** App subscription and course purchases are paid to the platform, not the school. The platform owns customer support for its subscription/course service and must provide receipts, transaction status and purchase support.
- [ ] **12.19 (P0)** School fee payment records remain separate and state clearly that the school is the payee and source of the school fee balance.
- [ ] **12.20 (P0)** Confirm the app's actual store-audience classification and AdMob eligibility before enabling App Open ads. If the app is subject to Google Play's Designed for Families restrictions, use an ad format permitted for that classification instead.

# 13. Google Drive backup and phone storage management

- [ ] **13.1 (P1)** Parents can explicitly opt in to a Google Drive app backup and disconnect the Google account later.
- [ ] **13.2 (P1)** Backup is scoped to the logged-in parent's own settings, permitted app state, recent authorised cached records and selected downloaded documents; it never backs up the whole school's database or any other family's information.
- [ ] **13.3 (P1)** Backup does not include passwords, authentication tokens, active session secrets or payment credentials.
- [ ] **13.4 (P1)** Backups are encrypted before upload, have an integrity check/version marker and use least-privilege Drive access.
- [ ] **13.5 (P1)** The app can perform a manual backup and, if supported and opted into, a scheduled/automatic backup when a suitable connection exists.
- [ ] **13.6 (P1)** Parents can see backup status, last successful backup time, backup size and any failure reason.
- [ ] **13.7 (P1)** After installing the app on a replacement phone and verifying the same parent account, the parent can restore the permitted backup and re-sync current school records.
- [ ] **13.8 (P0)** Restoring a backup never bypasses current guardian permissions, school unlinking, record publication rules or server-side authorisation.
- [ ] **13.9 (P1)** The app can reduce local storage use by managing downloaded files, clearing disposable cache, using thumbnails and allowing parents to control retained downloads.
- [ ] **13.10 (P1)** Before deleting a local copy, the UI distinguishes “remove from this phone” from “delete from school records” or “delete backup.”
- [ ] **13.11 (P1)** Document the Google Drive implementation choice: `appDataFolder` provides app-private hidden storage that is not visible in Drive's normal file list; use a visible user-selected folder only if broader Drive permissions and their review are approved.
- [ ] **13.12 (P0)** Backup remains optional and must not be required for the app's core use. The school's local/hosted services remain the authoritative source of school records.

# 14. Transport and family logistics — disabled until activated

- [ ] **14.1 (P0 for architecture; inactive at launch)** Transport feature is behind a server-controlled PHP/backend feature flag and defaults to off.
- [ ] **14.2** While disabled, transport screens, tracking APIs and related alerts are not visible/available to parents.
- [ ] **14.3 (P1 after activation)** If an authorised school/transport feed exists, parents can view route/vehicle status and relevant delay/departure/arrival alerts.
- [ ] **14.4 (P1 after activation)** Stale GPS is labelled; the app does not invent live status or ETAs when the source is unavailable.
- [ ] **14.5 (P1 after activation)** Pickup contacts and pickup permission changes follow school verification/approval rules.
- [ ] **14.6 (P2)** Library, canteen, shop and other school-service integrations are shown only when their authoritative data source is enabled.

# 15. Optional AI parent assistant — disabled and paid when activated

- [ ] **15.1 (P0 for architecture; inactive at launch)** The AI assistant is disabled by default and has no visible parent entry point until a PHP/backend feature flag enables it.
- [ ] **15.2 (P1 after activation)** It is treated as a paid value-added service, with price/entitlement configured by the platform.
- [ ] **15.3 (P1 after activation)** It answers only from school records and approved resources the current guardian is allowed to access.
- [ ] **15.4 (P1 after activation)** Answers cite their source and freshness; missing/stale/conflicting information is stated clearly.
- [ ] **15.5 (P0)** It must not diagnose learning/medical conditions, predict a child's potential or create unsupported negative labels.
- [ ] **15.6 (P0)** Tenant, guardian and sibling permissions are checked before retrieval; child-identifying information sent to any model is minimised.

# 16. User interface, visual design and ease of use

- [ ] **16.1 (P0)** Keep the current good components and existing colour scheme unless accessibility testing identifies a real issue.
- [ ] **16.2 (P0)** Reduce the oversized logo. The logo should not consume roughly 15% of the screen height on normal app pages; reserve larger branding for a brief splash/launch view only.
- [ ] **16.3 (P0)** Add persistent bottom navigation with a maximum of five primary destinations: **Home, Learning, Inbox, Payments, Explore**. Put Account/Settings under a clearly visible profile/avatar entry unless usability testing proves a different layout is better.
- [ ] **16.4 (P0)** Keep a persistent child selector on child-specific screens, showing the active child's name and school/class context.
- [ ] **16.5 (P0)** Make common tasks require as few taps as practical: open timetable, check homework, view notices, check fees and open/download a document should be available within a small number of predictable steps.
- [ ] **16.6 (P0)** Use a calm background, readable typography, consistent spacing and sufficient contrast. Avoid large blocks of saturated colour, unnecessary animation and crowded screens.
- [ ] **16.7 (P0)** Use consistent icons, labels and navigation patterns. Do not rely on colour alone to distinguish children, statuses or actions.
- [ ] **16.8 (P0)** Touch targets, font scaling, screen-reader labels and form errors remain accessible, especially for payment and consent flows.
- [ ] **16.9 (P0)** Show clear loading, empty, offline, stale-data, error and retry states rather than blank screens.
- [ ] **16.10 (P0)** Ads have visibly labelled, dedicated placements and must not be confused with school content or navigation controls.
- [ ] **16.11 (P0)** Maintain consistent design across Android and iOS while respecting native navigation, permissions and share/download behaviour.

# 17. Settings, privacy, security and support

- [ ] **17.1 (P0)** Parents can configure notification preferences by category and, where appropriate, by child.
- [ ] **17.2 (P0)** Parents can choose an available app language, adjust text size and use accessibility features.
- [ ] **17.3 (P0)** Optional biometrics make login easier but do not replace server-side access checks.
- [ ] **17.4 (P0)** Parents can inspect/revoke device sessions and recover access securely.
- [ ] **17.5 (P0)** The app includes a plain-language privacy page explaining school-data access, Drive backup, advertising and platform purchases separately.
- [ ] **17.6 (P0)** Parents can submit privacy/access/correction/deletion requests where applicable and can track their status.
- [ ] **17.7 (P0)** Retention or deletion requests account for records the school or platform is legally required to retain.
- [ ] **17.8 (P0)** Parents can contact support about login, child linking, record visibility, payments, backup/restore, ads and platform purchases.
- [ ] **17.9 (P0)** Every support request has a reference ID, status and appropriate escalation path.
- [ ] **17.10 (P0)** Access to academic, attendance, fee, health, message and guardian records is authorised on every API/file request, not merely hidden in the UI.
- [ ] **17.11 (P0)** Sensitive actions and record changes have timestamped audit trails with role-appropriate visibility.
- [ ] **17.12 (P0)** Use synthetic data for testing. No real student data or secrets may be put in development logs, demo accounts or public test files.

# 18. Local-first architecture, sync and service limits

- [ ] **18.1 (P0)** When the phone is on the school's local network, it connects securely to the local School Hub.
- [ ] **18.2 (P0)** When the parent is off-site, approved remote requests go through the hosted PHP/MySQL relay; a private LAN address is not assumed to be reachable over the internet.
- [ ] **18.3 (P0)** The local school database is authoritative for school operations and official student, attendance, academic and fee records.
- [ ] **18.4 (P0)** School staff can continue supported local operations during an internet outage; mobile clients display cached data and last-sync labels where appropriate.
- [ ] **18.5 (P0)** Parent requests made offline are queued only when safe; they show pending/synced/failed states and are revalidated by the server before final acceptance.
- [ ] **18.6 (P0)** Sync uses versioned interfaces, stable record IDs, timestamps/version markers, idempotency and retry logic to avoid duplicate actions.
- [ ] **18.7 (P0)** Conflicts are surfaced and resolved by defined rules; the parent app never silently overwrites official school records.
- [ ] **18.8 (P0)** Permission revocation is enforced on the next successful server check; cached data is limited, protected and removed/expired according to security rules.
- [ ] **18.9 (P0)** Firebase Spark may supplement the app only where appropriate; core operations do not depend on paid Firebase products.
- [ ] **18.10 (P0)** Each school's hosted storage is limited to 50 GB maximum, with monitoring, per-school quotas and clear warnings as storage approaches its limit.
- [ ] **18.11 (P0)** Large media/documents use compression, size limits, pagination and secure temporary downloads where supported.
- [ ] **18.12 (P0)** Backups and restore tests cover both the local school database and the parent app's separate, optional Drive backup.
- [ ] **18.13 (P0)** Monitoring records sync failures, payment reconciliation errors, document access errors and service health without logging unnecessary child information.

# 19. Acceptance tests before release

- [ ] **19.1** A correctly verified guardian is automatically linked to all unambiguous matching children; an uncertain match is sent for school review.
- [ ] **19.2** A caregiver with schedule-only access cannot open marks, fees, private messages or another child's profile.
- [ ] **19.3** The app shows accurate stale/offline labels and does not erase valid cache after a failed refresh.
- [ ] **19.4** A parent request retried after a timeout does not create duplicate records, duplicate payments or duplicate consent submissions.
- [ ] **19.5** The school fee ledger, gateway callback and receipt reconcile correctly; opening a payment return URL alone cannot mark the fee as paid.
- [ ] **19.6** A document URL cannot be reused after expiry or permission revocation.
- [ ] **19.7** Free-parent startup ads use test units in QA and obey frequency caps; premium entitlements suppress covered ads.
- [ ] **19.8** Document-entry ads do not obscure or become part of report cards/certificates, do not stack with App Open ads, and essential documents remain reachable when ads fail.
- [ ] **19.9** Child Development shows the access choice on each fresh entry for a non-subscriber but does not repeat it for every tap inside the section.
- [ ] **19.10** Course, transport and AI features are invisible and unavailable while their backend feature flags are off; enabling a flag exposes only the approved feature.
- [ ] **19.11** A future course purchase is linked to the selected child and is not described as activated in the Student App before that app confirms activation.
- [ ] **19.12** A Drive backup restores only the same parent’s permitted app data, then re-checks current child/record permissions with the server.
- [ ] **19.13** Deleting local cache is not confused with deleting school records or the Drive backup.
- [ ] **19.14** Visual review confirms the logo no longer dominates the first screen, bottom navigation is present, and core tasks use a small number of steps.
- [ ] **19.15** There are no unresolved critical/high-severity tenant-isolation, guardian-access, document-access, payment-integrity or secret-exposure findings.
- [ ] **19.16** Legal/privacy review and the mobile-store policy review are recorded before production use with real student data or live monetisation.
- [ ] **19.17** The store audience classification and AdMob eligibility are verified; the app uses no ad format disallowed for that classification.

---

# 20. Decisions/configuration that must remain explicit

These values must be controlled by configuration and not guessed by Codex:

- Parent subscription price, term/duration, benefits and purchase provider.
- Whether parent app access is a one-time fixed-term purchase or an auto-renewing subscription. The cancellation flow must follow the applicable store rules.
- Ad frequency caps, eligible App Open triggers, document-entry ad rules, paid ad-free entitlements, and handling when no ad is available.
- Course catalogue/purchase feature flag (default **off**).
- Transport feature flag (default **off**).
- AI assistant feature flag (default **off**) and its paid entitlement rules.
- Google Drive backup opt-in default, backup schedule, retention count, encryption/key recovery model and whether app-private hidden storage or a user-visible Drive folder is selected.
- Exact data cached offline and how long it remains available after guardian access is revoked or cannot be refreshed.
- The school's actual merchant/payee and payment integration for school fees.
- Applicable app-store billing route for digital subscriptions and course purchases in each market.

# 21. Codex implementation instruction

Use this checklist as the user's approved Parent App feature contract. Inspect the existing implementation before changing code. Preserve all features not explicitly changed here. For each checkbox, report **Implemented / Partial / Missing / Not tested**, with file paths and test evidence. Implement the approved changes incrementally, with the smallest safe code changes possible.

Do not:
- expose disabled Course, Transport or AI capabilities before their PHP/backend feature flags are enabled;
- let the parent upload external certificates;
- invent prices, billing periods, payment states or entitlements that have not been configured;
- claim that a school fee payment is confirmed until the authoritative gateway/school source confirms it;
- use children's grades, attendance, health data, messages or location to target advertisements;
- store authentication/payment secrets in Drive backups;
- remove mandatory app-store cancellation/refund handling or legal rights;
- mark a feature verified merely because its screen exists.

First produce a feature-by-feature gap report. Then fix the UI/navigation, guardian linking, parent-only monetisation, optional Drive backup and server-controlled feature flags, with automated tests and documented limitations.

# 22. Reference notes for implementation review

- Google AdMob App Open ads are designed for loading/splash transitions and require frequency and placement controls. Avoid stacking immediately adjacent ad placements. App Open ads are not eligible for apps within Google Play's Designed for Families program, so check the app's actual audience classification. https://support.google.com/admob/answer/9341964
- Google recommends interstitial ads at natural transition points and instructs developers to use test ads during development. https://developers.google.com/admob/android/interstitial
- Google Drive `appDataFolder` is app-specific hidden storage, not visible in the user's normal Drive file list; it differs from visible Drive backup folders. https://developers.google.com/workspace/drive/api/guides/appdata
- Google Play requires an easy online method to cancel subscriptions where its subscriptions policy applies. https://support.google.com/googleplay/android-developer/answer/9900533
- India's DPDP Act contains restrictions concerning targeted advertising directed at children; whether particular provisions apply and when must be verified with qualified counsel. An adult-facing UI is not by itself proof that no child-data obligations apply. https://www.indiacode.nic.in/bitstream/123456789/22037/1/a2023-22.pdf
- Official DPDP Rules and enforcement timeline: https://www.meity.gov.in/documents/act-and-policies/digital-personal-data-protection-rules-2025-gDOxUjMtQWa

**Important:** This checklist is product direction, not legal advice. Validate advertising, privacy, payment, refund and storefront terms before release.
