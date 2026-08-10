// bookings — server-side proxy for CREATING a booking.
// =============================================================================
// Runs on the Next.js server (the i18n middleware skips /api), so it can reach the
// internal .NET backend that the browser cannot. The booking write therefore stays
// server-side. Maps the backend's status codes straight through (201 created, 400
// validation, 409 slot taken / unavailable, 503 not configured).
// =============================================================================
import { NextResponse } from 'next/server';
import { createBooking } from '../../../lib/bookings';

export const dynamic = 'force-dynamic';

export async function POST(request) {
  let body;
  try { body = await request.json(); } catch { body = {}; }

  const res = await createBooking({
    slotId: Number(body.slotId),
    customerName: String(body.customerName ?? ''),
    customerEmail: String(body.customerEmail ?? ''),
    customerPhone: String(body.customerPhone ?? ''),
    notes: String(body.notes ?? ''),
  });

  return NextResponse.json(res.data ?? {}, { status: res.status });
}
