# Parent mobile app guide

Parents can use the app with a phone paired to the local school Hub or with a hosted account when the school has connected its Hub to the PHP backend. Hosted access shows only students the operator/school has explicitly linked to the parent account.

## Connect and sign in

### Local school connection

Ask the school office for a one-use pairing code, join the school's Wi-Fi, choose **Connect your school**, and enter the code. Sign in using the parent account created by the school. The pairing code expires after five minutes and can only be used once.

### Hosted school connection

Enter the PHP service's HTTPS API address ending in `/api/v1`, enter the Google email recorded by the school, and verify that Google account. The parent app does not ask for the registered phone number during sign-in. The server still checks that the verified account has an active parent record linked to a child. The school controls every child link, and the app cannot grant itself access. Hosted information is the last student snapshot received by the server and can be refreshed when the server is reachable.

If the server has not completed its initial setup, the Parent app shows a message to contact the school administrator. Parents should not run the school-server setup flow.

## Use the app

- **Children:** choose an authorized child and review the school summary.
- **Learning:** check the attendance, homework, timetable and published results included in the school's latest sync.
- **Fees:** review invoices and recorded payments. The app does not currently process a fee payment; contact the school for payment instructions.
- **Notices:** read the full notice and acknowledge it if the school requests acknowledgement. A push alert carries only a generic message; open this page to read school content.
- **Requests:** submit a leave, attendance-correction, profile/document or other request and review its status. Requests are saved on the device before transmission and remain queued during an outage. An attendance-correction request identifies the child and date, but does not change the official attendance record; the school must review it.

Hosted parents can open **Explore** to enable or mute push alerts for school announcements, timetable/calendar changes and new homework. These category choices are saved by the PHP service and shared across the parent's verified school accounts. Muting a push category does not remove its records from the app. Push delivery still requires notification permission in the phone's settings; local Hub mode does not currently expose category controls.

Before signing in, parents can use **Need help signing in?** to send a login-access request with contact details to the operator. After signing in with the same verified Google email, that request can be tracked in Explore. Signed-in hosted parents can open **Explore → Help and support** for account access, child linking, school records, fees, backups, platform payments, ads or purchases, and may associate a request with a linked child. Requests receive a reference and status and appear in the central operator's support inbox; the operator can add a response visible in the app after refresh. Contact details on a pre-login request are unverified. Routing to a school or platform team is a manual operator handoff; new tickets and replies do not send email or push alerts.

Parents can also adjust app text size in **Explore → Account and preferences**. The setting is saved on the phone and combines with the phone's own text scaling and accessibility settings. App language selection is not available yet; the current interface is English-only.

The **Privacy and data** page in Explore describes the current release: school-controlled child links, the account-separated but currently unencrypted offline cache, the absence of Parent app Drive backup/restore, ads and in-app purchases, view-only school fee records, and the optional Firebase diagnostics consent. It is an implementation summary, not a substitute for the school’s privacy policy or legal review.

Use **Explore → Remove saved school information** to remove the hosted child and school snapshot from this phone and clear the currently displayed support-ticket list. This does not delete school records, change the account, or discard requests waiting to sync. Reconnect and refresh to download the current hosted information again. This control does not yet manage downloaded documents or clear a local School Hub cache.

From **Requests**, select a linked child and submit a data access, correction or deletion request. The school reviews it and the app shows its status. A deletion request never erases records automatically; school staff must check retention obligations and carry out any approved action through the school's process.

From **Requests**, choose a linked child and submit a data access, correction or deletion request. The school reviews it and its status appears in the app. Submitting or approving a deletion request does not erase records automatically; school staff must first check retention obligations and carry out any approved action through the proper school process.

When using the local connection, keep the app open on the school Wi-Fi for queued requests to reach the Hub. Hosted Parent requests first reach the backend and then wait for the school's Hub relay poll. The app retries in the foreground; background delivery is not scheduled.

## Keep your account safe

Use your own login, keep the phone locked, and open **Manage signed-in devices** to review or revoke mobile sessions. A verified parent identity can manage sessions created under its matching school accounts. The app stores an account-separated local cache to support offline viewing, but the cache is not encrypted by this implementation. If a child is missing or information looks out of date, contact the school office and refresh after reconnecting.
