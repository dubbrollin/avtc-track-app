# Team payment portals — how to switch it on

Each team collects its **own** club fee from parents inside the app. Parents can pay:

- **By card** through the team's own Stripe account (the money lands in the team's bank account; the team pays Stripe's card fee, about 2.9% + 30¢). In full, or on a **payment plan**: a deposit today, then equal monthly payments charged to the saved card automatically. A failed monthly payment is flagged and the parent is asked for a new card.
- **Another way the team accepts** — Zelle, Cash App, Venmo, check or cash. The parent taps "I sent it"; the team admin confirms when it arrives.

Conference fees (team → VYC, on the Fees & Fines tab) are unchanged. This is parent → team.

## What's in the build

| Piece | File |
| --- | --- |
| Database: settings per team, Stripe account per team, one fee per athlete, payment history, team-admin functions | `supabase/2026-10-05-team-payments.sql` |
| Team admin sets up / checks their Stripe account | `supabase/functions/team-stripe/index.ts` |
| Parent starts a card payment (full, plan deposit, or new card) | `supabase/functions/fee-checkout/index.ts` |
| Stripe reports what happened; the only thing that writes card payments | `supabase/functions/stripe-webhook/index.ts` |
| Parent pay page (linked from the registration confirmation; no login needed) | `pay.html`, `payments.js` |
| Parent Dashboard: balance + pay buttons under each athlete | `parent.html` |
| Registration confirmation: fee + "Pay now" link | `index.html` |
| Admin page → **Payments** tab: Stripe setup, fee settings, ways to pay, confirm Zelle/check payments, record payments, adjust/waive, copy pay link | `admin.html` |

## One-time setup (Riley)

### 1. A Stripe account for VYC (the "platform")

This account never holds parents' money — it only lets each team create its own Stripe account through the app.

1. Create (or sign in to) a Stripe account for **Valley Youth Conference** at https://dashboard.stripe.com/register.
2. In that dashboard go to **Connect** (left menu) → **Get started** → choose **Platform or marketplace**. Answer the questionnaire (youth sports league; the teams are the businesses accepting payments; Stripe collects fees from them). Complete VYC's own business verification when Stripe asks.
3. **Developers → API keys → Create restricted key**, name it `vyc-track-app`, and allow **Write** on: Checkout Sessions, Customers, Payment Intents, Setup Intents, Subscriptions, Products, Prices, Invoices, Connect (Accounts) and **Read** on everything else. Copy the key (`rk_live_…`). Use **test mode** keys first (`rk_test_…`) to practise.

### 2. Put the key into Supabase and publish the three functions

From a terminal in the app folder (`C:\Users\avtra\Cowork Projects\outputs\App Building\track app\avtc-track-app`):

```bash
npx.cmd supabase secrets set STRIPE_SECRET_KEY=rk_test_PASTE_HERE APP_URL=https://dubbrollin.github.io/avtc-track-app --project-ref qwwmissmsrpfjrsqditi --agent no
```

```bash
npx.cmd supabase functions deploy team-stripe --use-api --project-ref qwwmissmsrpfjrsqditi --agent no
```

```bash
npx.cmd supabase functions deploy fee-checkout --no-verify-jwt --use-api --project-ref qwwmissmsrpfjrsqditi --agent no
```

```bash
npx.cmd supabase functions deploy stripe-webhook --no-verify-jwt --use-api --project-ref qwwmissmsrpfjrsqditi --agent no
```

(`fee-checkout` and `stripe-webhook` are opened without a login on purpose: a parent pays straight from the confirmation page, and Stripe calls the webhook. Both check their own proof — the registration's email, and Stripe's signature.)

### 3. Tell Stripe where to send events

In the VYC Stripe dashboard: **Developers → Webhooks → Add endpoint**.

- Endpoint URL: `https://qwwmissmsrpfjrsqditi.supabase.co/functions/v1/stripe-webhook`
- **Listen to: Events on Connected accounts** (not "your account")
- Events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`, `invoice.paid`, `invoice.payment_failed`, `customer.subscription.deleted`, `charge.refunded`
- Save, then copy the **Signing secret** (`whsec_…`) and store it:

```bash
npx.cmd supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_PASTE_HERE --project-ref qwwmissmsrpfjrsqditi --agent no
```

### 4. Run the database change

```powershell
& "C:\Users\avtra\Cowork Projects\outputs\App Building\track app\avtc-track-app\supabase\run-sql.ps1" -File "C:\Users\avtra\Cowork Projects\outputs\App Building\track app\avtc-track-app\supabase\2026-10-05-team-payments.sql"
```

Also run the parent meet sign-up change (team switch + "are you coming?" questionnaire). It doesn't need Stripe:

```powershell
& "C:\Users\avtra\Cowork Projects\outputs\App Building\track app\avtc-track-app\supabase\run-sql.ps1" -File "C:\Users\avtra\Cowork Projects\outputs\App Building\track app\avtc-track-app\supabase\2026-10-06-parent-meet-attendance.sql"
```

### 5. Publish the pages

`git push origin main` from the app folder (test push — same as every other update).

## How a team switches it on

1. Team admin signs in → Admin page → **Payments** tab.
2. **Set up Stripe for this team** → Stripe's form (bank account, responsible person, EIN or SSN) → Stripe sends them back to the Payments tab, which shows **Card payments ON ✓** when Stripe is satisfied. (If Stripe wants more, the tab says "Action needed" with a "Continue Stripe setup" button.)
3. Enter the **fee per athlete**, optional sibling discount, what it covers, tick the ways to pay they accept (with the Zelle / Cash App / Venmo details), optionally the payment plan (deposit, number of monthly payments, first date) → **Save**.
4. Press **Add the fee to athletes who don't have one** for anyone who registered before step 3. New registrations get the fee automatically.

Parents then see the fee and a **Pay now** link on their registration confirmation, on their pay link, and on the Parent Dashboard.

## Testing before real money

Use the Stripe **test mode** restricted key in step 2. Stripe's test onboarding lets you fill the team's form with test data (any name, SSN `000-00-0000`, bank routing `110000000` / account `000123456789`). Pay with card `4242 4242 4242 4242`, any future date, any CVC. Card `4000 0000 0000 0341` attaches but fails every charge — use it to see the "card failed → update my card" path on a payment plan. Switch to the live key when ready; the teams redo Stripe setup once in live mode.

## Not built (yet)

- Reminder emails before each monthly card charge, and emails when a Zelle/check payment is confirmed (needs an email service — Resend, like the salon app).
- Passing Stripe's card fee on to the parent as a line item (SportsEngine-style). Easy to add if teams ask.
- Refunding a card payment from inside the app — done in the team's Stripe dashboard for now; the app records it automatically.
- Valley United's $250 postseason fee still uses its own placeholder; it can be moved onto this system when the VUS page work starts.
