# Parent mobile app guide

Parents can use the app with a phone paired to the local school Hub or with a hosted account when the school has connected its Hub to the PHP backend. Hosted access shows only students the operator/school has explicitly linked to the parent account.

## Connect and sign in

### Local school connection

Ask the school office for a one-use pairing code, join the school's Wi-Fi, choose **Connect your school**, and enter the code. Sign in using the parent account created by the school. The pairing code expires after five minutes and can only be used once.

### Hosted school connection

Enter the school's HTTPS API address ending in `/api/v1` and the school ID if the app asks for it. Sign in with the parent account. If no child appears, ask the school office to link your account to the correct child; the app cannot add that access itself. Hosted information is the last student snapshot received by the server and can be refreshed when the server is reachable.

## Use the app

- **Children:** choose an authorized child and review the school summary.
- **Learning:** check the attendance, homework, timetable and published results included in the school's latest sync.
- **Fees:** review invoices and recorded payments. The app does not currently process a fee payment; contact the school for payment instructions.
- **Notices:** read the full notice and acknowledge it if the school requests acknowledgement. A push alert carries only a generic message; open this page to read school content.
- **Requests:** submit a leave, profile/document or other request and review its status. Requests are saved on the device before transmission and remain queued during an outage.

When using the local connection, keep the app open on the school Wi-Fi for queued requests to reach the Hub. Hosted Parent requests first reach the backend and then wait for the school's Hub relay poll. The app retries in the foreground; background delivery is not scheduled.

## Keep your account safe

Use your own login, keep the phone locked, and sign out on a shared device. The app stores an account-separated local cache to support offline viewing, but the cache is not encrypted by this implementation. If a child is missing or information looks out of date, contact the school office and refresh after reconnecting.
