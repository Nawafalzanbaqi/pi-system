// local-payments — server-side proxy for a payment's STATUS.
// =============================================================================
// GET /api/payments/<reference> — proxies to the internal .NET backend and returns
// the payment (or 404). Used by the return page's status panel.
// =============================================================================
import { NextResponse } from 'next/server';
import { getPayment } from '../../../../lib/payments';

export const dynamic = 'force-dynamic';

export async function GET(request, { params }) {
  const { reference } = await params;
  const res = await getPayment(reference);
  return NextResponse.json(res.data ?? {}, { status: res.status });
}
