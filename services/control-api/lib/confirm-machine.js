// confirm-machine.js — PURE state machine for the destructive-action flow
// (confirm → pending → success | error). Extracted from the UI so the exact
// transition logic is unit-testable with raw `node` (no React, no browser).
//
//   idle ──ask──▶ confirming ──confirm──▶ pending ──resolve──▶ success ──close──▶ idle
//                      ▲                      │
//                      └────────reject────────┘   (a failed action returns to
//                                                   confirming so the operator can
//                                                   retry or cancel; never silently
//                                                   closes on failure)
// Unknown (state,event) pairs are a no-op (return the same state) — fail safe.

export const CONFIRM_STATES = ['idle', 'confirming', 'pending', 'success', 'error'];

export function confirmReducer(state, event) {
  switch (state) {
    case 'idle':
      return event === 'ask' ? 'confirming' : 'idle';
    case 'confirming':
      if (event === 'confirm') return 'pending';
      if (event === 'cancel' || event === 'close') return 'idle';
      return 'confirming';
    case 'pending':
      if (event === 'resolve') return 'success';
      if (event === 'reject') return 'error';
      return 'pending';
    case 'success':
      return event === 'close' ? 'idle' : 'success';
    case 'error':
      // A failed action keeps the dialog open for retry/cancel.
      if (event === 'confirm') return 'pending';
      if (event === 'cancel' || event === 'close') return 'idle';
      return 'error';
    default:
      return 'idle';
  }
}

// Derived flags the dialog renders from — single source of truth for the view.
export function confirmView(state) {
  return {
    open: state !== 'idle',
    pending: state === 'pending',
    success: state === 'success',
    failed: state === 'error',
    // The confirm button is disabled while the request is in flight or done.
    confirmDisabled: state === 'pending' || state === 'success',
  };
}
