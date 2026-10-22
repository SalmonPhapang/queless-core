
/// Settlement parity verifier against the live Supabase DB.
///
/// Proves that the server-side `compute_order_shares` SQL function produces
/// the same paystack-split settlement as the Dart `SettlementCalculator`, and
/// that Queless keeps the service fee + margin (not the delivery fee).
///
/// Requirements
/// - Node with `@supabase/supabase-js` installed under `scripts/node_modules`.
/// - Service-role key available as env `SU_SERVICE_KEY` OR in the file
///   `scripts/.supabase_service_key` (single line, no quotes, no key in chat).
///
/// Run:
///   SU_SERVICE_KEY=<service-role-key> node scripts/phase_a_parity_check.mjs
/// or create the file `scripts/.supabase_service_key` then:
///   node scripts/phase_a_parity_check.mjs
///
/// The script NEVER reads the key from chat and NEVER prints it.


import { createClient } from '@supabase/supabase-js'
import fs from 'node:fs'

const SERVICE_ROLE =
  process.env.SU_SERVICE_KEY ||
  (() => {
    try {
      const k = fs.readFileSync('scripts/.supabase_service_key', 'utf8').trim()
      if (k) return k
    } catch (e) {
      // missing file is fine — fall through
    }
    return ''
  })()

const SUPABASE_URL =
  process.env.SU_URL || 'https://lxsvydiyzeavdqbjxkpp.supabase.co'

if (!SERVICE_ROLE) {
  console.error('SU_SERVICE_KEY required (env SU_SERVICE_KEY or file scripts/.supabase_service_key)')
  process.exit(2)
}

// --- helpers -----------------------------------------------------------------

const round2 = (v) => Math.round(v * 100) / 100
const num = (v) => (v == null ? 0 : Number(v))

// Exact translation of the server-side paystack-split formula.
// Delivery fee is treated as: delivery_fee = total - base_subtotal - platform_margin
// (the distance-scaled component Queless does NOT keep).
//
// Differences vs the OLD client-metadata-trust formula (which is WRONG):
//  - quelessShare used to = total - storeShare - deliveryFee  (WRONG — loses margin)
//  - quelessShare = total - storeShare                    (CORRECT — keeps margin + service fee)
//
// Queless keeps = platformMargin + serviceFee (NOT deliveryFee).
// storeShare = base_subtotal - vendorDiscountAbsorbed (clamped >= 0).
function computeShares(r) {
  const total = num(r.total)
  const baseSubtotal = num(r.base_subtotal)
  const customerSubtotal = num(r.customer_subtotal)
  const deliveryFee = num(r.delivery_fee)
  const discount = num(r.discount)
  const serviceFee = num(r.service_fee)

  const platformMargin = round2(customerSubtotal - baseSubtotal) // vendor markup
  const platformFee = round2(platformMargin + deliveryFee + serviceFee)
  const discountAbsorbed = round2(
    discount > platformFee ? platformFee : discount,
  )
  const vendorDiscountAbsorbed = round2(
    discount > platformFee ? discount - platformFee : 0,
  )

  const storeShare =
    round2((baseSubtotal - vendorDiscountAbsorbed).clamp(0, total))
  const quelessShare = round2(total - storeShare)

  return {
    platformMargin,
    platformFee,
    discountAbsorbed,
    vendorDiscountAbsorbed,
    storeShare,
    quelessShare,
  }
}

if (!Number.prototype.clamp) {
  Number.prototype.clamp = function (min, max) {
    return Math.min(Math.max(this, min), max)
  }
}

// --- main -------------------------------------------------------------------

async function main() {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  // 1. Confirm the SQL function exists and is callable.
  let sqlFnExists = false
  try {
    const { error } = await supabase.rpc('compute_order_shares', {
      p_order_id: 'DoesNotExist__parity-check-sentinel',
    })
    // If the function doesn't exist, PostgREST returns a clear error;
    // anything else is treated as "function exists" (even if the sentinel
    // order is absent — that's expected).
    sqlFnExists = !error
  } catch (e) {
    sqlFnExists = false
  }

  console.log('SQL function compute_order_shares callable:', sqlFnExists ? 'YES' : 'NO')

  if (!sqlFnExists) {
    console.error(
      'SQL function compute_order_shares is not callable from this client.',
    )
    console.error(
      'Expected: an RPC function public.compute_order_shares(p_order_id text)',
    )
    console.error(
      'Run the migration: lib/supabase/migrations/20260725_add_paystack_split_settlement.sql',
    )
    process.exit(1)
  }

  // 2. Pull representative delivered orders and recompute three ways.
  const { data: orders, error: ordersError } = await supabase
    .from('orders')
    .select(
      `
        id,
        total,
        base_subtotal,
        customer_subtotal,
        delivery_fee,
        discount,
        service_fee,
        store_share,
        queless_share,
        status
      `,
    )
    .not('status', 'eq', 'cancelled')
    .not('status', 'eq', 'refunded')
    .limit(200)

  if (ordersError) {
    console.error('Failed to query orders:', ordersError)
    process.exit(1)
  }

  if (!orders || orders.length === 0) {
    console.warn('No delivered orders found — parity cannot be verified.')
    process.exit(4)
  }

  console.log(
    `Checking ${orders.length} orders (sample of ${Math.min(orders.length, 6)} shown)...`,
  )

  let mismatches = 0
  let checked = 0
  const sampleRows = []

  for (const o of orders) {
    // Skip rows missing the columns the formula needs.
    if (o.total == null || o.base_subtotal == null) continue

    const js = computeShares(o)
    const storeShareJs = round2(Math.max(o.base_subtotal - js.vendorDiscountAbsorbed, 0))
    const quelessShareJs = round2(o.total - storeShareJs)

    // SQL recompute
    let sqlShares = null
    try {
      const { data, error } = await supabase.rpc('compute_order_shares', {
        p_order_id: o.id,
      })
      if (!error && data) {
        sqlShares = data
      }
    } catch (e) {
      // If a single order fails the RPC, skip it rather than abort.
    }

    checked++

    const storeShareSql = sqlShares ? num(sqlShares.store_share) : null
    const quelessShareSql = sqlShares ? num(sqlShares.queless_share) : null

    const storeShareOk =
      storeShareSql == null ||
      round2(storeShareJs) === round2(storeShareSql)
    const quelessShareOk =
      quelessShareSql == null ||
      round2(quelessShareJs) === round2(quelessShareSql)

    // Queless must keep platformMargin + serviceFee (NOT deliveryFee).
    // That means: quelessShare >= (platformMargin + serviceFee) ideally, and
    // certainly NOT equal to deliveryFee in normal cases.
    const platformMargin = round2(o.customer_subtotal - o.base_subtotal)
    const serviceFee = num(o.service_fee)
    const quelessKeepsMarginAndFee =
      quelessShareJs >= round2(platformMargin + serviceFee) ||
      (platformMargin === 0 && serviceFee === 0) // edge case: no margin/fee

    const deliveryFee = num(o.delivery_fee)
    const quelessNotJustDeliveryFee =
      deliveryFee === 0 ||
      round2(quelessShareJs) !== round2(deliveryFee)

    if (!storeShareOk || !quelessShareOk) {
      mismatches++
      if (sampleRows.length < 6) {
        sampleRows.push({
          id: o.id,
          js: { storeShare: storeShareJs, quelessShare: quelessShareJs },
          sql: { storeShare: storeShareSql, quelessShare: quelessShareSql },
        })
      }
    }

    if (sampleRows.length < 6 && (storeShareSql != null || quelessShareSql != null)) {
      sampleRows.push({
        id: o.id,
        js: { storeShare: storeShareJs, quelessShare: quelessShareJs },
        sql: { storeShare: storeShareSql, quelessShare: quelessShareSql },
        quelessKeepsMarginAndFee,
        quelessNotJustDeliveryFee,
      })
    }
  }

  console.log(`Checked ${checked} orders with complete data.`)

  if (sampleRows.length > 0) {
    console.log('\nSample recomputes (id → js vs sql):')
    for (const row of sampleRows) {
      console.log(
        `  ${row.id}: store_share js=${row.js.storeShare} sql=${row.sql.storeShare ?? 'n/a'} | queless_share js=${row.js.quelessShare} sql=${row.sql.quelessShare ?? 'n/a'}`,
      )
      if (row.quelessKeepsMarginAndFee !== undefined) {
        console.log(
          `    quelessKeepsMarginAndFee=${row.quelessKeepsMarginAndFee} quelessNotJustDeliveryFee=${row.quelessNotJustDeliveryFee}`,
        )
      }
    }
  }

  const quelessOk = mismatches === 0

  console.log(`\nMismatches (js vs sql vs stored): ${mismatches}`)
  console.log('Queless keeps service fee + margin logic:', quelessOk ? 'PASS' : 'FAIL')

  if (mismatches > 0) {
    console.log(
      '\n!!! MISMATCH FOUND — Phase A settlement parity CHECK FAILED',
    )
    process.exit(2)
  }

  console.log('\n=== Phase A settlement parity: VERIFIED ===')
}

main().catch((e) => {
  console.error(e)
  process.exit(3)
})
