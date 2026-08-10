// local-payments — server-side proxy for CREATING a payment.
// =============================================================================
// POST /api/payments — runs on the Next.js server (the i18n middleware skips /api),
// so it can reach the internal .NET backend the browser cannot. Maps the backend's
// status codes straight through (201 created, 400 validation, 502 provider error,
// 503 not configured). Amount is in the currency minor unit (e.g. halalas).
// =============================================================================
import { NextResponse } from 'next/server';
import { createPayment } from '../../../lib/payments';

export const dynamic = 'force-dynamic';

export async function POST(request) {
  let body;
  try { body = await request.json(); } catch { body = {}; }

  const res = await createPayment({
    amount: Number(body.amount),
    currency: body.currency ? String(body.currency) : undefined,
    description: body.description ? String(body.description) : undefined,
  });

  return NextResponse.json(res.data ?? {}, { status: res.status });
}
