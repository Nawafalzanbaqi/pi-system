// bookings — server-side proxy for LISTING a service's available slots.
// =============================================================================
// GET /api/bookings/slots?serviceId=<id> — runs on the Next.js server and proxies
// to the internal .NET backend. Always returns a JSON array (empty on any issue),
// so the client widget never has to special-case errors.
// =============================================================================
import { NextResponse } from 'next/server';
import { getSlots } from '../../../../lib/bookings';

export const dynamic = 'force-dynamic';

export async function GET(request) {
  const serviceId = new URL(request.url).searchParams.get('serviceId');
  if (!serviceId) return NextResponse.json([], { status: 200 });
  const slots = await getSlots(serviceId);
  return NextResponse.json(slots, { status: 200 });
}
