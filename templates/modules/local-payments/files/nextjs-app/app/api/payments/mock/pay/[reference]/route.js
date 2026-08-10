// local-payments — server-side proxy for the MOCK simulate-pay action.
// =============================================================================
// POST /api/payments/mock/pay/<reference> — proxies to the .NET backend, which (for
// the mock provider) emits an HMAC-signed webhook to itself and records the payment
// as paid. Returns 404 from the backend if the active provider is not the mock.
// =============================================================================
import { NextResponse } from 'next/server';
import { mockPay } from '../../../../../../lib/payments';

export const dynamic = 'force-dynamic';

export async function POST(request, { params }) {
  const { reference } = await params;
  const res = await mockPay(reference);
  return NextResponse.json(res.data ?? {}, { status: res.status });
}
